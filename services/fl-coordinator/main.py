"""
Federated Learning Coordinator

FedAvg aggregation server for the multi-tenant Kubernetes SaaS platform.
Runs in the fl-system namespace. Never stores raw tenant data between rounds.

Endpoints:
  POST /register       — tenant registers before participating
  GET  /global-model   — fetch current global model weights
  POST /submit-update  — submit local update after training (rate-limited)
  GET  /round-status   — current round state
  GET  /billing        — per-tenant billing / metering (requires auth)
  GET  /health         — liveness / readiness probe (no auth)
  GET  /metrics        — Prometheus metrics (no auth)

Environment variables:
  FL_SHARED_SECRET          Shared secret for all authenticated endpoints
  FL_MIN_CLIENTS            Minimum updates before synchronous aggregation (default: 2)
  FL_AGGREGATION_STRATEGY   fedavg | krum | trimmed_mean (default: fedavg)
  FL_ASYNC_TIMEOUT_S        Watchdog fires aggregation after this many seconds (default: 300)
  FL_TLS_CERT               Path to server TLS certificate (enables mTLS when set)
  FL_TLS_KEY                Path to server TLS private key
  FL_TLS_CA                 Path to CA certificate for client verification
"""

import asyncio
import enum
import logging
import os
import ssl
import time
from collections import defaultdict
from contextlib import asynccontextmanager
from typing import Any, Optional

import numpy as np
from fastapi import Depends, FastAPI, Header, HTTPException
from prometheus_client import Counter, Gauge, Histogram, make_asgi_app
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

# ── Constants ────────────────────────────────────────────────────────────────
_RATE_LIMIT_WINDOW_S: float = 60.0
_RATE_LIMIT_MAX: int = 10

# ── Prometheus metrics ───────────────────────────────────────────────────────
rounds_completed = Counter("fl_rounds_completed_total", "Total FL rounds completed")
clients_participated = Histogram("fl_clients_per_round", "Clients per FL round")
aggregation_duration = Histogram(
    "fl_aggregation_duration_seconds", "Time to aggregate weights"
)
global_model_version = Gauge("fl_global_model_version", "Current global model version")
fl_tenant_rounds_total = Counter(
    "fl_tenant_rounds_total", "FL rounds participated by tenant", ["tenant"]
)
fl_tenant_samples_total = Counter(
    "fl_tenant_samples_total", "FL samples contributed by tenant", ["tenant"]
)

# ── State ────────────────────────────────────────────────────────────────────
class FLState:
    """Mutable server state for one federated learning session."""

    def __init__(self) -> None:
        self.round: int = 0
        self.global_weights: Optional[list[Any]] = None
        self.pending_updates: dict[str, dict[str, Any]] = {}
        self.min_clients: int = int(os.getenv("FL_MIN_CLIENTS", "2"))
        self.registered_tenants: set[str] = set()
        self.round_lock: asyncio.Lock = asyncio.Lock()
        self.last_aggregation_time: float = time.monotonic()


state = FLState()

# ── Billing (per-tenant metering) ────────────────────────────────────────────
_billing: dict = defaultdict(
    lambda: {"rounds": 0, "total_samples": 0, "last_participated": None}
)

# ── Rate-limit state (per-tenant sliding window) ─────────────────────────────
_rate_windows: dict[str, list[float]] = defaultdict(list)

# ── Pydantic schemas ─────────────────────────────────────────────────────────
class TenantRegistration(BaseModel):
    tenant_id: str
    data_size: int


class ModelUpdate(BaseModel):
    tenant_id: str
    round: int
    weights: list[Any]
    num_samples: int
    metrics: dict[str, Any] = {}


class GlobalModel(BaseModel):
    round: int
    weights: Optional[list[Any]]
    min_clients_needed: int
    registered_clients: int


# ── Aggregation strategy ──────────────────────────────────────────────────────
class AggregationStrategy(str, enum.Enum):
    fedavg = "fedavg"
    krum = "krum"
    trimmed_mean = "trimmed_mean"


# ── Auth ─────────────────────────────────────────────────────────────────────
def verify_fl_secret(x_fl_secret: str = Header(...)) -> None:
    """Reject requests whose x-fl-secret header does not match the shared secret."""
    expected = os.getenv("FL_SHARED_SECRET", "changeme-in-production")
    if x_fl_secret != expected:
        raise HTTPException(status_code=403, detail="Invalid FL secret")


# ── Rate limiter ─────────────────────────────────────────────────────────────
def _check_rate_limit(tenant_id: str) -> None:
    """
    Enforce a sliding-window rate limit of 10 submissions per tenant per minute.

    Prevents a single malfunctioning or malicious client from flooding the
    coordinator with spurious updates and degrading aggregation quality.
    """
    now = time.monotonic()
    window = [t for t in _rate_windows[tenant_id] if now - t < _RATE_LIMIT_WINDOW_S]
    _rate_windows[tenant_id] = window
    if len(window) >= _RATE_LIMIT_MAX:
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded: max {_RATE_LIMIT_MAX} submissions per minute",
        )
    _rate_windows[tenant_id].append(now)


# ── Weight validation ────────────────────────────────────────────────────────
def _validate_weights(weights: list[Any], tenant_id: str) -> None:
    """
    Check submitted weight tensors for NaN and Inf before aggregation.

    NaN weights silently corrupt the global model via weighted averaging.
    Inf weights indicate numerical overflow in the client's training loop.
    Both are rejected at this boundary rather than propagated to all tenants.
    """
    if not weights:
        raise ValueError(f"Empty weight list from tenant {tenant_id}")

    for layer_idx, layer in enumerate(weights):
        try:
            arr = np.array(layer, dtype=np.float64)
        except (ValueError, TypeError) as exc:
            raise ValueError(
                f"Layer {layer_idx} from {tenant_id} is not numeric: {exc}"
            ) from exc

        if np.any(np.isnan(arr)):
            raise ValueError(f"NaN detected in layer {layer_idx} from tenant {tenant_id}")

        if np.any(np.isinf(arr)):
            raise ValueError(f"Inf detected in layer {layer_idx} from tenant {tenant_id}")


# ── FedAvg (pure function — no side effects, fully testable) ─────────────────
def _compute_fedavg(updates: list[dict[str, Any]]) -> list[list[float]]:
    """
    Compute a sample-weighted average of model weight tensors (FedAvg).

    Implements McMahan et al. (2017): each client's contribution is weighted
    by n_i / N_total, where n_i is its local sample count.

    Raises ValueError for empty input or zero total samples so the caller
    can log and abort the round rather than storing a corrupted global model.
    """
    if not updates:
        raise ValueError("Cannot aggregate: no updates provided")

    total_samples: int = sum(u["num_samples"] for u in updates)
    if total_samples == 0:
        raise ValueError("Cannot aggregate: total sample count across all clients is zero")

    aggregated: Optional[list[np.ndarray]] = None
    for upd in updates:
        client_weight = upd["num_samples"] / total_samples
        layers = [np.array(layer, dtype=np.float64) * client_weight for layer in upd["weights"]]
        if aggregated is None:
            aggregated = layers
        else:
            aggregated = [aggregated[i] + layers[i] for i in range(len(layers))]

    assert aggregated is not None
    return [layer.tolist() for layer in aggregated]


# ── Krum (Blanchard et al. 2017) ─────────────────────────────────────────────
def _compute_krum(updates: list[dict[str, Any]], f: int = 1) -> list[list[float]]:
    """
    Krum aggregation: select the single update whose weight vector is closest
    to its (n − f − 2) nearest neighbours by L2 distance.

    Robust against up to f Byzantine clients out of n total.
    When n is too small to admit n−f−2 neighbours, at least 1 neighbour is used.
    """
    if not updates:
        raise ValueError("Cannot aggregate: no updates provided")

    n = len(updates)
    if n == 1:
        return updates[0]["weights"]

    # Flatten each client's weights to a 1-D vector
    vectors = [
        np.concatenate([
            np.array(layer, dtype=np.float64).flatten() for layer in upd["weights"]
        ])
        for upd in updates
    ]

    # Symmetric pairwise L2 distances
    distances = np.zeros((n, n))
    for i in range(n):
        for j in range(i + 1, n):
            d = float(np.linalg.norm(vectors[i] - vectors[j]))
            distances[i, j] = d
            distances[j, i] = d

    # Number of nearest neighbours to sum (at least 1)
    k = max(1, n - f - 2)

    scores = np.zeros(n)
    for i in range(n):
        dists_from_i = sorted(distances[i, j] for j in range(n) if j != i)
        scores[i] = float(sum(dists_from_i[:k]))

    best_idx = int(np.argmin(scores))
    return updates[best_idx]["weights"]


# ── Trimmed mean ──────────────────────────────────────────────────────────────
def _compute_trimmed_mean(
    updates: list[dict[str, Any]], trim_fraction: float = 0.1
) -> list[list[float]]:
    """
    Coordinate-wise trimmed mean aggregation.

    For each weight coordinate, sorts values across all clients and discards
    the top and bottom trim_fraction before computing the mean.
    Tolerates ⌊n × trim_fraction⌋ Byzantine clients per coordinate.
    """
    if not updates:
        raise ValueError("Cannot aggregate: no updates provided")

    n = len(updates)
    trim_count = int(n * trim_fraction)
    num_layers = len(updates[0]["weights"])
    result = []

    for layer_idx in range(num_layers):
        stacked = np.stack([
            np.array(upd["weights"][layer_idx], dtype=np.float64) for upd in updates
        ])  # shape: (n, *layer_shape)

        if trim_count > 0 and n - 2 * trim_count > 0:
            sorted_stack = np.sort(stacked, axis=0)
            trimmed = sorted_stack[trim_count: n - trim_count]
        else:
            trimmed = stacked

        result.append(np.mean(trimmed, axis=0).tolist())

    return result


# ── mTLS ─────────────────────────────────────────────────────────────────────
def _build_ssl_context(cert: str, key: str, ca: str) -> ssl.SSLContext:
    """
    Build a mutual-TLS SSLContext for the coordinator server.

    Requires all FL clients to present a certificate signed by the given CA,
    providing cryptographic tenant authentication on top of the shared secret.
    Called from __main__ when FL_TLS_CERT is set.
    """
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_cert_chain(cert, key)
    ctx.load_verify_locations(ca)
    return ctx


# ── Aggregation orchestrator ─────────────────────────────────────────────────
async def _aggregate(app_state: FLState) -> None:
    """
    Run one complete FL round: aggregate pending updates, advance round counter.

    Dispatches to the strategy selected by FL_AGGREGATION_STRATEGY env var.
    Called inside round_lock — caller must hold the lock.
    Resets last_aggregation_time so the async watchdog resets its countdown.
    """
    start = time.time()
    updates = list(app_state.pending_updates.values())

    raw_strategy = os.getenv("FL_AGGREGATION_STRATEGY", "fedavg")
    try:
        strategy = AggregationStrategy(raw_strategy)
    except ValueError as exc:
        raise ValueError(f"Unknown aggregation strategy: {raw_strategy!r}") from exc

    if strategy == AggregationStrategy.fedavg:
        app_state.global_weights = _compute_fedavg(updates)
    elif strategy == AggregationStrategy.krum:
        app_state.global_weights = _compute_krum(updates)
    elif strategy == AggregationStrategy.trimmed_mean:
        app_state.global_weights = _compute_trimmed_mean(updates)

    app_state.round += 1
    app_state.last_aggregation_time = time.monotonic()
    app_state.pending_updates.clear()

    elapsed = time.time() - start
    rounds_completed.inc()
    clients_participated.observe(len(updates))
    aggregation_duration.observe(elapsed)
    global_model_version.set(app_state.round)

    logger.info(
        "Aggregation complete | strategy=%s round=%d clients=%d duration=%.3fs",
        raw_strategy,
        app_state.round,
        len(updates),
        elapsed,
    )


# ── Async aggregation watchdog ────────────────────────────────────────────────
async def _async_aggregation_watchdog(app_state: FLState) -> None:
    """
    Background task: fires aggregation after FL_ASYNC_TIMEOUT_S seconds even
    when fewer than min_clients updates have arrived (asynchronous FL).

    Checks every 10 s; timeout is read once at startup so it can be
    overridden via monkeypatch in tests before the function is called.
    """
    timeout = float(os.getenv("FL_ASYNC_TIMEOUT_S", "300"))
    while True:
        await asyncio.sleep(10)
        async with app_state.round_lock:
            pending = len(app_state.pending_updates)
            elapsed = time.monotonic() - app_state.last_aggregation_time
            if pending > 0 and elapsed > timeout:
                logger.info(
                    "Async watchdog: firing aggregation (pending=%d, elapsed=%.1fs > timeout=%.1fs)",
                    pending,
                    elapsed,
                    timeout,
                )
                await _aggregate(app_state)


# ── Lifespan ─────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(application: FastAPI):  # type: ignore[type-arg]
    """Spawn the async aggregation watchdog on startup; cancel it on shutdown."""
    task = asyncio.create_task(_async_aggregation_watchdog(state))
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


# ── Application ──────────────────────────────────────────────────────────────
app = FastAPI(
    title="FL Coordinator",
    description="Federated Learning aggregation server — namespace-based multi-tenant K8s",
    version="1.0.0",
    lifespan=lifespan,
)
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)


# ── Routes ───────────────────────────────────────────────────────────────────
@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "round": state.round, "pending": len(state.pending_updates)}


@app.post("/register", dependencies=[Depends(verify_fl_secret)])
def register_tenant(reg: TenantRegistration) -> dict[str, Any]:
    state.registered_tenants.add(reg.tenant_id)
    logger.info("Tenant registered: %s (data_size=%d)", reg.tenant_id, reg.data_size)
    return {"status": "registered", "current_round": state.round}


@app.get("/global-model", response_model=GlobalModel, dependencies=[Depends(verify_fl_secret)])
def get_global_model() -> GlobalModel:
    return GlobalModel(
        round=state.round,
        weights=state.global_weights,
        min_clients_needed=state.min_clients,
        registered_clients=len(state.registered_tenants),
    )


@app.post("/submit-update", dependencies=[Depends(verify_fl_secret)])
async def submit_update(update: ModelUpdate) -> dict[str, Any]:
    """
    Accept a local model update; trigger aggregation when conditions are met.

    Async FL: accepts updates for the current round OR any future round
    (clients that are ahead). Rejects only stale past-round submissions (409).
    """
    if update.tenant_id not in state.registered_tenants:
        raise HTTPException(status_code=403, detail="Tenant not registered — call /register first")

    _check_rate_limit(update.tenant_id)

    if update.round < state.round:
        raise HTTPException(
            status_code=409,
            detail=f"Stale round: coordinator is on round {state.round}, got {update.round}",
        )

    try:
        _validate_weights(update.weights, update.tenant_id)
    except ValueError as exc:
        logger.warning("Rejecting weights from %s: %s", update.tenant_id, exc)
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    async with state.round_lock:
        state.pending_updates[update.tenant_id] = {
            "weights": update.weights,
            "num_samples": update.num_samples,
            "metrics": update.metrics,
        }

        # Billing / metering
        tid = update.tenant_id
        _billing[tid]["rounds"] += 1
        _billing[tid]["total_samples"] += update.num_samples
        _billing[tid]["last_participated"] = time.time()
        fl_tenant_rounds_total.labels(tenant=tid).inc()
        fl_tenant_samples_total.labels(tenant=tid).inc(update.num_samples)

        logger.info(
            "Update accepted | tenant=%s round=%d pending=%d/%d",
            update.tenant_id,
            update.round,
            len(state.pending_updates),
            len(state.registered_tenants),
        )
        if len(state.pending_updates) >= state.min_clients:
            await _aggregate(state)

    return {"status": "accepted", "pending_count": len(state.pending_updates)}


@app.get("/round-status", dependencies=[Depends(verify_fl_secret)])
def round_status() -> dict[str, Any]:
    return {
        "current_round": state.round,
        "pending_updates": list(state.pending_updates.keys()),
        "registered_tenants": list(state.registered_tenants),
        "ready_to_aggregate": len(state.pending_updates) >= state.min_clients,
    }


@app.get("/billing", dependencies=[Depends(verify_fl_secret)])
def get_billing() -> dict[str, Any]:
    """Return per-tenant billing/metering data (rounds participated, samples contributed)."""
    return {
        "tenants": {
            tid: {
                "rounds_participated": v["rounds"],
                "total_samples": v["total_samples"],
                "last_participated": v["last_participated"],
            }
            for tid, v in _billing.items()
        }
    }


if __name__ == "__main__":  # pragma: no cover
    import uvicorn

    tls_cert = os.getenv("FL_TLS_CERT")
    if tls_cert:
        ssl_ctx = _build_ssl_context(
            tls_cert,
            os.getenv("FL_TLS_KEY", ""),
            os.getenv("FL_TLS_CA", ""),
        )
        uvicorn.run(app, host="0.0.0.0", port=8080, ssl=ssl_ctx)
    else:
        uvicorn.run(app, host="0.0.0.0", port=8080)
