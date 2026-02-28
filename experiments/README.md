# Benchmark Experiments

Reproducible benchmark suite for the multi-tenant Kubernetes isolation research.
**Every experiment runs with a single command.**

---

## Formal Metric Definitions

### 1. Interference Index (II)

Measures how much a co-located aggressor degrades the victim tenant's tail latency.

```
II = (P95_stress - P95_baseline) / P95_baseline
```

| II Value | Interpretation |
|----------|----------------|
| 0.00 | No interference — perfect isolation |
| 0.10 | 10 % latency degradation — acceptable |
| 0.25 | 25 % degradation — soft isolation boundary |
| > 0.50 | Severe interference — isolation is failing |

### 2. Resource Fairness Deviation (RFD)

Measures the scheduling drift between what a tenant requested and what was actually allocated.

```
RFD = |CPU_actual_millicores - CPU_requested_millicores| / CPU_requested_millicores
```

Collected via `kubectl top pods` during steady-state load.

### 3. Autoscaling Stability Score (ASS)

Measures HPA event frequency over an observation window. Lower = more stable.

```
ASS = total_scaling_events / observation_window_seconds
```

| ASS Value | Interpretation |
|-----------|----------------|
| 0.00 | No scaling triggered |
| < 0.05 | Stable autoscaling |
| > 0.20 | Flapping — HPA oscillating |

---

## Experiments

| # | Directory | Research Question | One-command |
|---|-----------|-------------------|-------------|
| 1 | `baseline/` | RQ3 — clean throughput and latency | `./baseline/run.sh` |
| 2 | `cpu_contention/` | RQ2, RQ3 — II under CPU aggressor | `./cpu_contention/run.sh` |
| 3 | `memory_pressure/` | RQ2, RQ3 — II under memory aggressor | `./memory_pressure/run.sh` |
| 4 | `hpa_burst/` | RQ4 — HPA reaction time and ASS | `./hpa_burst/run.sh` |
| 5 | `comparison_node_isolation/` | RQ5 — namespace vs node isolation II | `./comparison_node_isolation/run.sh` |

---

## Running

### Prerequisites

```bash
kubectl version --client   # >= v1.25
helm version               # >= v3.10
hey --version              # https://github.com/rakyll/hey
jq --version               # JSON processing
kubectl top pods           # requires metrics-server
```

Install `hey`:
```bash
# Linux
wget -O hey https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64 && chmod +x hey && sudo mv hey /usr/local/bin/

# macOS
brew install hey
```

### Run a Single Experiment

```bash
cd experiments/
./baseline/run.sh                        # default: 60s, concurrency 50
./baseline/run.sh 120 100               # custom: 120s, concurrency 100
```

### Run All Experiments

```bash
./run-all.sh
# Results saved to experiments/results/run_all_TIMESTAMP/
```

### Compute Metrics from Results

```bash
./compute-metrics.sh \
  results/TIMESTAMP_baseline/results.json \
  results/TIMESTAMP_cpu_contention/results.json
```

---

## Output Format

Every experiment writes a `results.json` conforming to this schema:

```json
{
  "experiment": "<name>",
  "timestamp": "<ISO 8601>",
  "cluster": {
    "k8s_version": "<string>",
    "node_spec":   "<string>",
    "cni":         "<string>"
  },
  "workload": {
    "target":       "<service/endpoint>",
    "duration_s":   60,
    "concurrency":  50,
    "seed":         42
  },
  "results": {
    "throughput_rps": 0.0,
    "p50_ms":         0.0,
    "p95_ms":         0.0,
    "p99_ms":         0.0,
    "error_rate":     0.0
  },
  "metrics": {
    "interference_index":           null,
    "resource_fairness_deviation":  null,
    "autoscaling_stability_score":  null
  }
}
```

---

## Reproducibility Guide

### Hardware Used in Thesis

| Parameter | Value |
|-----------|-------|
| Cloud instance | AWS EC2 t3.micro |
| vCPU | 2 |
| RAM | 1 GB |
| Storage | 8 GB gp2 SSD |
| OS | Amazon Linux 2023 |
| Kubernetes | k3s v1.33.6 |
| CNI | Flannel |
| Load generator | hey v0.1.4 |
| Random seed | 42 |
| Test duration | 60 s per run |
| Concurrency | 50 workers |
| Warm-up | 10 s before measurement |

### Capture Cluster Snapshot

```bash
mkdir -p experiments/results/cluster-snapshot
kubectl version -o json                              > experiments/results/cluster-snapshot/k8s-version.json
kubectl get nodes -o json                            > experiments/results/cluster-snapshot/nodes.json
kubectl get resourcequota --all-namespaces -o json   > experiments/results/cluster-snapshot/quotas.json
kubectl get limitrange --all-namespaces -o json      > experiments/results/cluster-snapshot/limitranges.json
kubectl get networkpolicy --all-namespaces -o json   > experiments/results/cluster-snapshot/netpols.json
```

### Replicating on a Different Cluster

1. Clone the repo: `git clone https://github.com/Aliipou/multi-tenancy-kubernet`
2. Update image repositories in `helm-charts/saas-app/values.yaml`
3. Run: `./experiments/run-all.sh`
4. Compare your `results.json` against `experiments/*/expected-output.json`

Acceptable variance from expected values: ± 20 % on P95 latency, ± 10 % on throughput.
