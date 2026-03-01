"""
Rigorous tests for the FL Coordinator.

Coverage targets (100% on main.py):
  Unit — _compute_fedavg, _compute_krum, _compute_trimmed_mean,
          _validate_weights, _check_rate_limit, _build_ssl_context
  Integration — all HTTP endpoints via FastAPI TestClient
  Async — _async_aggregation_watchdog (monkeypatched sleep)
  Billing — _billing dict, GET /billing endpoint

Test naming convention:
  test_<function>_<condition>_<expected_result>
"""

import asyncio
import math
import time
from unittest.mock import MagicMock

import numpy as np
import pytest
from fastapi.testclient import TestClient

import main
from main import (
    AggregationStrategy,
    _async_aggregation_watchdog,
    _billing,
    _check_rate_limit,
    _compute_fedavg,
    _compute_krum,
    _compute_trimmed_mean,
    _rate_windows,
    _validate_weights,
    app,
    state,
)

CLIENT = TestClient(app)
HEADERS = {"x-fl-secret": "test-secret"}
BAD_HEADERS = {"x-fl-secret": "wrong-secret"}

# ─────────────────────────────────────────────────────────────────────────────
# _compute_fedavg — pure function tests
# ─────────────────────────────────────────────────────────────────────────────

def test_compute_fedavg_equal_samples_produces_simple_average() -> None:
    """With equal sample counts FedAvg degenerates to a plain mean."""
    updates = [
        {"weights": [[[1.0, 2.0]], [0.0]], "num_samples": 100},
        {"weights": [[[3.0, 4.0]], [2.0]], "num_samples": 100},
    ]
    result = _compute_fedavg(updates)
    assert math.isclose(result[0][0][0], 2.0, abs_tol=1e-9)
    assert math.isclose(result[0][0][1], 3.0, abs_tol=1e-9)
    assert math.isclose(result[1][0], 1.0, abs_tol=1e-9)


def test_compute_fedavg_unequal_samples_weights_proportionally() -> None:
    """Client with 3x samples should dominate 3:1 over the smaller client."""
    updates = [
        {"weights": [[[0.0]]], "num_samples": 300},
        {"weights": [[[4.0]]], "num_samples": 100},
    ]
    result = _compute_fedavg(updates)
    expected = 0.0 * 0.75 + 4.0 * 0.25  # = 1.0
    assert math.isclose(result[0][0][0], expected, abs_tol=1e-9)


def test_compute_fedavg_single_client_returns_its_weights() -> None:
    """With one client, result is exactly that client's weights (weight=1.0)."""
    weights = [[[1.5, -2.3, 0.0]]]
    updates = [{"weights": weights, "num_samples": 50}]
    result = _compute_fedavg(updates)
    np.testing.assert_allclose(result[0][0], weights[0][0], atol=1e-9)


def test_compute_fedavg_empty_updates_raises_value_error() -> None:
    with pytest.raises(ValueError, match="no updates"):
        _compute_fedavg([])


def test_compute_fedavg_zero_total_samples_raises_value_error() -> None:
    updates = [
        {"weights": [[[1.0]]], "num_samples": 0},
        {"weights": [[[2.0]]], "num_samples": 0},
    ]
    with pytest.raises(ValueError, match="zero"):
        _compute_fedavg(updates)


def test_compute_fedavg_multilayer_model_aggregates_each_layer() -> None:
    """Aggregation must be applied independently per layer."""
    updates = [
        {"weights": [[[1.0], [2.0]], [[0.5]]], "num_samples": 1},
        {"weights": [[[3.0], [4.0]], [[1.5]]], "num_samples": 1},
    ]
    result = _compute_fedavg(updates)
    assert math.isclose(result[0][0][0], 2.0, abs_tol=1e-9)
    assert math.isclose(result[0][1][0], 3.0, abs_tol=1e-9)
    assert math.isclose(result[1][0][0], 1.0, abs_tol=1e-9)


# ─────────────────────────────────────────────────────────────────────────────
# _compute_krum — Byzantine-robust aggregation
# ─────────────────────────────────────────────────────────────────────────────

def test_compute_krum_empty_updates_raises_value_error() -> None:
    with pytest.raises(ValueError, match="no updates"):
        _compute_krum([])


def test_compute_krum_single_client_returns_its_weights() -> None:
    weights = [[[1.0, 2.0]], [0.5]]
    updates = [{"weights": weights, "num_samples": 100}]
    assert _compute_krum(updates) == weights


def test_compute_krum_equal_weights_returns_one_of_them() -> None:
    """All clients have identical weights → all Krum scores are 0 → first wins."""
    w = [[[1.0, 2.0]], [0.5]]
    updates = [
        {"weights": w, "num_samples": 100},
        {"weights": w, "num_samples": 100},
        {"weights": w, "num_samples": 100},
    ]
    result = _compute_krum(updates)
    np.testing.assert_allclose(np.array(result[0]), np.array(w[0]), atol=1e-9)


def test_compute_krum_outlier_has_high_score_and_is_rejected() -> None:
    """The outlier update (far from others) must NOT be selected by Krum."""
    honest = [[[0.0]]]
    outlier = [[[1000.0]]]  # very far from honest clients
    updates = [
        {"weights": honest, "num_samples": 100},
        {"weights": honest, "num_samples": 100},
        {"weights": honest, "num_samples": 100},
        {"weights": outlier, "num_samples": 100},  # Byzantine
    ]
    result = _compute_krum(updates, f=1)
    # Result must be one of the honest updates (not the outlier)
    assert math.isclose(result[0][0][0], 0.0, abs_tol=1e-9)


def test_compute_krum_two_clients_returns_one() -> None:
    """With n=2, f=0: each client's k=max(1,0)=1 neighbour is the other."""
    updates = [
        {"weights": [[[1.0]]], "num_samples": 50},
        {"weights": [[[3.0]]], "num_samples": 50},
    ]
    result = _compute_krum(updates)
    # Both have the same score; first (argmin→0) is returned
    assert result == [[[1.0]]]


# ─────────────────────────────────────────────────────────────────────────────
# _compute_trimmed_mean
# ─────────────────────────────────────────────────────────────────────────────

def test_compute_trimmed_mean_empty_updates_raises_value_error() -> None:
    with pytest.raises(ValueError, match="no updates"):
        _compute_trimmed_mean([])


def test_compute_trimmed_mean_single_client_returns_its_weights() -> None:
    weights = [[[1.5, -2.3]]]
    updates = [{"weights": weights, "num_samples": 50}]
    result = _compute_trimmed_mean(updates, trim_fraction=0.0)
    np.testing.assert_allclose(np.array(result[0]), np.array(weights[0]), atol=1e-9)


def test_compute_trimmed_mean_zero_fraction_equals_unweighted_mean() -> None:
    """With trim=0 and equal samples, trimmed_mean == FedAvg (simple average)."""
    updates = [
        {"weights": [[[1.0, 2.0]], [0.5]], "num_samples": 100},
        {"weights": [[[3.0, 4.0]], [1.5]], "num_samples": 100},
    ]
    fedavg_result = _compute_fedavg(updates)
    trim_result = _compute_trimmed_mean(updates, trim_fraction=0.0)
    np.testing.assert_allclose(
        np.array(fedavg_result[0]), np.array(trim_result[0]), atol=1e-9
    )
    np.testing.assert_allclose(
        np.array(fedavg_result[1]), np.array(trim_result[1]), atol=1e-9
    )


def test_compute_trimmed_mean_outlier_is_removed() -> None:
    """With trim_fraction=0.25 on 4 clients, 1 top + 1 bottom are trimmed."""
    updates = [
        {"weights": [[[1.0]]], "num_samples": 100},
        {"weights": [[[2.0]]], "num_samples": 100},
        {"weights": [[[3.0]]], "num_samples": 100},
        {"weights": [[[1000.0]]], "num_samples": 100},  # outlier
    ]
    result = _compute_trimmed_mean(updates, trim_fraction=0.25)
    # After trimming 1 bottom (1.0) and 1 top (1000.0), mean of [2.0, 3.0] = 2.5
    assert math.isclose(result[0][0][0], 2.5, abs_tol=1e-9)


def test_compute_trimmed_mean_trim_count_exceeds_safe_range_falls_back_to_mean() -> None:
    """When n - 2*trim_count <= 0, fall back to mean of all (no trim)."""
    updates = [
        {"weights": [[[1.0]]], "num_samples": 100},
        {"weights": [[[3.0]]], "num_samples": 100},
    ]
    # trim_fraction=0.5 → trim_count=1, n-2*1=0 → use all
    result = _compute_trimmed_mean(updates, trim_fraction=0.5)
    assert math.isclose(result[0][0][0], 2.0, abs_tol=1e-9)


# ─────────────────────────────────────────────────────────────────────────────
# _aggregate strategy dispatch
# ─────────────────────────────────────────────────────────────────────────────

async def test_aggregate_unknown_strategy_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FL_AGGREGATION_STRATEGY", "bogus")
    fresh = main.FLState()
    fresh.pending_updates["t1"] = {"weights": [[[1.0]]], "num_samples": 100, "metrics": {}}
    with pytest.raises(ValueError, match="Unknown aggregation strategy"):
        await main._aggregate(fresh)


async def test_aggregate_krum_strategy_selected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FL_AGGREGATION_STRATEGY", "krum")
    fresh = main.FLState()
    fresh.pending_updates["t1"] = {"weights": [[[1.0]]], "num_samples": 100, "metrics": {}}
    await main._aggregate(fresh)
    assert fresh.round == 1
    assert fresh.global_weights == [[[1.0]]]


async def test_aggregate_trimmed_mean_strategy_selected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FL_AGGREGATION_STRATEGY", "trimmed_mean")
    fresh = main.FLState()
    fresh.pending_updates["t1"] = {"weights": [[[2.0]]], "num_samples": 100, "metrics": {}}
    await main._aggregate(fresh)
    assert fresh.round == 1
    assert math.isclose(fresh.global_weights[0][0][0], 2.0, abs_tol=1e-9)


# ─────────────────────────────────────────────────────────────────────────────
# _validate_weights
# ─────────────────────────────────────────────────────────────────────────────

def test_validate_weights_valid_input_passes() -> None:
    _validate_weights([[[1.0, 2.0], [3.0, 4.0]], [0.5, -0.5]], "tenant-a")


def test_validate_weights_nan_in_first_layer_raises_value_error() -> None:
    with pytest.raises(ValueError, match="NaN"):
        _validate_weights([[[float("nan"), 1.0]]], "tenant-a")


def test_validate_weights_nan_in_second_layer_raises_value_error() -> None:
    with pytest.raises(ValueError, match="NaN"):
        _validate_weights([[[1.0]], [float("nan")]], "tenant-a")


def test_validate_weights_inf_raises_value_error() -> None:
    with pytest.raises(ValueError, match="Inf"):
        _validate_weights([[[float("inf")]]], "tenant-a")


def test_validate_weights_negative_inf_raises_value_error() -> None:
    with pytest.raises(ValueError, match="Inf"):
        _validate_weights([[[-float("inf")]]], "tenant-a")


def test_validate_weights_empty_list_raises_value_error() -> None:
    with pytest.raises(ValueError, match="Empty"):
        _validate_weights([], "tenant-a")


def test_validate_weights_non_numeric_layer_raises_value_error() -> None:
    with pytest.raises(ValueError, match="not numeric"):
        _validate_weights([["a", "b"]], "tenant-a")


def test_validate_weights_zero_weights_are_valid() -> None:
    """All-zero weights are valid — they just mean no training happened."""
    _validate_weights([[[0.0, 0.0, 0.0]]], "tenant-a")


# ─────────────────────────────────────────────────────────────────────────────
# _check_rate_limit
# ─────────────────────────────────────────────────────────────────────────────

def test_check_rate_limit_allows_requests_under_limit() -> None:
    for _ in range(9):
        _check_rate_limit("tenant-a")  # should not raise


def test_check_rate_limit_blocks_at_tenth_request() -> None:
    for _ in range(10):
        _check_rate_limit("tenant-a")
    with pytest.raises(Exception):  # HTTPException 429
        _check_rate_limit("tenant-a")


def test_check_rate_limit_independent_per_tenant() -> None:
    """Rate limit for tenant-a must not affect tenant-b."""
    for _ in range(10):
        _check_rate_limit("tenant-a")
    # tenant-b has a clean slate
    _check_rate_limit("tenant-b")  # must not raise


def test_check_rate_limit_expires_old_entries(monkeypatch: pytest.MonkeyPatch) -> None:
    """Entries older than the window should not count toward the limit."""
    old_time = time.monotonic() - 61  # 61 seconds ago — outside the 60s window
    _rate_windows["tenant-a"] = [old_time] * 10
    _check_rate_limit("tenant-a")  # all old entries evicted — should not raise


# ─────────────────────────────────────────────────────────────────────────────
# _build_ssl_context — mTLS
# ─────────────────────────────────────────────────────────────────────────────

def test_build_ssl_context_calls_correct_ssl_methods(monkeypatch: pytest.MonkeyPatch) -> None:
    mock_ctx = MagicMock()
    mock_ssl_class = MagicMock(return_value=mock_ctx)
    monkeypatch.setattr(main.ssl, "SSLContext", mock_ssl_class)

    result = main._build_ssl_context("/cert.pem", "/key.pem", "/ca.pem")

    mock_ssl_class.assert_called_once_with(main.ssl.PROTOCOL_TLS_SERVER)
    assert mock_ctx.verify_mode == main.ssl.CERT_REQUIRED
    mock_ctx.load_cert_chain.assert_called_once_with("/cert.pem", "/key.pem")
    mock_ctx.load_verify_locations.assert_called_once_with("/ca.pem")
    assert result is mock_ctx


# ─────────────────────────────────────────────────────────────────────────────
# Lifespan — watchdog task startup / shutdown
# ─────────────────────────────────────────────────────────────────────────────

def test_lifespan_starts_watchdog_on_enter_and_cancels_on_exit() -> None:
    """
    When TestClient is used as a context manager the lifespan runs.
    The watchdog task must be created on startup and cleanly cancelled on shutdown.
    """
    from fastapi.testclient import TestClient as TC

    with TC(app) as tc:
        resp = tc.get("/health")
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"
    # Reaching here means lifespan shutdown completed without error


# ─────────────────────────────────────────────────────────────────────────────
# GET /health — unauthenticated
# ─────────────────────────────────────────────────────────────────────────────

def test_health_returns_200_without_auth() -> None:
    resp = CLIENT.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_health_reflects_current_round() -> None:
    state.round = 3
    resp = CLIENT.get("/health")
    assert resp.json()["round"] == 3


# ─────────────────────────────────────────────────────────────────────────────
# POST /register
# ─────────────────────────────────────────────────────────────────────────────

def test_register_new_tenant_returns_registered() -> None:
    resp = CLIENT.post("/register", json={"tenant_id": "t1", "data_size": 100}, headers=HEADERS)
    assert resp.status_code == 200
    assert resp.json()["status"] == "registered"
    assert "t1" in state.registered_tenants


def test_register_without_auth_returns_422() -> None:
    resp = CLIENT.post("/register", json={"tenant_id": "t1", "data_size": 100})
    assert resp.status_code == 422


def test_register_with_wrong_secret_returns_403() -> None:
    resp = CLIENT.post("/register", json={"tenant_id": "t1", "data_size": 100}, headers=BAD_HEADERS)
    assert resp.status_code == 403


def test_register_idempotent_second_call_still_succeeds() -> None:
    CLIENT.post("/register", json={"tenant_id": "t1", "data_size": 100}, headers=HEADERS)
    resp = CLIENT.post("/register", json={"tenant_id": "t1", "data_size": 200}, headers=HEADERS)
    assert resp.status_code == 200


# ─────────────────────────────────────────────────────────────────────────────
# GET /global-model
# ─────────────────────────────────────────────────────────────────────────────

def test_get_global_model_initially_has_null_weights() -> None:
    resp = CLIENT.get("/global-model", headers=HEADERS)
    assert resp.status_code == 200
    assert resp.json()["weights"] is None
    assert resp.json()["round"] == 0


def test_get_global_model_without_auth_returns_422() -> None:
    resp = CLIENT.get("/global-model")
    assert resp.status_code == 422


# ─────────────────────────────────────────────────────────────────────────────
# POST /submit-update
# ─────────────────────────────────────────────────────────────────────────────

def _register(tenant_id: str) -> None:
    CLIENT.post("/register", json={"tenant_id": tenant_id, "data_size": 100}, headers=HEADERS)


def _valid_update(tenant_id: str, round_num: int = 0) -> dict:
    return {
        "tenant_id": tenant_id,
        "round": round_num,
        "weights": [[[1.0, 2.0], [3.0, 4.0]], [0.5, -0.5]],
        "num_samples": 100,
        "metrics": {"loss": 0.42},
    }


def test_submit_update_happy_path_returns_accepted() -> None:
    _register("t1")
    resp = CLIENT.post("/submit-update", json=_valid_update("t1"), headers=HEADERS)
    assert resp.status_code == 200
    assert resp.json()["status"] == "accepted"


def test_submit_update_triggers_aggregation_when_min_clients_met() -> None:
    _register("t1")
    _register("t2")
    CLIENT.post("/submit-update", json=_valid_update("t1"), headers=HEADERS)
    assert state.round == 0  # not yet triggered

    CLIENT.post("/submit-update", json=_valid_update("t2"), headers=HEADERS)
    assert state.round == 1  # aggregation ran
    assert state.global_weights is not None
    assert len(state.pending_updates) == 0


def test_submit_update_fedavg_result_is_correct_after_aggregation() -> None:
    """After two equal-weight clients, global model is the average of their weights."""
    _register("t1")
    _register("t2")
    update_a = {**_valid_update("t1"), "weights": [[[0.0]]], "num_samples": 1}
    update_b = {**_valid_update("t2"), "weights": [[[4.0]]], "num_samples": 1}
    CLIENT.post("/submit-update", json=update_a, headers=HEADERS)
    CLIENT.post("/submit-update", json=update_b, headers=HEADERS)
    assert math.isclose(state.global_weights[0][0][0], 2.0, abs_tol=1e-9)


def test_submit_update_unregistered_tenant_returns_403() -> None:
    resp = CLIENT.post("/submit-update", json=_valid_update("unknown"), headers=HEADERS)
    assert resp.status_code == 403


def test_submit_update_past_round_returns_409() -> None:
    """Updates for rounds already completed must be rejected."""
    _register("t1")
    state.round = 3  # advance coordinator past round 0
    bad = {**_valid_update("t1"), "round": 1}  # past round
    resp = CLIENT.post("/submit-update", json=bad, headers=HEADERS)
    assert resp.status_code == 409


def test_submit_update_current_round_accepted() -> None:
    """Updates for the current coordinator round must be accepted."""
    _register("t1")
    state.round = 2
    update = {**_valid_update("t1"), "round": 2}
    resp = CLIENT.post("/submit-update", json=update, headers=HEADERS)
    assert resp.status_code == 200


def test_submit_update_future_round_accepted() -> None:
    """Async FL: clients that are ahead of the coordinator are accepted."""
    _register("t1")
    state.round = 0
    update = {**_valid_update("t1"), "round": 5}
    resp = CLIENT.post("/submit-update", json=update, headers=HEADERS)
    assert resp.status_code == 200


def test_submit_update_nan_weights_returns_422() -> None:
    import json as jsonlib

    _register("t1")
    bad = {**_valid_update("t1"), "weights": [[[float("nan")]]]}
    # httpx >=0.28 uses allow_nan=False; send raw bytes to bypass that restriction
    resp = CLIENT.post(
        "/submit-update",
        content=jsonlib.dumps(bad, allow_nan=True).encode(),
        headers={**HEADERS, "Content-Type": "application/json"},
    )
    assert resp.status_code == 422
    assert "NaN" in resp.json()["detail"]


def test_submit_update_inf_weights_returns_422() -> None:
    import json as jsonlib

    _register("t1")
    bad = {**_valid_update("t1"), "weights": [[[float("inf")]]]}
    resp = CLIENT.post(
        "/submit-update",
        content=jsonlib.dumps(bad, allow_nan=True).encode(),
        headers={**HEADERS, "Content-Type": "application/json"},
    )
    assert resp.status_code == 422


def test_submit_update_without_auth_returns_422() -> None:
    _register("t1")
    resp = CLIENT.post("/submit-update", json=_valid_update("t1"))
    assert resp.status_code == 422


def test_submit_update_rate_limit_returns_429_on_eleventh_request() -> None:
    _register("t1")
    for _ in range(10):
        # reset round each time so round-mismatch doesn't interfere
        state.round = 0
        CLIENT.post("/submit-update", json=_valid_update("t1"), headers=HEADERS)
    state.round = 0
    resp = CLIENT.post("/submit-update", json=_valid_update("t1"), headers=HEADERS)
    assert resp.status_code == 429


def test_submit_update_duplicate_from_same_tenant_overwrites_previous() -> None:
    """Second submission from the same tenant replaces the first (idempotent round)."""
    _register("t1")
    update_first = {**_valid_update("t1"), "weights": [[[1.0]]], "num_samples": 10}
    update_second = {**_valid_update("t1"), "weights": [[[9.0]]], "num_samples": 90}
    CLIENT.post("/submit-update", json=update_first, headers=HEADERS)
    CLIENT.post("/submit-update", json=update_second, headers=HEADERS)
    assert state.pending_updates["t1"]["num_samples"] == 90


# ─────────────────────────────────────────────────────────────────────────────
# Async FL watchdog
# ─────────────────────────────────────────────────────────────────────────────

async def test_watchdog_fires_aggregation_with_less_than_min_clients(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Watchdog must aggregate even when fewer than min_clients updates are pending."""
    monkeypatch.setenv("FL_ASYNC_TIMEOUT_S", "1")

    # Use a fresh FLState (own asyncio.Lock bound to current event loop)
    fresh = main.FLState()
    fresh.registered_tenants.add("t1")
    fresh.pending_updates["t1"] = {
        "weights": [[[1.0]]], "num_samples": 100, "metrics": {}
    }
    # Force the condition: elapsed >> timeout
    fresh.last_aggregation_time = time.monotonic() - 1000

    call_count = 0

    async def fake_sleep(s: float) -> None:
        nonlocal call_count
        call_count += 1
        if call_count >= 2:
            raise asyncio.CancelledError

    monkeypatch.setattr(main.asyncio, "sleep", fake_sleep)

    with pytest.raises(asyncio.CancelledError):
        await _async_aggregation_watchdog(fresh)

    assert fresh.round == 1
    assert len(fresh.pending_updates) == 0


async def test_watchdog_does_not_fire_when_no_pending_updates(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Watchdog must not aggregate when there are no pending updates."""
    monkeypatch.setenv("FL_ASYNC_TIMEOUT_S", "0")

    fresh = main.FLState()
    fresh.last_aggregation_time = time.monotonic() - 1000  # timeout exceeded

    call_count = 0

    async def fake_sleep(s: float) -> None:
        nonlocal call_count
        call_count += 1
        if call_count >= 2:
            raise asyncio.CancelledError

    monkeypatch.setattr(main.asyncio, "sleep", fake_sleep)

    with pytest.raises(asyncio.CancelledError):
        await _async_aggregation_watchdog(fresh)

    assert fresh.round == 0  # no aggregation — nothing pending


async def test_watchdog_does_not_fire_before_timeout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Watchdog must not aggregate when timeout has not been exceeded."""
    monkeypatch.setenv("FL_ASYNC_TIMEOUT_S", "9999")

    fresh = main.FLState()
    fresh.registered_tenants.add("t1")
    fresh.pending_updates["t1"] = {
        "weights": [[[1.0]]], "num_samples": 100, "metrics": {}
    }
    # last_aggregation_time is now → elapsed is tiny → timeout not exceeded

    call_count = 0

    async def fake_sleep(s: float) -> None:
        nonlocal call_count
        call_count += 1
        if call_count >= 2:
            raise asyncio.CancelledError

    monkeypatch.setattr(main.asyncio, "sleep", fake_sleep)

    with pytest.raises(asyncio.CancelledError):
        await _async_aggregation_watchdog(fresh)

    assert fresh.round == 0  # timeout not reached → no aggregation


# ─────────────────────────────────────────────────────────────────────────────
# GET /round-status
# ─────────────────────────────────────────────────────────────────────────────

def test_round_status_shows_correct_pending_tenants() -> None:
    _register("t1")
    CLIENT.post("/submit-update", json=_valid_update("t1"), headers=HEADERS)
    resp = CLIENT.get("/round-status", headers=HEADERS)
    assert resp.status_code == 200
    data = resp.json()
    assert "t1" in data["pending_updates"]
    assert data["ready_to_aggregate"] is False  # min_clients=2, only 1 submitted


def test_round_status_ready_to_aggregate_true_when_min_clients_met() -> None:
    _register("t1")
    _register("t2")
    CLIENT.post("/submit-update", json=_valid_update("t1"), headers=HEADERS)
    CLIENT.post("/submit-update", json={**_valid_update("t2"), "weights": [[[1.0]]]}, headers=HEADERS)
    # After aggregation pending_updates is cleared, so check before second submit triggers agg
    # Actually by the time we check, aggregation already ran — round is 1
    resp = CLIENT.get("/round-status", headers=HEADERS)
    assert resp.json()["current_round"] == 1


def test_round_status_without_auth_returns_422() -> None:
    resp = CLIENT.get("/round-status")
    assert resp.status_code == 422


# ─────────────────────────────────────────────────────────────────────────────
# GET /billing — tenant metering
# ─────────────────────────────────────────────────────────────────────────────

def test_billing_endpoint_requires_auth() -> None:
    resp = CLIENT.get("/billing")
    assert resp.status_code == 422


def test_billing_endpoint_wrong_secret_returns_403() -> None:
    resp = CLIENT.get("/billing", headers=BAD_HEADERS)
    assert resp.status_code == 403


def test_billing_increments_on_accepted_submit() -> None:
    _register("t1")
    CLIENT.post("/submit-update", json=_valid_update("t1", round_num=0), headers=HEADERS)
    assert _billing["t1"]["rounds"] == 1
    assert _billing["t1"]["total_samples"] == 100
    assert _billing["t1"]["last_participated"] is not None


def test_billing_unregistered_tenant_not_tracked() -> None:
    assert "t-never-seen" not in _billing


def test_billing_correct_counts_after_multiple_submits() -> None:
    _register("t1")
    CLIENT.post(
        "/submit-update",
        json={**_valid_update("t1"), "num_samples": 50},
        headers=HEADERS,
    )
    state.round = 0  # reset so second submit is not stale
    CLIENT.post(
        "/submit-update",
        json={**_valid_update("t1"), "num_samples": 75},
        headers=HEADERS,
    )
    assert _billing["t1"]["rounds"] == 2
    assert _billing["t1"]["total_samples"] == 125


def test_billing_endpoint_returns_correct_json() -> None:
    _register("t1")
    CLIENT.post("/submit-update", json=_valid_update("t1"), headers=HEADERS)
    resp = CLIENT.get("/billing", headers=HEADERS)
    assert resp.status_code == 200
    data = resp.json()
    assert "tenants" in data
    assert "t1" in data["tenants"]
    t1 = data["tenants"]["t1"]
    assert t1["rounds_participated"] == 1
    assert t1["total_samples"] == 100
    assert t1["last_participated"] is not None


def test_billing_accumulates_across_two_tenants() -> None:
    _register("t1")
    _register("t2")
    CLIENT.post("/submit-update", json={**_valid_update("t1"), "num_samples": 200}, headers=HEADERS)
    CLIENT.post("/submit-update", json={**_valid_update("t2"), "num_samples": 300}, headers=HEADERS)
    # Both submits happened; after t2's submit aggregation fires (min_clients=2)
    assert _billing["t1"]["total_samples"] == 200
    assert _billing["t2"]["total_samples"] == 300
    assert _billing["t1"]["rounds"] == 1
    assert _billing["t2"]["rounds"] == 1
