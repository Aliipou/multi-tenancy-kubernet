#!/bin/bash
# baseline/run.sh — Measure clean throughput and latency with no contention.
#
# Usage: ./run.sh [duration_seconds] [concurrency]
# Example: ./run.sh 60 50
#
# Answers: RQ3 — What are baseline response time and throughput characteristics?

set -euo pipefail

DURATION=${1:-60}
CONCURRENCY=${2:-50}
SEED=42
NAMESPACE="bench-baseline"
RELEASE="bench-baseline"
CHART="$(cd "$(dirname "$0")/../.." && pwd)/helm-charts/saas-app"
VALUES="$(cd "$(dirname "$0")" && pwd)/workload.yaml"
PORT=19002
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$(cd "$(dirname "$0")" && pwd)/results/${TIMESTAMP}"
PF_PID=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

check_prereqs() {
  for cmd in kubectl helm hey jq; do
    command -v "$cmd" &>/dev/null || fail "Missing prerequisite: $cmd"
  done
  [[ -d "$CHART" ]] || fail "Helm chart not found: $CHART"
}

deploy() {
  log "Creating namespace $NAMESPACE..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  log "Deploying Helm release $RELEASE..."
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" \
    --values "$VALUES" \
    --wait --timeout=120s
}

wait_ready() {
  log "Waiting for all deployments to be ready..."
  kubectl rollout status deployment --namespace "$NAMESPACE" --timeout=90s
  sleep 5  # allow readiness probes to settle
}

port_forward() {
  local svc
  svc=$(kubectl get svc -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=api-service" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$svc" ]]; then
    warn "Could not auto-detect API service name, trying release-based name..."
    svc="${RELEASE}-api"
  fi

  log "Port-forwarding $svc -> localhost:${PORT}..."
  kubectl port-forward -n "$NAMESPACE" "svc/${svc}" "${PORT}:3002" &
  PF_PID=$!
  sleep 3
}

run_loadtest() {
  log "Warm-up: 10 s @ concurrency=10..."
  hey -z 10s -c 10 "http://localhost:${PORT}/health" > /dev/null 2>&1 || true
  sleep 2

  log "Load test: ${DURATION}s @ concurrency=${CONCURRENCY} (seed=${SEED})..."
  RAND_SEED=$SEED hey \
    -z "${DURATION}s" \
    -c "$CONCURRENCY" \
    -m GET \
    "http://localhost:${PORT}/health" \
    > "$RESULTS_DIR/hey_output.txt" 2>&1

  log "Load test complete."
  cat "$RESULTS_DIR/hey_output.txt"
}

parse_hey() {
  local f="$RESULTS_DIR/hey_output.txt"
  RPS=$(awk '/Requests\/sec:/{printf "%.2f", $2}' "$f")
  P50=$(awk '/50% in/{printf "%.3f", $3 * 1000}' "$f")
  P95=$(awk '/95% in/{printf "%.3f", $3 * 1000}' "$f")
  P99=$(awk '/99% in/{printf "%.3f", $3 * 1000}' "$f")
  ERRORS=$(awk '/\[4[0-9]{2}\]|^\[5[0-9]{2}\]/{s+=$1} END{print s+0}' "$f")
  TOTAL=$(awk '/Total:/{printf "%d", $2 * '$CONCURRENCY'}' "$f" 2>/dev/null || echo "0")
  ERROR_RATE=$(awk -v e="$ERRORS" -v t="$TOTAL" 'BEGIN{if(t>0) printf "%.4f",e/t; else print "0"}')
}

collect_rfd() {
  log "Collecting CPU usage for RFD (10 s sample)..."
  sleep 10
  CPU_ACTUAL=$(kubectl top pods -n "$NAMESPACE" \
    --selector="app.kubernetes.io/component=api-service" \
    --no-headers 2>/dev/null | awk '{sum+=$2} END{print sum+0}' | tr -d 'm' || echo "0")
  CPU_REQ=200  # millicores from workload.yaml
  RFD=$(awk -v actual="$CPU_ACTUAL" -v req="$CPU_REQ" \
    'BEGIN{if(req>0) printf "%.4f", (actual-req<0?req-actual:actual-req)/req; else print "null"}')
}

save_results() {
  local k8s_ver
  k8s_ver=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "unknown")
  local node_spec="${NODE_SPEC:-unknown}"
  local cni="${CNI:-unknown}"

  jq -n \
    --arg exp        "baseline" \
    --arg ts         "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg k8sv       "$k8s_ver" \
    --arg nodespec   "$node_spec" \
    --arg cni        "$cni" \
    --arg target     "api-service /health" \
    --argjson dur    "$DURATION" \
    --argjson conc   "$CONCURRENCY" \
    --argjson seed   "$SEED" \
    --argjson rps    "${RPS:-0}" \
    --argjson p50    "${P50:-0}" \
    --argjson p95    "${P95:-0}" \
    --argjson p99    "${P99:-0}" \
    --argjson err    "${ERROR_RATE:-0}" \
    --argjson rfd    "${RFD:-null}" \
  '{
    experiment: $exp,
    timestamp:  $ts,
    cluster: { k8s_version: $k8sv, node_spec: $nodespec, cni: $cni },
    workload: { target: $target, duration_s: $dur, concurrency: $conc, seed: $seed },
    results: {
      throughput_rps: $rps,
      p50_ms: $p50,
      p95_ms: $p95,
      p99_ms: $p99,
      error_rate: $err
    },
    metrics: {
      interference_index:          null,
      resource_fairness_deviation: $rfd,
      autoscaling_stability_score: null
    }
  }' > "$RESULTS_DIR/results.json"

  log "Results saved: $RESULTS_DIR/results.json"
  cat "$RESULTS_DIR/results.json"
}

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  log "Removing namespace $NAMESPACE..."
  helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --wait=false 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────
mkdir -p "$RESULTS_DIR"
trap cleanup EXIT

check_prereqs
deploy
wait_ready
port_forward
run_loadtest
parse_hey
collect_rfd
save_results

log "Baseline experiment complete."
