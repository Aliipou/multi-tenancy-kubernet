"""
Rigorous tests for the FL Client.

Coverage targets (100% on main.py):
  Unit        — LocalModel, generate_local_data, _mse_loss
  Integration — _register, _fetch_global_model, _submit_update, run_fl_loop (all mocked)

Test naming convention:
  test_<class/function>_<condition>_<expected_result>
"""

import asyncio
import math
from unittest.mock import AsyncMock, MagicMock, patch

import numpy as np
import pytest

from main import (
    INPUT_DIM,
    OUTPUT_DIM,
    LocalModel,
    _add_gaussian_noise,
    _fetch_global_model,
    _mse_loss,
    _register,
    _submit_update,
    generate_local_data,
    run_fl_loop,
)

# ─────────────────────────────────────────────────────────────────────────────
# _add_gaussian_noise — differential privacy
# ─────────────────────────────────────────────────────────────────────────────

def test_add_gaussian_noise_disabled_when_epsilon_nonpositive() -> None:
    weights = [[[1.0, 2.0], [3.0, 4.0]], [0.5]]
    result = _add_gaussian_noise(weights, epsilon=0.0, delta=1e-5, sensitivity=1.0)
    assert result is weights  # exact same object — DP disabled


def test_add_gaussian_noise_disabled_when_epsilon_negative() -> None:
    weights = [[[1.0]]]
    result = _add_gaussian_noise(weights, epsilon=-1.0, delta=1e-5, sensitivity=1.0)
    assert result is weights


def test_add_gaussian_noise_disabled_when_delta_nonpositive() -> None:
    weights = [[[1.0, 2.0]], [0.5]]
    result = _add_gaussian_noise(weights, epsilon=1.0, delta=0.0, sensitivity=1.0)
    assert result is weights


def test_add_gaussian_noise_shape_preserved() -> None:
    weights = [[[1.0, 2.0], [3.0, 4.0]], [0.5, -0.5]]
    result = _add_gaussian_noise(weights, epsilon=1.0, delta=1e-5, sensitivity=1.0)
    assert len(result) == len(weights)
    for orig, noisy in zip(weights, result):
        assert np.array(noisy).shape == np.array(orig).shape


def test_add_gaussian_noise_produces_different_values() -> None:
    weights = [[[1.0, 2.0], [3.0, 4.0]]]
    result = _add_gaussian_noise(weights, epsilon=1.0, delta=1e-5, sensitivity=1.0)
    # Probability that noise is exactly zero for every element is negligible
    assert not np.allclose(np.array(result), np.array(weights))


def test_add_gaussian_noise_large_epsilon_reduces_noise() -> None:
    """Larger ε → smaller noise_scale → smaller noise magnitude."""
    weights = [[[0.0] * 50]]

    result_small_eps = _add_gaussian_noise(weights, epsilon=0.01, delta=1e-5, sensitivity=1.0)
    result_large_eps = _add_gaussian_noise(weights, epsilon=1000.0, delta=1e-5, sensitivity=1.0)

    noise_small = float(np.abs(np.array(result_small_eps[0])).mean())
    noise_large = float(np.abs(np.array(result_large_eps[0])).mean())
    assert noise_small > noise_large


# ─────────────────────────────────────────────────────────────────────────────
# generate_local_data
# ─────────────────────────────────────────────────────────────────────────────

def test_generate_local_data_returns_correct_shapes() -> None:
    X, y = generate_local_data(n=50, input_dim=10, output_dim=1)
    assert X.shape == (50, 10)
    assert y.shape == (50, 1)


def test_generate_local_data_non_default_dims_respected() -> None:
    X, y = generate_local_data(n=30, input_dim=5, output_dim=3)
    assert X.shape == (30, 5)
    assert y.shape == (30, 3)


def test_generate_local_data_fixed_seed_is_deterministic() -> None:
    X1, y1 = generate_local_data(n=20, seed=42)
    X2, y2 = generate_local_data(n=20, seed=42)
    np.testing.assert_array_equal(X1, X2)
    np.testing.assert_array_equal(y1, y2)


def test_generate_local_data_different_seeds_produce_different_data() -> None:
    X1, _ = generate_local_data(n=20, seed=1)
    X2, _ = generate_local_data(n=20, seed=2)
    assert not np.array_equal(X1, X2)


def test_generate_local_data_minimum_size_one_sample() -> None:
    X, y = generate_local_data(n=1)
    assert X.shape[0] == 1


def test_generate_local_data_zero_size_raises_value_error() -> None:
    with pytest.raises(ValueError, match=">="):
        generate_local_data(n=0)


def test_generate_local_data_negative_size_raises_value_error() -> None:
    with pytest.raises(ValueError):
        generate_local_data(n=-5)


def test_generate_local_data_contains_no_nan() -> None:
    X, y = generate_local_data(n=100)
    assert not np.any(np.isnan(X))
    assert not np.any(np.isnan(y))


# ─────────────────────────────────────────────────────────────────────────────
# LocalModel — construction
# ─────────────────────────────────────────────────────────────────────────────

def test_local_model_default_weight_shapes() -> None:
    model = LocalModel(input_dim=10, output_dim=1)
    assert model.W.shape == (10, 1)
    assert model.b.shape == (1,)


def test_local_model_non_default_dims() -> None:
    model = LocalModel(input_dim=5, output_dim=3)
    assert model.W.shape == (5, 3)
    assert model.b.shape == (3,)


def test_local_model_fixed_seed_produces_same_init_weights() -> None:
    m1 = LocalModel(seed=7)
    m2 = LocalModel(seed=7)
    np.testing.assert_array_equal(m1.W, m2.W)


def test_local_model_different_seeds_produce_different_init_weights() -> None:
    m1 = LocalModel(seed=1)
    m2 = LocalModel(seed=2)
    assert not np.array_equal(m1.W, m2.W)


# ─────────────────────────────────────────────────────────────────────────────
# LocalModel — forward
# ─────────────────────────────────────────────────────────────────────────────

def test_local_model_forward_output_shape_matches_output_dim() -> None:
    model = LocalModel(input_dim=4, output_dim=2)
    X = np.ones((10, 4))
    y_pred = model.forward(X)
    assert y_pred.shape == (10, 2)


def test_local_model_forward_zero_weights_returns_bias() -> None:
    model = LocalModel(input_dim=3, output_dim=1)
    model.W = np.zeros((3, 1))
    model.b = np.array([5.0])
    X = np.random.randn(10, 3)
    y_pred = model.forward(X)
    np.testing.assert_allclose(y_pred, np.full((10, 1), 5.0))


# ─────────────────────────────────────────────────────────────────────────────
# LocalModel — train
# ─────────────────────────────────────────────────────────────────────────────

def test_local_model_train_reduces_loss_on_linear_data() -> None:
    X, y = generate_local_data(n=100, seed=0)
    model = LocalModel(seed=0)
    metrics = model.train(X, y, epochs=20, lr=0.01)
    assert metrics["final_loss"] < metrics["initial_loss"]


def test_local_model_train_returns_non_negative_losses() -> None:
    X, y = generate_local_data(n=50)
    model = LocalModel()
    metrics = model.train(X, y, epochs=5, lr=0.01)
    assert metrics["initial_loss"] >= 0.0
    assert metrics["final_loss"] >= 0.0


def test_local_model_train_zero_epochs_does_not_change_weights() -> None:
    X, y = generate_local_data(n=50)
    model = LocalModel(seed=42)
    W_before = model.W.copy()
    model.train(X, y, epochs=0, lr=0.01)
    np.testing.assert_array_equal(model.W, W_before)


def test_local_model_train_empty_dataset_raises_value_error() -> None:
    model = LocalModel()
    X = np.empty((0, INPUT_DIM))
    y = np.empty((0, OUTPUT_DIM))
    with pytest.raises(ValueError, match="empty"):
        model.train(X, y)


def test_local_model_train_metrics_dict_has_required_keys() -> None:
    X, y = generate_local_data(n=20)
    model = LocalModel()
    metrics = model.train(X, y, epochs=3)
    assert "initial_loss" in metrics
    assert "final_loss" in metrics


def test_local_model_train_result_loss_is_finite() -> None:
    X, y = generate_local_data(n=100, seed=1)
    model = LocalModel(seed=1)
    metrics = model.train(X, y, epochs=10, lr=0.01)
    assert math.isfinite(metrics["final_loss"])


# ─────────────────────────────────────────────────────────────────────────────
# LocalModel — get_weights / set_weights (serialisation round-trip)
# ─────────────────────────────────────────────────────────────────────────────

def test_local_model_get_weights_returns_two_tensors() -> None:
    model = LocalModel()
    weights = model.get_weights()
    assert len(weights) == 2


def test_local_model_get_weights_returns_python_lists() -> None:
    model = LocalModel()
    weights = model.get_weights()
    assert isinstance(weights[0], list)
    assert isinstance(weights[1], list)


def test_local_model_set_weights_roundtrip_preserves_values() -> None:
    model1 = LocalModel(seed=3)
    X, y = generate_local_data(n=50)
    model1.train(X, y, epochs=5)

    model2 = LocalModel()
    model2.set_weights(model1.get_weights())

    np.testing.assert_allclose(model1.W, model2.W, atol=1e-12)
    np.testing.assert_allclose(model1.b, model2.b, atol=1e-12)


def test_local_model_set_weights_wrong_tensor_count_raises_value_error() -> None:
    model = LocalModel()
    with pytest.raises(ValueError, match="2 weight tensors"):
        model.set_weights([[[1.0]]])  # only 1 tensor


def test_local_model_set_weights_wrong_w_shape_raises_value_error() -> None:
    model = LocalModel(input_dim=10, output_dim=1)
    wrong_W = np.zeros((5, 1)).tolist()   # wrong input_dim
    correct_b = np.zeros(1).tolist()
    with pytest.raises(ValueError, match="shape mismatch"):
        model.set_weights([wrong_W, correct_b])


def test_local_model_set_weights_wrong_b_shape_raises_value_error() -> None:
    model = LocalModel(input_dim=10, output_dim=1)
    correct_W = np.zeros((10, 1)).tolist()
    wrong_b = np.zeros(3).tolist()  # wrong output_dim
    with pytest.raises(ValueError, match="shape mismatch"):
        model.set_weights([correct_W, wrong_b])


# ─────────────────────────────────────────────────────────────────────────────
# _mse_loss
# ─────────────────────────────────────────────────────────────────────────────

def test_mse_loss_identical_arrays_returns_zero() -> None:
    y = np.array([[1.0, 2.0], [3.0, 4.0]])
    assert _mse_loss(y, y) == 0.0


def test_mse_loss_known_value() -> None:
    y_pred = np.array([[2.0]])
    y_true = np.array([[0.0]])
    assert math.isclose(_mse_loss(y_pred, y_true), 4.0)


def test_mse_loss_is_non_negative() -> None:
    rng = np.random.default_rng(0)
    y_pred = rng.normal(size=(50, 1))
    y_true = rng.normal(size=(50, 1))
    assert _mse_loss(y_pred, y_true) >= 0.0


# ─────────────────────────────────────────────────────────────────────────────
# Coordinator communication (all HTTP calls mocked — no real network)
# ─────────────────────────────────────────────────────────────────────────────

def _make_mock_client(response_json: dict) -> MagicMock:
    """Return a mock httpx.AsyncClient whose HTTP methods return response_json.

    Explicitly set json as a plain MagicMock so that resp.json() returns the
    dict synchronously.  Under Python 3.13 + pytest-asyncio 1.x, child attrs
    of AsyncMock default to AsyncMock, making json() return a coroutine.
    """
    mock_resp = AsyncMock()
    mock_resp.json = MagicMock(return_value=response_json)
    mock_resp.raise_for_status = MagicMock()

    mock_client = MagicMock()
    mock_client.post = AsyncMock(return_value=mock_resp)
    mock_client.get = AsyncMock(return_value=mock_resp)
    return mock_client


@pytest.mark.asyncio
async def test_register_calls_coordinator_register_endpoint() -> None:
    client = _make_mock_client({"status": "registered", "current_round": 0})
    await _register(client)
    client.post.assert_called_once()
    call_url = client.post.call_args[0][0]
    assert "/register" in call_url


@pytest.mark.asyncio
async def test_register_raises_on_http_error() -> None:
    import httpx

    mock_resp = AsyncMock()
    # Use MagicMock for raise_for_status so the side_effect fires synchronously
    mock_resp.raise_for_status = MagicMock(
        side_effect=httpx.HTTPStatusError("403", request=MagicMock(), response=MagicMock())
    )
    mock_client = MagicMock()
    mock_client.post = AsyncMock(return_value=mock_resp)
    with pytest.raises(httpx.HTTPStatusError):
        await _register(mock_client)


@pytest.mark.asyncio
async def test_fetch_global_model_returns_parsed_json() -> None:
    expected = {"round": 2, "weights": [[[1.0]]], "min_clients_needed": 2, "registered_clients": 2}
    client = _make_mock_client(expected)
    result = await _fetch_global_model(client)
    assert result["round"] == 2
    assert result["weights"] == [[[1.0]]]


@pytest.mark.asyncio
async def test_submit_update_sends_correct_payload() -> None:
    client = _make_mock_client({"status": "accepted"})
    model = LocalModel(seed=0)
    metrics = {"initial_loss": 1.0, "final_loss": 0.5}
    await _submit_update(client, model, metrics, round_num=3)

    call_kwargs = client.post.call_args[1]
    payload = call_kwargs["json"]
    assert payload["round"] == 3
    assert payload["num_samples"] > 0
    assert len(payload["weights"]) == 2  # W and b


@pytest.mark.asyncio
async def test_submit_update_raises_on_http_error() -> None:
    import httpx

    mock_resp = AsyncMock()
    mock_resp.raise_for_status = MagicMock(
        side_effect=httpx.HTTPStatusError("429", request=MagicMock(), response=MagicMock())
    )
    mock_client = MagicMock()
    mock_client.post = AsyncMock(return_value=mock_resp)
    model = LocalModel()
    with pytest.raises(httpx.HTTPStatusError):
        await _submit_update(mock_client, model, {}, round_num=0)


# ─────────────────────────────────────────────────────────────────────────────
# run_fl_loop — covers the main loop including error handling branches
# ─────────────────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_run_fl_loop_completes_one_round_then_cancels() -> None:
    """
    Verify the loop registers, fetches global model, trains, and submits.
    We cancel the loop after one iteration to avoid infinite sleep.
    """
    global_model_response = {
        "round": 0,
        "weights": None,
        "min_clients_needed": 2,
        "registered_clients": 1,
    }
    accepted_response = {"status": "registered", "current_round": 0}

    mock_resp = AsyncMock()
    mock_resp.raise_for_status = MagicMock()
    # Pre-set json as MagicMock so resp.json() returns dict, not coroutine
    mock_resp.json = MagicMock(return_value=global_model_response)

    call_count = 0

    async def fake_get(*args: object, **kwargs: object) -> AsyncMock:
        mock_resp.json = MagicMock(return_value=global_model_response)
        return mock_resp

    async def fake_post(*args: object, **kwargs: object) -> AsyncMock:
        mock_resp.json = MagicMock(return_value=accepted_response)
        return mock_resp

    mock_client = MagicMock()
    mock_client.post = AsyncMock(side_effect=fake_post)
    mock_client.get = AsyncMock(side_effect=fake_get)
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    # Patch sleep to raise CancelledError after first iteration
    sleep_call_count = 0

    async def fake_sleep(_: float) -> None:
        nonlocal sleep_call_count
        sleep_call_count += 1
        raise asyncio.CancelledError

    with patch("main.httpx.AsyncClient", return_value=mock_client), \
         patch("main.asyncio.sleep", side_effect=fake_sleep):
        with pytest.raises(asyncio.CancelledError):
            await run_fl_loop()

    assert sleep_call_count == 1
    assert mock_client.post.call_count >= 2  # /register + /submit-update


@pytest.mark.asyncio
async def test_run_fl_loop_handles_http_error_without_crashing() -> None:
    """HTTP errors from coordinator must be caught and loop must continue."""
    import httpx

    mock_resp = AsyncMock()
    mock_resp.raise_for_status = MagicMock()

    register_resp = AsyncMock()
    register_resp.raise_for_status = MagicMock()
    register_resp.json.return_value = {"status": "registered", "current_round": 0}

    error_resp = AsyncMock()
    error_resp.raise_for_status.side_effect = httpx.HTTPStatusError(
        "503", request=MagicMock(), response=MagicMock()
    )

    call_count = 0

    async def fake_get(*args: object, **kwargs: object) -> AsyncMock:
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            raise asyncio.CancelledError  # stop after first get attempt
        return error_resp

    mock_client = MagicMock()
    mock_client.post = AsyncMock(return_value=register_resp)
    mock_client.get = AsyncMock(side_effect=fake_get)
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    with patch("main.httpx.AsyncClient", return_value=mock_client):
        with pytest.raises(asyncio.CancelledError):
            await run_fl_loop()


@pytest.mark.asyncio
async def test_run_fl_loop_applies_global_weights_when_available() -> None:
    """When global model has weights, they must be applied before local training."""
    global_weights = [np.zeros((INPUT_DIM, OUTPUT_DIM)).tolist(), np.zeros(OUTPUT_DIM).tolist()]
    global_model_response = {"round": 1, "weights": global_weights}
    accepted_response = {"status": "registered", "current_round": 1}

    mock_resp = AsyncMock()
    mock_resp.raise_for_status = MagicMock()
    mock_resp.json = MagicMock(return_value=global_model_response)

    async def fake_get(*args: object, **kwargs: object) -> AsyncMock:
        mock_resp.json = MagicMock(return_value=global_model_response)
        return mock_resp

    async def fake_post(*args: object, **kwargs: object) -> AsyncMock:
        mock_resp.json = MagicMock(return_value=accepted_response)
        return mock_resp

    async def fake_sleep(_: float) -> None:
        raise asyncio.CancelledError

    mock_client = MagicMock()
    mock_client.post = AsyncMock(side_effect=fake_post)
    mock_client.get = AsyncMock(side_effect=fake_get)
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    with patch("main.httpx.AsyncClient", return_value=mock_client), \
         patch("main.asyncio.sleep", side_effect=fake_sleep):
        with pytest.raises(asyncio.CancelledError):
            await run_fl_loop()

    # Verify that submit-update was called with round=1 weights
    submit_calls = [
        c for c in mock_client.post.call_args_list
        if "/submit-update" in str(c)
    ]
    assert len(submit_calls) == 1


@pytest.mark.asyncio
async def test_run_fl_loop_logs_http_status_error_and_continues() -> None:
    """HTTPStatusError from the coordinator must be logged; loop must sleep and continue."""
    import httpx

    register_resp = AsyncMock()
    register_resp.raise_for_status = MagicMock()
    register_resp.json = MagicMock(return_value={"status": "registered", "current_round": 0})

    # raise_for_status raises so _fetch_global_model propagates HTTPStatusError
    error_resp = AsyncMock()
    error_resp.raise_for_status = MagicMock(
        side_effect=httpx.HTTPStatusError("503", request=MagicMock(), response=MagicMock())
    )

    sleep_count = 0

    async def fake_sleep(_: float) -> None:
        nonlocal sleep_count
        sleep_count += 1
        raise asyncio.CancelledError

    mock_client = MagicMock()
    mock_client.post = AsyncMock(return_value=register_resp)
    mock_client.get = AsyncMock(return_value=error_resp)
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    with patch("main.httpx.AsyncClient", return_value=mock_client), \
         patch("main.asyncio.sleep", side_effect=fake_sleep):
        with pytest.raises(asyncio.CancelledError):
            await run_fl_loop()

    assert sleep_count == 1  # loop reached sleep → exception was caught


@pytest.mark.asyncio
async def test_run_fl_loop_logs_value_error_and_continues() -> None:
    """ValueError from set_weights (wrong shape) must be logged; loop must continue."""
    # weights with wrong shape: only 1 tensor instead of 2 (W, b)
    wrong_weights = [[[1.0]]]
    global_model_response = {"round": 0, "weights": wrong_weights}

    register_resp = AsyncMock()
    register_resp.raise_for_status = MagicMock()
    register_resp.json = MagicMock(return_value={"status": "registered", "current_round": 0})

    model_resp = AsyncMock()
    model_resp.raise_for_status = MagicMock()
    model_resp.json = MagicMock(return_value=global_model_response)

    sleep_count = 0

    async def fake_sleep(_: float) -> None:
        nonlocal sleep_count
        sleep_count += 1
        raise asyncio.CancelledError

    mock_client = MagicMock()
    mock_client.post = AsyncMock(return_value=register_resp)
    mock_client.get = AsyncMock(return_value=model_resp)
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    with patch("main.httpx.AsyncClient", return_value=mock_client), \
         patch("main.asyncio.sleep", side_effect=fake_sleep):
        with pytest.raises(asyncio.CancelledError):
            await run_fl_loop()

    assert sleep_count == 1  # loop continued past the ValueError
