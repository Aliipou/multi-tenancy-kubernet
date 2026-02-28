#!/bin/bash
# compute-metrics.sh — Compute II, RFD, and ASS from experiment result files.
#
# Usage:
#   ./compute-metrics.sh <baseline.json> <stress.json>
#   ./compute-metrics.sh results/baseline/results.json results/cpu_contention/results.json
#
# Outputs a JSON object with all three metrics to stdout.

set -euo pipefail

BASELINE=${1:?'Usage: compute-metrics.sh <baseline.json> <stress.json>'}
STRESS=${2:?'Usage: compute-metrics.sh <baseline.json> <stress.json>'}

command -v jq &>/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }
command -v awk &>/dev/null || { echo "ERROR: awk is required" >&2; exit 1; }

[[ -f "$BASELINE" ]] || { echo "ERROR: baseline file not found: $BASELINE" >&2; exit 1; }
[[ -f "$STRESS"   ]] || { echo "ERROR: stress file not found: $STRESS"   >&2; exit 1; }

# ── Read values ──────────────────────────────────────────────────────────────
P95_BASE=$(jq -r '.results.p95_ms'   "$BASELINE")
P95_STR=$(jq  -r '.results.p95_ms'   "$STRESS")

RPS_BASE=$(jq -r '.results.throughput_rps' "$BASELINE")
RPS_STR=$(jq  -r '.results.throughput_rps' "$STRESS")

CPU_REQ=$(jq  -r '.metrics.resource_fairness_deviation // "null"' "$STRESS")
SCALING=$(jq  -r '.metrics.autoscaling_stability_score // "null"' "$STRESS")

STRESS_EXP=$(jq -r '.experiment' "$STRESS")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Interference Index ────────────────────────────────────────────────────────
II=$(awk -v base="$P95_BASE" -v stress="$P95_STR" '
  BEGIN {
    if (base > 0) printf "%.4f", (stress - base) / base
    else           printf "null"
  }')

# ── Throughput Degradation ────────────────────────────────────────────────────
TD=$(awk -v base="$RPS_BASE" -v stress="$RPS_STR" '
  BEGIN {
    if (base > 0) printf "%.4f", (base - stress) / base
    else           printf "null"
  }')

# ── Output ────────────────────────────────────────────────────────────────────
jq -n \
  --arg timestamp "$TIMESTAMP" \
  --arg baseline  "$BASELINE" \
  --arg stress    "$STRESS_EXP" \
  --argjson p95b  "$P95_BASE" \
  --argjson p95s  "$P95_STR" \
  --argjson rpsb  "$RPS_BASE" \
  --argjson rpss  "$RPS_STR" \
  --argjson ii    "$II" \
  --argjson td    "$TD" \
  --argjson rfd   "${CPU_REQ:-null}" \
  --argjson ass   "${SCALING:-null}" \
'{
  timestamp:   $timestamp,
  baseline:    $baseline,
  stress_experiment: $stress,
  raw: {
    p95_baseline_ms: $p95b,
    p95_stress_ms:   $p95s,
    rps_baseline:    $rpsb,
    rps_stress:      $rpss
  },
  metrics: {
    interference_index:           $ii,
    throughput_degradation:       $td,
    resource_fairness_deviation:  $rfd,
    autoscaling_stability_score:  $ass
  },
  interpretation: {
    ii_verdict:  (if $ii == null then "unavailable"
                  elif $ii <= 0.10 then "PASS — negligible interference"
                  elif $ii <= 0.25 then "WARN — moderate interference"
                  else                  "FAIL — isolation boundary violated" end)
  }
}'
