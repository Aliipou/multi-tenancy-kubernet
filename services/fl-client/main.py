"""
Federated Learning Client

Per-tenant training agent. Runs inside the tenant namespace.
Loads (or generates) local data, trains a simple linear model,
and submits weight updates to the FL Coordinator.

Raw data NEVER leaves this pod — only the trained weight tensors are transmitted.

Environment variables:
  FL_COORDINATOR_URL          URL of the fl-coordinator service
  TENANT_ID                   Unique identifier for this tenant
  FL_SHARED_SECRET            Shared secret for coordinator authentication
  FL_LOCAL_EPOCHS             Number of local SGD epochs per round (default: 5)
  FL_TRAINING_INTERVAL_S      Seconds to wait between FL rounds (default: 300)
  FL_INPUT_DIM                Input feature dimension (default: 10)
  FL_OUTPUT_DIM               Output dimension (default: 1)
  FL_LOCAL_DATA_SIZE          Number of synthetic training samples (default: 200)
  FL_LEARNING_RATE            SGD learning rate (default: 0.01)
  FL_DATA_SEED                Random seed for synthetic data generation (default: 42)
  DP_EPSILON                  Differential privacy ε budget (default: 1.0; ≤0 disables DP)
  DP_DELTA                    Differential privacy δ failure probability (default: 1e-5)
  DP_SENSITIVITY              L2 sensitivity of the weight update (default: 1.0)
"""

import asyncio
import logging
import math
import os
from dataclasses import dataclass, field
from typing import Any

import httpx
import numpy as np

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

# ── Constants (from env) ─────────────────────────────────────────────────────
COORDINATOR_URL: str = os.getenv("FL_COORDINATOR_URL", "http://fl-coordinator.fl-system.svc.cluster.local:8080")
TENANT_ID: str = os.getenv("TENANT_ID", "unknown-tenant")
FL_SECRET: str = os.getenv("FL_SHARED_SECRET", "changeme-in-production")
LOCAL_EPOCHS: int = int(os.getenv("FL_LOCAL_EPOCHS", "5"))
TRAINING_INTERVAL_S: float = float(os.getenv("FL_TRAINING_INTERVAL_S", "300"))
INPUT_DIM: int = int(os.getenv("FL_INPUT_DIM", "10"))
OUTPUT_DIM: int = int(os.getenv("FL_OUTPUT_DIM", "1"))
LOCAL_DATA_SIZE: int = int(os.getenv("FL_LOCAL_DATA_SIZE", "200"))
LEARNING_RATE: float = float(os.getenv("FL_LEARNING_RATE", "0.01"))
DATA_SEED: int = int(os.getenv("FL_DATA_SEED", "42"))
DP_EPSILON: float = float(os.getenv("DP_EPSILON", "1.0"))
DP_DELTA: float = float(os.getenv("DP_DELTA", "1e-5"))
DP_SENSITIVITY: float = float(os.getenv("DP_SENSITIVITY", "1.0"))

_HEADERS: dict[str, str] = {"x-fl-secret": FL_SECRET}
_HTTP_TIMEOUT_S: float = 30.0


# ── Local Model ───────────────────────────────────────────────────────────────
class LocalModel:
    """
    Single-layer linear regression model trained with mini-batch SGD.

    Chosen because it has no ML framework dependencies (numpy only),
    is fully deterministic given a fixed seed, and its weights serialise
    trivially as nested Python lists for JSON transport.
    """

    def __init__(
        self,
        input_dim: int = INPUT_DIM,
        output_dim: int = OUTPUT_DIM,
        seed: int = 0,
    ) -> None:
        rng = np.random.default_rng(seed)
        self.W: np.ndarray = rng.normal(0.0, 0.01, (input_dim, output_dim))
        self.b: np.ndarray = np.zeros(output_dim)

    def forward(self, X: np.ndarray) -> np.ndarray:
        """Compute linear prediction: y_pred = X @ W + b."""
        return X @ self.W + self.b

    def train(
        self,
        X: np.ndarray,
        y: np.ndarray,
        epochs: int = LOCAL_EPOCHS,
        lr: float = LEARNING_RATE,
    ) -> dict[str, float]:
        """
        Train using full-batch gradient descent for `epochs` passes.

        Returns a metrics dict with initial_loss and final_loss so the
        coordinator can log training progress without seeing the raw data.

        Raises ValueError for empty input to prevent silent zero-gradient updates.
        """
        n = X.shape[0]
        if n == 0:
            raise ValueError("Cannot train on empty dataset")

        initial_loss = _mse_loss(self.forward(X), y)

        for _ in range(epochs):
            y_pred = self.forward(X)
            error = y_pred - y                           # (n, output_dim)
            dW = X.T @ error / n                         # (input_dim, output_dim)
            db = error.mean(axis=0)                      # (output_dim,)
            self.W -= lr * dW
            self.b -= lr * db

        final_loss = _mse_loss(self.forward(X), y)
        return {"initial_loss": float(initial_loss), "final_loss": float(final_loss)}

    def get_weights(self) -> list[list[float]]:
        """Serialise model weights to nested Python lists for JSON transport."""
        return [self.W.tolist(), self.b.tolist()]

    def set_weights(self, weights: list[list[float]]) -> None:
        """
        Deserialise and apply weights received from the global model.

        Validates shape consistency to catch protocol mismatches between
        coordinator and client before they corrupt local training.
        """
        if len(weights) != 2:
            raise ValueError(f"Expected 2 weight tensors (W, b), got {len(weights)}")
        W_new = np.array(weights[0], dtype=np.float64)
        b_new = np.array(weights[1], dtype=np.float64)
        if W_new.shape != self.W.shape:
            raise ValueError(f"W shape mismatch: expected {self.W.shape}, got {W_new.shape}")
        if b_new.shape != self.b.shape:
            raise ValueError(f"b shape mismatch: expected {self.b.shape}, got {b_new.shape}")
        self.W = W_new
        self.b = b_new


# ── Data generation ───────────────────────────────────────────────────────────
def generate_local_data(
    n: int = LOCAL_DATA_SIZE,
    input_dim: int = INPUT_DIM,
    output_dim: int = OUTPUT_DIM,
    seed: int = DATA_SEED,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Generate synthetic linear regression data with Gaussian noise.

    In production, replace this with real tenant data loading.
    The fixed seed ensures deterministic benchmarks across runs.

    Raises ValueError if n < 1 to prevent training on empty data.
    """
    if n < 1:
        raise ValueError(f"Data size must be >= 1, got {n}")

    rng = np.random.default_rng(seed)
    X = rng.normal(0.0, 1.0, (n, input_dim))
    true_W = rng.normal(0.0, 1.0, (input_dim, output_dim))
    noise = rng.normal(0.0, 0.1, (n, output_dim))
    y = X @ true_W + noise
    return X, y


# ── Helpers ───────────────────────────────────────────────────────────────────
def _mse_loss(y_pred: np.ndarray, y_true: np.ndarray) -> float:
    """Compute Mean Squared Error loss."""
    return float(np.mean((y_pred - y_true) ** 2))


def _add_gaussian_noise(
    weights: list[list[float]],
    epsilon: float,
    delta: float,
    sensitivity: float,
) -> list[list[float]]:
    """
    Add calibrated Gaussian noise to model weights for (ε, δ)-differential privacy.

    Implements the Gaussian mechanism (Dwork & Roth, 2014):
        noise_scale = sensitivity × √(2 ln(1.25/δ)) / ε

    Returns weights unchanged when ε ≤ 0 or δ ≤ 0 (DP disabled).
    Raw data never leaves the client; only the noised weights are transmitted.
    """
    if epsilon <= 0 or delta <= 0:
        return weights

    noise_scale = sensitivity * math.sqrt(2.0 * math.log(1.25 / delta)) / epsilon
    rng = np.random.default_rng()
    noisy: list[list[float]] = []
    for layer in weights:
        arr = np.array(layer, dtype=np.float64)
        noisy.append((arr + rng.normal(0.0, noise_scale, arr.shape)).tolist())
    return noisy


# ── Coordinator communication ─────────────────────────────────────────────────
async def _register(client: httpx.AsyncClient) -> None:
    """Register this tenant with the coordinator before participating in FL."""
    resp = await client.post(
        f"{COORDINATOR_URL}/register",
        json={"tenant_id": TENANT_ID, "data_size": LOCAL_DATA_SIZE},
        headers=_HEADERS,
        timeout=_HTTP_TIMEOUT_S,
    )
    resp.raise_for_status()
    logger.info("Registered with coordinator | tenant=%s", TENANT_ID)


async def _fetch_global_model(client: httpx.AsyncClient) -> dict[str, Any]:
    """Fetch the current global model weights from the coordinator."""
    resp = await client.get(
        f"{COORDINATOR_URL}/global-model",
        headers=_HEADERS,
        timeout=_HTTP_TIMEOUT_S,
    )
    resp.raise_for_status()
    return resp.json()  # type: ignore[return-value]


async def _submit_update(
    client: httpx.AsyncClient,
    model: LocalModel,
    metrics: dict[str, float],
    round_num: int,
) -> None:
    """Submit trained weights to the coordinator for FedAvg aggregation."""
    resp = await client.post(
        f"{COORDINATOR_URL}/submit-update",
        json={
            "tenant_id": TENANT_ID,
            "round": round_num,
            "weights": model.get_weights(),
            "num_samples": LOCAL_DATA_SIZE,
            "metrics": metrics,
        },
        headers=_HEADERS,
        timeout=_HTTP_TIMEOUT_S,
    )
    resp.raise_for_status()
    logger.info(
        "Update submitted | tenant=%s round=%d loss=%.4f",
        TENANT_ID,
        round_num,
        metrics.get("final_loss", math.nan),
    )


# ── Main FL loop ──────────────────────────────────────────────────────────────
async def run_fl_loop() -> None:
    """
    Continuous FL participation loop.

    Each iteration: fetch global model → train locally → submit weights.
    Sleeps between rounds to avoid overwhelming the coordinator.
    Never exposes raw data outside this function's scope.
    """
    async with httpx.AsyncClient() as client:
        await _register(client)
        X, y = generate_local_data()

        while True:
            try:
                global_model = await _fetch_global_model(client)
                round_num: int = global_model["round"]

                model = LocalModel()
                if global_model.get("weights"):
                    model.set_weights(global_model["weights"])

                metrics = model.train(X, y, epochs=LOCAL_EPOCHS, lr=LEARNING_RATE)
                logger.info(
                    "Training complete | round=%d loss %.4f -> %.4f",
                    round_num,
                    metrics["initial_loss"],
                    metrics["final_loss"],
                )

                noisy_weights = _add_gaussian_noise(
                    model.get_weights(), DP_EPSILON, DP_DELTA, DP_SENSITIVITY
                )
                model.set_weights(noisy_weights)
                await _submit_update(client, model, metrics, round_num)

            except httpx.HTTPStatusError as exc:
                logger.error("HTTP error during FL round: %s", exc)
            except ValueError as exc:
                logger.error("Training error: %s", exc)

            await asyncio.sleep(TRAINING_INTERVAL_S)


if __name__ == "__main__":  # pragma: no cover
    asyncio.run(run_fl_loop())
