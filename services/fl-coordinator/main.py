"""
Federated Learning Coordinator

FedAvg aggregation server for the multi-tenant Kubernetes SaaS platform.
Runs in the fl-system namespace. Never stores raw tenant data between rounds.

Endpoints:
  POST /register       — tenant registers before participating
  GET  /global-model   — fetch current global model weights
  POST /submit-update  — submit local update after training (rate-limited)
  GET  /round-status   — current round state
  GET  /health         — liveness / readiness probe (no auth)
  GET  /metrics        — Prometheus metrics (no auth)
"""

import asyncio
import logging
import os
import time
from collections import defaultdict
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

# ── Application ──────────────────────────────────────────────────────────────
app = FastAPI(
    title="FL Coordinator",
    description="Federated Learning aggregation server — namespace-based multi-tenant K8s",
    version="1.0.0",
)
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)

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


state = FLState()

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


# ── Aggregation orchestrator ─────────────────────────────────────────────────
async def _aggregate(app_state: FLState) -> None:
    """
    Run one complete FL round: aggregate pending updates, advance round counter.

    Called automatically inside the round_lock when min_clients updates
    have accumulated. Clears pending_updates so the next round starts fresh.
    Does NOT release the lock — caller is responsible.
    """
    start = time.time()
    updates = list(app_state.pending_updates.values())

    app_state.global_weights = _compute_fedavg(updates)
    app_state.round += 1
    app_state.pending_updates.clear()

    elapsed = time.time() - start
    rounds_completed.inc()
    clients_participated.observe(len(updates))
    aggregation_duration.observe(elapsed)
    global_model_version.set(app_state.round)

    logger.info(
        "Aggregation complete | round=%d clients=%d duration=%.3fs",
        app_state.round,
        len(updates),
        elapsed,
    )


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
    """Accept a local model update; trigger FedAvg when min_clients updates are ready."""
    if update.tenant_id not in state.registered_tenants:
        raise HTTPException(status_code=403, detail="Tenant not registered — call /register first")

    _check_rate_limit(update.tenant_id)

    if update.round != state.round:
        raise HTTPException(
            status_code=409,
            detail=f"Round mismatch: coordinator is on round {state.round}, got {update.round}",
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


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
