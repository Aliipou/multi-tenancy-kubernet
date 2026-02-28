"""
Pytest configuration for FL coordinator tests.

Sets FL_SHARED_SECRET before the app module is imported so the
verify_fl_secret dependency reads the test value, not the default.
"""

import os

# Must be set before importing main
os.environ["FL_SHARED_SECRET"] = "test-secret"
os.environ["FL_MIN_CLIENTS"] = "2"

import pytest
from main import _rate_windows, state  # noqa: E402 — intentional post-env-set import


@pytest.fixture(autouse=True)
def reset_fl_state() -> None:
    """
    Reset all mutable FL state between tests.

    Without this, a test that triggers aggregation would leave round=1,
    causing every subsequent test that submits to round=0 to get a 409.
    """
    state.round = 0
    state.global_weights = None
    state.pending_updates.clear()
    state.registered_tenants.clear()
    _rate_windows.clear()
    yield
    state.round = 0
    state.global_weights = None
    state.pending_updates.clear()
    state.registered_tenants.clear()
    _rate_windows.clear()
