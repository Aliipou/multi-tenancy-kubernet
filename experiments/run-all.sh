#!/bin/bash
# run-all.sh — Run every benchmark experiment in sequence.
# Usage: ./experiments/run-all.sh [duration_seconds] [concurrency]

set -euo pipefail

DURATION=${1:-60}
CONCURRENCY=${2:-50}
ROOT="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SUMMARY_DIR="$ROOT/results/run_all_$TIMESTAMP"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

mkdir -p "$SUMMARY_DIR"

EXPERIMENTS=(baseline cpu_contention memory_pressure hpa_burst comparison_node_isolation)
PASSED=()
FAILED=()

log "Starting full benchmark suite — duration=${DURATION}s concurrency=${CONCURRENCY}"
log "Results: $SUMMARY_DIR"
echo ""

for exp in "${EXPERIMENTS[@]}"; do
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Running: $exp"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if bash "$ROOT/$exp/run.sh" "$DURATION" "$CONCURRENCY" \
       2>&1 | tee "$SUMMARY_DIR/${exp}.log"; then
    PASSED+=("$exp")
    log "PASS: $exp"
  else
    FAILED+=("$exp")
    fail "FAIL: $exp  (log: $SUMMARY_DIR/${exp}.log)"
  fi
  echo ""
done

# Copy the latest results.json from each experiment into the summary dir
for exp in "${EXPERIMENTS[@]}"; do
  latest=$(find "$ROOT/$exp" -name "results.json" -newer "$ROOT/$exp/run.sh" 2>/dev/null \
           | sort | tail -1 || true)
  if [[ -n "$latest" ]]; then
    cp "$latest" "$SUMMARY_DIR/${exp}_results.json"
  fi
done

# Summary
echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Suite complete"
log "  Passed: ${#PASSED[@]} / ${#EXPERIMENTS[@]}"
[[ ${#FAILED[@]} -gt 0 ]] && fail "  Failed: ${FAILED[*]}"
log "  Logs  : $SUMMARY_DIR"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
