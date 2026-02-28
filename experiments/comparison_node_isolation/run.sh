#!/bin/bash
# comparison_node_isolation/run.sh — Compare II between namespace and node isolation.
#
# Usage: ./run.sh [duration_seconds] [concurrency]
# Example: ./run.sh 60 50
#
# Runs two sequential arms:
#   Arm A — namespace-only isolation (aggressor co-located on same node)
#   Arm B — node-level isolation (aggressor on a separate node via nodeSelector)
#
# Requires a 2-node cluster for Arm B to be meaningful.
# On a 1-node cluster, Arm B produces a WARNING and is skipped.
#
# Answers: RQ5 — Is namespace isolation sufficient vs dedicated node isolation?

set -euo pipefail

DURATION=${1:-60}
CONCURRENCY=${2:-50}
SEED=42
CHART="$(cd "$(dirname "$0")/../.." && pwd)/helm-charts/saas-app"
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT_A=19006
PORT_B=19007
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$DIR/results/${TIMESTAMP}"
PF_PID_A=""
PF_PID_B=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

check_prereqs() {
  for cmd in kubectl helm hey jq; do
    command -v "$cmd" &>/dev/null || fail "Missing prerequisite: $cmd"
  done
}

check_node_count() {
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$NODE_COUNT" -lt 2 ]]; then
    warn "Only $NODE_COUNT node found. Arm B (node isolation) requires 2+ nodes."
    warn "Arm B will be SKIPPED. To run it, use a multi-node cluster and label nodes:"
    warn "  kubectl label node <victim-node>    isolation-role=victim"
    warn "  kubectl label node <aggressor-node> isolation-role=aggressor"
    TWO_NODE=false
  else
    TWO_NODE=true
    log "Found $NODE_COUNT nodes — Arm B will run."
  fi
}

run_arm() {
  local arm="$1"          # "A" or "B"
  local ns="$2"
  local release="$3"
  local values="$4"
  local aggressor_name="$5"
  local aggressor_ns="$6"
  local port="$7"
  local pf_pid_var="$8"

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Arm ${arm}: deploying to namespace $ns"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install "$release" "$CHART" \
    --namespace "$ns" --values "$values" --wait --timeout=120s

  log "Arm ${arm}: deploying aggressor $aggressor_name in $aggressor_ns..."
  kubectl create namespace "$aggressor_ns" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
  kubectl apply -f "$DIR/stress-profile.yaml" \
    --dry-run=client -o json \
    | jq --arg name "$aggressor_name" --arg ns "$aggressor_ns" \
        '.metadata.name = $name | .metadata.namespace = $ns' \
    | kubectl apply -f -

  kubectl rollout status "deployment/$aggressor_name" -n "$aggressor_ns" --timeout=60s
  sleep 10   # let aggressor reach steady state

  local svc
  svc=$(kubectl get svc -n "$ns" \
    -l "app.kubernetes.io/component=api-service" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "${release}-api")

  log "Arm ${arm}: port-forwarding $svc -> localhost:${port}..."
  kubectl port-forward -n "$ns" "svc/${svc}" "${port}:3002" &
  eval "$pf_pid_var=$!"
  sleep 3

  log "Arm ${arm}: warm-up 10s..."
  hey -z 10s -c 10 "http://localhost:${port}/health" > /dev/null 2>&1 || true
  sleep 2

  log "Arm ${arm}: load test ${DURATION}s @ concurrency=${CONCURRENCY}..."
  RAND_SEED=$SEED hey \
    -z "${DURATION}s" \
    -c "$CONCURRENCY" \
    -m GET \
    "http://localhost:${port}/health" \
    > "$RESULTS_DIR/arm_${arm}_hey.txt" 2>&1

  eval "kill \${$pf_pid_var} 2>/dev/null" || true

  # Parse
  local f="$RESULTS_DIR/arm_${arm}_hey.txt"
  local rps p50 p95 p99
  rps=$(awk '/Requests\/sec:/{printf "%.2f", $2}' "$f")
  p50=$(awk '/50% in/{printf "%.3f", $3 * 1000}' "$f")
  p95=$(awk '/95% in/{printf "%.3f", $3 * 1000}' "$f")
  p99=$(awk '/99% in/{printf "%.3f", $3 * 1000}' "$f")

  echo "$rps $p50 $p95 $p99"
}

cleanup_arm() {
  local release="$1" ns="$2" aggressor="$3" aggressor_ns="$4"
  helm uninstall "$release"  -n "$ns"           2>/dev/null || true
  kubectl delete deployment "$aggressor" -n "$aggressor_ns" 2>/dev/null || true
  kubectl delete namespace "$ns"           --wait=false 2>/dev/null || true
  [[ "$aggressor_ns" != "$ns" ]] && \
    kubectl delete namespace "$aggressor_ns" --wait=false 2>/dev/null || true
}

cleanup() {
  [[ -n "$PF_PID_A" ]] && kill "$PF_PID_A" 2>/dev/null || true
  [[ -n "$PF_PID_B" ]] && kill "$PF_PID_B" 2>/dev/null || true
  cleanup_arm "bench-ns-iso"   "bench-ns-iso"   "cpu-aggressor-colocated" "bench-ns-iso"
  cleanup_arm "bench-node-iso" "bench-node-iso" "cpu-aggressor-isolated"  "bench-node-iso"
}

# ── Main ──────────────────────────────────────────────────────────────────────
mkdir -p "$RESULTS_DIR"
trap cleanup EXIT

check_prereqs
check_node_count

# Arm A — namespace isolation
read -r RPS_A P50_A P95_A P99_A <<< "$(run_arm A bench-ns-iso bench-ns-iso \
  "$DIR/workload-namespace.yaml" cpu-aggressor-colocated bench-ns-iso $PORT_A PF_PID_A)"

# Arm B — node isolation (skip on single-node)
if [[ "$TWO_NODE" == true ]]; then
  read -r RPS_B P50_B P95_B P99_B <<< "$(run_arm B bench-node-iso bench-node-iso \
    "$DIR/workload-node.yaml" cpu-aggressor-isolated bench-node-iso $PORT_B PF_PID_B)"
else
  RPS_B="null"; P50_B="null"; P95_B="null"; P99_B="null"
  warn "Arm B skipped (single-node cluster)"
fi

# Compute II for each arm (using Arm A as the baseline reference)
II_A=$(awk -v b="$P95_A" -v s="$P95_A" 'BEGIN{print "0.0000"}')  # Arm A IS the stressed case
II_B="null"
if [[ "$TWO_NODE" == true && "$P95_A" != "null" && "$P95_B" != "null" ]]; then
  II_B=$(awk -v base="$P95_B" -v stress="$P95_A" \
    'BEGIN{if(base>0) printf "%.4f",(stress-base)/base; else print "null"}')
fi

k8s_ver=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "unknown")

jq -n \
  --arg exp       "comparison_node_isolation" \
  --arg ts        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg k8sv      "$k8s_ver" \
  --arg nodespec  "${NODE_SPEC:-unknown}" \
  --arg cni       "${CNI:-unknown}" \
  --argjson dur   "$DURATION" \
  --argjson conc  "$CONCURRENCY" \
  --argjson seed  "$SEED" \
  --argjson rps_a  "${RPS_A:-0}" \
  --argjson p95_a  "${P95_A:-0}" \
  --argjson p99_a  "${P99_A:-0}" \
  --argjson rps_b  "${RPS_B:-null}" \
  --argjson p95_b  "${P95_B:-null}" \
  --argjson p99_b  "${P99_B:-null}" \
  --argjson ii_b   "${II_B:-null}" \
  --arg two_node   "$TWO_NODE" \
'{
  experiment: $exp,
  timestamp:  $ts,
  cluster: { k8s_version: $k8sv, node_spec: $nodespec, cni: $cni },
  workload: { duration_s: $dur, concurrency: $conc, seed: $seed },
  arm_A_namespace_isolation: {
    description: "Victim and aggressor share the same node; namespace ResourceQuota only",
    throughput_rps: $rps_a,
    p95_ms: $p95_a,
    p99_ms: $p99_a,
    interference_index: "reference (stressed arm)"
  },
  arm_B_node_isolation: {
    description: "Victim on dedicated node; aggressor on separate node",
    two_node_cluster: ($two_node == "true"),
    throughput_rps: $rps_b,
    p95_ms: $p95_b,
    p99_ms: $p99_b,
    interference_index_vs_arm_A: $ii_b
  },
  metrics: {
    interference_index:          $ii_b,
    resource_fairness_deviation: null,
    autoscaling_stability_score: null
  }
}' > "$RESULTS_DIR/results.json"

log "Results saved: $RESULTS_DIR/results.json"
cat "$RESULTS_DIR/results.json"
log "Comparison experiment complete."
