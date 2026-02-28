#!/bin/bash
# cpu_contention/run.sh — Measure Interference Index under a CPU aggressor.
#
# Usage: ./run.sh [duration_seconds] [concurrency] [baseline_results.json]
# Example: ./run.sh 60 50 ../baseline/results/20260228_090000/results.json
#
# Answers: RQ2 — Can namespace isolation prevent resource interference?
#          RQ3 — What is the performance overhead of resource contention?

set -euo pipefail

DURATION=${1:-60}
CONCURRENCY=${2:-50}
BASELINE_JSON=${3:-""}
SEED=42
NAMESPACE="bench-cpu"
RELEASE="bench-cpu"
CHART="$(cd "$(dirname "$0")/../.." && pwd)/helm-charts/saas-app"
VALUES="$(cd "$(dirname "$0")" && pwd)/workload.yaml"
STRESS_MANIFEST="$(cd "$(dirname "$0")" && pwd)/stress-profile.yaml"
PORT=19003
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
}

deploy() {
  log "Creating namespace $NAMESPACE..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  log "Deploying victim tenant..."
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" \
    --values "$VALUES" \
    --wait --timeout=120s

  log "Deploying CPU aggressor..."
  kubectl apply -f "$STRESS_MANIFEST"

  log "Waiting for aggressor to become Running..."
  kubectl rollout status deployment/cpu-aggressor -n "$NAMESPACE" --timeout=60s
  sleep 5  # let aggressor fully saturate CPU before measuring
}

wait_ready() {
  kubectl rollout status deployment --namespace "$NAMESPACE" --timeout=90s
  sleep 5
}

port_forward() {
  local svc
  svc=$(kubectl get svc -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=api-service" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "${RELEASE}-api")

  log "Port-forwarding $svc -> localhost:${PORT}..."
  kubectl port-forward -n "$NAMESPACE" "svc/${svc}" "${PORT}:3002" &
  PF_PID=$!
  sleep 3
}

run_loadtest() {
  log "Warm-up: 10s..."
  hey -z 10s -c 10 "http://localhost:${PORT}/health" > /dev/null 2>&1 || true
  sleep 2

  log "Load test under CPU stress: ${DURATION}s @ concurrency=${CONCURRENCY}..."
  RAND_SEED=$SEED hey \
    -z "${DURATION}s" \
    -c "$CONCURRENCY" \
    -m GET \
    "http://localhost:${PORT}/health" \
    > "$RESULTS_DIR/hey_output.txt" 2>&1

  cat "$RESULTS_DIR/hey_output.txt"
}

parse_hey() {
  local f="$RESULTS_DIR/hey_output.txt"
  RPS=$(awk '/Requests\/sec:/{printf "%.2f", $2}' "$f")
  P50=$(awk '/50% in/{printf "%.3f", $3 * 1000}' "$f")
  P95=$(awk '/95% in/{printf "%.3f", $3 * 1000}' "$f")
  P99=$(awk '/99% in/{printf "%.3f", $3 * 1000}' "$f")
  ERRORS=$(awk '/\[4[0-9]{2}\]|^\[5[0-9]{2}\]/{s+=$1} END{print s+0}' "$f")
  TOTAL=$(awk '/Total:/{t=$2} /Requests\/sec:/{r=$2} END{printf "%d", t*r}' "$f" 2>/dev/null || echo "1")
  ERROR_RATE=$(awk -v e="$ERRORS" -v t="$TOTAL" 'BEGIN{if(t>0) printf "%.4f",e/t; else print "0"}')
}

compute_ii() {
  if [[ -n "$BASELINE_JSON" && -f "$BASELINE_JSON" ]]; then
    P95_BASE=$(jq -r '.results.p95_ms' "$BASELINE_JSON")
    II=$(awk -v base="$P95_BASE" -v stress="$P95" \
      'BEGIN{if(base>0) printf "%.4f",(stress-base)/base; else print "null"}')
    log "Interference Index (II) = $II  (P95: ${P95_BASE}ms -> ${P95}ms)"
  else
    warn "No baseline JSON provided — II will be null. Pass path as 3rd argument."
    II="null"
  fi
}

collect_node_metrics() {
  log "Sampling node CPU pressure..."
  kubectl top node 2>/dev/null > "$RESULTS_DIR/node-top.txt" || warn "metrics-server not available"
  kubectl top pods -n "$NAMESPACE" 2>/dev/null > "$RESULTS_DIR/pod-top.txt" || true
}

save_results() {
  local k8s_ver
  k8s_ver=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "unknown")

  jq -n \
    --arg exp      "cpu_contention" \
    --arg ts       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg k8sv     "$k8s_ver" \
    --arg nodespec "${NODE_SPEC:-unknown}" \
    --arg cni      "${CNI:-unknown}" \
    --argjson dur  "$DURATION" \
    --argjson conc "$CONCURRENCY" \
    --argjson seed "$SEED" \
    --argjson rps  "${RPS:-0}" \
    --argjson p50  "${P50:-0}" \
    --argjson p95  "${P95:-0}" \
    --argjson p99  "${P99:-0}" \
    --argjson err  "${ERROR_RATE:-0}" \
    --argjson ii   "${II:-null}" \
  '{
    experiment: $exp,
    timestamp:  $ts,
    cluster: { k8s_version: $k8sv, node_spec: $nodespec, cni: $cni },
    workload: {
      target: "api-service /health (with cpu-aggressor running in same namespace)",
      duration_s: $dur, concurrency: $conc, seed: $seed
    },
    results: {
      throughput_rps: $rps,
      p50_ms: $p50, p95_ms: $p95, p99_ms: $p99,
      error_rate: $err
    },
    metrics: {
      interference_index:          $ii,
      resource_fairness_deviation: null,
      autoscaling_stability_score: null
    }
  }' > "$RESULTS_DIR/results.json"

  log "Results saved: $RESULTS_DIR/results.json"
  cat "$RESULTS_DIR/results.json"
}

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  kubectl delete -f "$STRESS_MANIFEST" 2>/dev/null || true
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
collect_node_metrics
run_loadtest
parse_hey
compute_ii
save_results

log "CPU contention experiment complete."
