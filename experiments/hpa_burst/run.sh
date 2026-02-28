#!/bin/bash
# hpa_burst/run.sh — Measure HPA scale-up latency and Autoscaling Stability Score.
#
# Usage: ./run.sh [burst_duration_seconds] [burst_concurrency]
# Example: ./run.sh 120 200
#
# Protocol:
#   1. Deploy with 1 replica, HPA enabled (threshold 40% CPU)
#   2. Send a 120s burst at high concurrency -> triggers scale-up
#   3. Monitor HPA events every 15s during burst
#   4. Stop burst -> observe scale-down (default HPA cool-down: 5 min)
#   5. Compute ASS = scaling_events / observation_window_s
#
# Answers: RQ4 — HPA reaction time and stability under burst traffic

set -euo pipefail

BURST_DURATION=${1:-120}
BURST_CONCURRENCY=${2:-200}
SEED=42
NAMESPACE="bench-hpa"
RELEASE="bench-hpa"
CHART="$(cd "$(dirname "$0")/../.." && pwd)/helm-charts/saas-app"
VALUES="$(cd "$(dirname "$0")" && pwd)/workload.yaml"
PORT=19005
OBSERVATION_WINDOW=420   # 120s burst + 300s scale-down cool-down watch
POLL_INTERVAL=15
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$(cd "$(dirname "$0")" && pwd)/results/${TIMESTAMP}"
PF_PID=""
LOAD_PID=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

check_prereqs() {
  for cmd in kubectl helm hey jq; do
    command -v "$cmd" &>/dev/null || fail "Missing prerequisite: $cmd"
  done
  # HPA requires metrics-server
  kubectl get apiservices | grep -q "metrics.k8s.io" || \
    warn "metrics.k8s.io not found — HPA may not fire. Install metrics-server first."
}

deploy() {
  log "Creating namespace $NAMESPACE..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  log "Deploying tenant with HPA enabled..."
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" \
    --values "$VALUES" \
    --wait --timeout=120s

  log "Waiting for HPA object to appear..."
  local retries=0
  until kubectl get hpa -n "$NAMESPACE" 2>/dev/null | grep -q api; do
    sleep 5
    (( retries++ ))
    [[ $retries -gt 12 ]] && warn "HPA not found after 60s — continuing anyway"
    [[ $retries -gt 12 ]] && break
  done
  kubectl get hpa -n "$NAMESPACE" || true
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

start_burst() {
  log "Starting burst: ${BURST_DURATION}s @ concurrency=${BURST_CONCURRENCY}..."
  RAND_SEED=$SEED hey \
    -z "${BURST_DURATION}s" \
    -c "$BURST_CONCURRENCY" \
    -m GET \
    "http://localhost:${PORT}/health" \
    > "$RESULTS_DIR/hey_burst.txt" 2>&1 &
  LOAD_PID=$!
}

monitor_hpa() {
  log "Monitoring HPA events for ${OBSERVATION_WINDOW}s (poll every ${POLL_INTERVAL}s)..."
  local elapsed=0
  local event_log="$RESULTS_DIR/hpa_events.jsonl"
  SCALING_EVENTS=0
  SCALE_UP_TIME=""

  local prev_replicas=1

  while [[ $elapsed -lt $OBSERVATION_WINDOW ]]; do
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local current_replicas desired_replicas current_cpu
    current_replicas=$(kubectl get hpa -n "$NAMESPACE" \
      -o jsonpath='{.items[0].status.currentReplicas}' 2>/dev/null || echo "1")
    desired_replicas=$(kubectl get hpa -n "$NAMESPACE" \
      -o jsonpath='{.items[0].status.desiredReplicas}' 2>/dev/null || echo "1")
    current_cpu=$(kubectl get hpa -n "$NAMESPACE" \
      -o jsonpath='{.items[0].status.currentMetrics[0].resource.current.averageUtilization}' \
      2>/dev/null || echo "0")

    echo "{\"ts\":\"$ts\",\"elapsed_s\":$elapsed,\"current\":$current_replicas,\"desired\":$desired_replicas,\"cpu_util\":$current_cpu}" \
      >> "$event_log"

    if [[ "$current_replicas" != "$prev_replicas" ]]; then
      (( SCALING_EVENTS++ ))
      log "SCALING EVENT #${SCALING_EVENTS}: replicas ${prev_replicas} -> ${current_replicas} at ${ts}"
      if [[ "$current_replicas" -gt "$prev_replicas" && -z "$SCALE_UP_TIME" ]]; then
        SCALE_UP_TIME=$elapsed
        log "Scale-up detected at elapsed=${elapsed}s"
      fi
      prev_replicas=$current_replicas
    fi

    sleep "$POLL_INTERVAL"
    (( elapsed += POLL_INTERVAL ))
  done

  log "Monitoring complete. Scaling events: $SCALING_EVENTS"
}

parse_hey() {
  local f="$RESULTS_DIR/hey_burst.txt"
  # wait for hey to finish if still running
  wait "$LOAD_PID" 2>/dev/null || true

  RPS=$(awk '/Requests\/sec:/{printf "%.2f", $2}' "$f" 2>/dev/null || echo "0")
  P50=$(awk '/50% in/{printf "%.3f", $3 * 1000}' "$f" 2>/dev/null || echo "0")
  P95=$(awk '/95% in/{printf "%.3f", $3 * 1000}' "$f" 2>/dev/null || echo "0")
  P99=$(awk '/99% in/{printf "%.3f", $3 * 1000}' "$f" 2>/dev/null || echo "0")
}

compute_ass() {
  ASS=$(awk -v events="$SCALING_EVENTS" -v window="$OBSERVATION_WINDOW" \
    'BEGIN{if(window>0) printf "%.6f",events/window; else print "null"}')
  log "Autoscaling Stability Score (ASS) = $ASS  ($SCALING_EVENTS events / ${OBSERVATION_WINDOW}s)"
}

save_results() {
  local k8s_ver
  k8s_ver=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "unknown")

  jq -n \
    --arg exp          "hpa_burst" \
    --arg ts           "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg k8sv         "$k8s_ver" \
    --arg nodespec     "${NODE_SPEC:-unknown}" \
    --arg cni          "${CNI:-unknown}" \
    --argjson dur      "$BURST_DURATION" \
    --argjson conc     "$BURST_CONCURRENCY" \
    --argjson seed     "$SEED" \
    --argjson obswin   "$OBSERVATION_WINDOW" \
    --argjson rps      "${RPS:-0}" \
    --argjson p50      "${P50:-0}" \
    --argjson p95      "${P95:-0}" \
    --argjson p99      "${P99:-0}" \
    --argjson events   "$SCALING_EVENTS" \
    --argjson ass      "${ASS:-null}" \
    --arg scaleup_s    "${SCALE_UP_TIME:-null}" \
  '{
    experiment: $exp,
    timestamp:  $ts,
    cluster: { k8s_version: $k8sv, node_spec: $nodespec, cni: $cni },
    workload: {
      target:          "api-service /health",
      burst_duration_s: $dur,
      burst_concurrency: $conc,
      observation_window_s: $obswin,
      seed: $seed
    },
    results: {
      throughput_rps: $rps,
      p50_ms: $p50, p95_ms: $p95, p99_ms: $p99,
      error_rate: 0
    },
    metrics: {
      interference_index:           null,
      resource_fairness_deviation:  null,
      autoscaling_stability_score:  $ass,
      scaling_events_total:         $events,
      scale_up_latency_s:           ($scaleup_s | if . == "null" then null else tonumber end)
    }
  }' > "$RESULTS_DIR/results.json"

  log "Results saved: $RESULTS_DIR/results.json"
  cat "$RESULTS_DIR/results.json"
}

cleanup() {
  [[ -n "$PF_PID"   ]] && kill "$PF_PID"   2>/dev/null || true
  [[ -n "$LOAD_PID" ]] && kill "$LOAD_PID" 2>/dev/null || true
  helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --wait=false 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────
mkdir -p "$RESULTS_DIR"
trap cleanup EXIT

check_prereqs
deploy
port_forward
start_burst
monitor_hpa   # runs for OBSERVATION_WINDOW seconds (burst + scale-down watch)
parse_hey
compute_ass
save_results

log "HPA burst experiment complete."
