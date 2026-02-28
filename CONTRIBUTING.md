# Contributing & Engineering Standards

This document defines the non-negotiable quality bar for every change to this repository.
Code is reviewed as if it will be read by a distributed systems expert and a security researcher simultaneously.

---

## Mandatory Workflow

### Before writing any code

1. Read **all** existing files in the affected directory
2. State your plan in one paragraph — what changes, what breaks, why this approach
3. Identify which existing tests will be affected

### For every change

1. Write the **test first** (TDD)
2. Run existing tests — confirm they pass before your change
3. Implement the code
4. Run **all** tests again — zero regressions allowed
5. Fix the code if a test fails — never fix the test to hide a real bug

### After every change

```bash
ruff check . && ruff format --check .   # Python linting + formatting
mypy --strict <changed_file>            # type checking
bandit -r services/                     # security scan
```

A change is not done until all three pass with zero errors.

---

## Definition of Done

A task is **DONE** only when all boxes are checked:

- [ ] All new code has tests (happy path + edge case + failure case)
- [ ] All existing tests still pass
- [ ] `ruff check` returns 0 errors
- [ ] `mypy --strict` returns 0 errors
- [ ] `bandit` returns no HIGH or MEDIUM findings
- [ ] No hardcoded secrets, URLs, or magic numbers
- [ ] README updated if observable behaviour changed
- [ ] `CHANGELOG.md` entry added

---

## Code Quality — Python

- **Type hints** on every function signature — no exceptions
- **Docstring** on every public function explaining *why*, not *what*
- **Maximum function length:** 40 lines — decompose if longer
- **No bare `except:`** — always catch specific exceptions (`ValueError`, `HTTPException`, etc.)
- **No hardcoded values** — use environment variables or named constants at module top
- **Async functions** must have explicit timeout handling (`asyncio.wait_for` or `httpx` timeout)
- **Logging levels:**
  - `INFO` — state changes (round completed, tenant registered)
  - `DEBUG` — data payloads (weight shapes, sample counts)
  - `ERROR` — failures requiring operator attention

### Example — correct style

```python
FL_MIN_CLIENTS: int = int(os.getenv("FL_MIN_CLIENTS", "2"))
AGGREGATION_TIMEOUT_S: float = float(os.getenv("FL_AGGREGATION_TIMEOUT_S", "30.0"))

async def aggregate_round(state: FLState) -> None:
    """
    Run one FedAvg aggregation round over all pending client updates.

    Rejects updates containing NaN weights before averaging to prevent
    gradient poisoning from a malfunctioning client.
    """
    async with asyncio.wait_for(state.round_lock.acquire(), timeout=AGGREGATION_TIMEOUT_S):
        try:
            _validate_updates(state.pending_updates)
            await _fedavg(state)
        except ValueError as exc:
            logger.error("Aggregation rejected: %s", exc)
            raise
        finally:
            state.round_lock.release()
```

---

## Code Quality — Tests

Every public function needs **at least 3 test cases**:

| Case | Description |
|------|-------------|
| Happy path | Normal input, expected output |
| Edge case | Empty input, zero samples, boundary values |
| Failure case | What happens when input is malformed or a dep fails |

### Naming convention

```
test_<function>_<condition>_<expected_result>

# Good:
test_fedavg_with_unequal_sample_sizes_weights_proportionally
test_fedavg_with_all_zero_samples_raises_value_error
test_submit_update_with_nan_weights_rejects_and_logs

# Bad:
test_aggregation
test_fedavg_works
```

### Rules

- Use `pytest` fixtures for repeated setup — no copy-paste between tests
- Mock all external services (`httpx`, `kubernetes` API) — never call real endpoints
- Minimum coverage: **80 %** per file, **90 %** for `fl-coordinator/main.py`

---

## Kubernetes / Helm Standards

Every manifest must have:

- `resources.requests` **and** `resources.limits` on every container
- `livenessProbe` **and** `readinessProbe` on every Deployment
- `NetworkPolicy` must be explicit: deny-all default, then allow only named traffic
- Secrets via `secretKeyRef` — never inline in `env[].value`
- Helm values fields must have an inline comment explaining the field

### Example — correct NetworkPolicy

```yaml
# Allow only fl-client pods in fl-enabled namespaces to reach the coordinator.
# All other ingress is denied by the cluster-wide default-deny policy.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: fl-coordinator-ingress
  namespace: fl-system
spec:
  podSelector:
    matchLabels:
      app: fl-coordinator
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              fl-enabled: "true"
          podSelector:
            matchLabels:
              component: fl-client
      ports:
        - protocol: TCP
          port: 8080
```

---

## Federated Learning — Invariants

These must **never** be violated:

| Invariant | Enforcement |
|-----------|-------------|
| Coordinator stores no raw data between rounds | `pending_updates` cleared after every `_aggregate()` call |
| NaN weights are rejected before aggregation | `_validate_updates()` runs before FedAvg |
| Race condition on concurrent submissions is prevented | `asyncio.Lock` wraps all mutations to `pending_updates` |
| Every FL round emits Prometheus metrics | `rounds_completed`, `clients_participated`, `aggregation_duration` |
| Tenant ID validated against registered set | Check `tenant_id in state.registered_tenants` before accepting |

---

## Security Rules

- Never log the `x-fl-secret` value, even partially (`secret[:4]` is still forbidden)
- Rate-limit `/submit-update`: max 10 requests/minute per `tenant_id`
- Validate all inputs with Pydantic — no manual string parsing
- `bandit` scan must return no HIGH or MEDIUM findings before merge

---

## Commit Message Format

```
type(scope): short description (max 72 chars)

WHY this change was needed (1-3 sentences).
What alternatives were considered and why this approach was chosen.

Fixes: #issue-number  (if applicable)
```

**Types:** `feat` · `fix` · `test` · `refactor` · `perf` · `docs` · `ci` · `chore`

### Examples

```
feat(fl-coordinator): add NaN weight validation before FedAvg aggregation

Malformed weights from a buggy client can corrupt the global model silently.
Validation rejects the update and logs an error without crashing the round.
Alternative considered: clip NaN to zero — rejected because it hides client bugs.
```

```
test(fl-client): add edge case for zero-sample training round

FedAvg denominator is total_samples; zero samples causes division by zero.
This test confirms the coordinator raises ValueError and skips aggregation.
```

```
fix(networkpolicy): restrict fl-client egress to coordinator only

Without this policy, fl-client pods could reach other tenant namespaces,
violating the data isolation guarantee. Default-deny + explicit allow added.
```

---

## Changelog Format

Add an entry to `CHANGELOG.md` for every non-trivial change:

```markdown
## [Unreleased]

### Added
- NaN weight validation in FL coordinator before FedAvg aggregation (#12)

### Fixed
- NetworkPolicy now correctly restricts fl-client egress to fl-system only (#15)

### Changed
- HPA CPU threshold reduced from 70% to 40% for faster burst response in experiments (#18)
```
