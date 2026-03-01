"""
Pytest configuration for FL coordinator tests.

Sets FL_SHARED_SECRET before the app module is imported so the
verify_fl_secret dependency reads the test value, not the default.
"""

import os
import sys
import time

# ── Windows compatibility fix ────────────────────────────────────────────────
# prometheus_client imports resource.getpagesize() which is not available in
# the Windows stub of the resource module (Python 3.13+).  Patch it before
# the package is first imported so the AttributeError is never raised.
if sys.platform == "win32":
    import resource  # noqa: F401  (stub module, always importable on Win32)
    if not hasattr(resource, "getpagesize"):
        resource.getpagesize = lambda: 4096  # type: ignore[attr-defined]

# Must be set before importing main
os.environ["FL_SHARED_SECRET"] = "test-secret"
os.environ["FL_MIN_CLIENTS"] = "2"

import pytest
from main import _billing, _rate_windows, state  # noqa: E402 — intentional post-env-set import


@pytest.fixture(autouse=True)
def reset_fl_state() -> None:
    """
    Reset all mutable FL state between tests.

    Without this, a test that triggers aggregation would leave round=1,
    causing every subsequent test that submits to round=0 to get a 409.
    Also resets last_aggregation_time and billing so watchdog and metering
    tests start from a known baseline.
    """
    state.round = 0
    state.global_weights = None
    state.pending_updates.clear()
    state.registered_tenants.clear()
    state.last_aggregation_time = time.monotonic()
    _rate_windows.clear()
    _billing.clear()
    yield
    state.round = 0
    state.global_weights = None
    state.pending_updates.clear()
    state.registered_tenants.clear()
    state.last_aggregation_time = time.monotonic()
    _rate_windows.clear()
    _billing.clear()
