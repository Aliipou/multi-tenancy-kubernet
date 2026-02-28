# Multi-Tenant Kubernetes SaaS Platform

[![CI/CD](https://github.com/Aliipou/multi-tenancy-kubernet/actions/workflows/ci.yml/badge.svg)](https://github.com/Aliipou/multi-tenancy-kubernet/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-k3s-326CE5?logo=kubernetes)](https://k3s.io)
[![Node.js](https://img.shields.io/badge/Node.js-18.x-339933?logo=node.js)](https://nodejs.org)

> Namespace-based multi-tenant SaaS platform on Kubernetes — each tenant is fully isolated by network policy, RBAC, and resource quotas. Includes an optional Federated Learning extension for privacy-preserving collaborative ML across tenant boundaries.

Bachelor's Thesis · Centria University of Applied Sciences · 2026
**Author:** Ali Pourrahim

---

## Table of Contents

- [Research Questions](#research-questions)
- [Benchmark Framework](#benchmark-framework)
- [Reproducibility](#reproducibility)
- [Overview](#overview)
- [Architecture](#architecture)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Deployment](#deployment)
- [Testing](#testing)
- [Monitoring](#monitoring)
- [Security](#security)
- [Next Phase: Federated Learning](#next-phase-federated-learning)
- [Performance Results](#performance-results)
- [Troubleshooting](#troubleshooting)
- [Additional Documentation](#additional-documentation)

---

## Research Questions

This project is the implementation artifact for a thesis that investigates the following research questions.

### Main Research Question

> How can namespace-based isolation in Kubernetes effectively support multi-tenant SaaS deployments while maintaining adequate security, acceptable performance, and cost efficiency?

### Sub-Questions

**RQ1 — Architecture and Configuration**
- What Kubernetes resources and configurations enable effective tenant isolation in a namespace-based model?
- How should resource quotas and limits be configured to prevent noisy neighbor effects while maximising resource utilisation?

**RQ2 — Security and Isolation**
- To what extent do RBAC and NetworkPolicies provide adequate isolation between tenants?
- What is the attack surface and threat model for namespace-based multi-tenancy?
- Can namespace isolation prevent cross-tenant data access and resource interference?

**RQ3 — Performance Characteristics**
- What are the response time and throughput characteristics of a multi-tenant application under varying load conditions?
- What is the performance overhead of security controls (RBAC, NetworkPolicies) compared to an unrestricted deployment?
- How does resource contention between tenants affect application performance?

**RQ4 — Scalability and Autoscaling**
- How effectively does the Horizontal Pod Autoscaler respond to load changes in a multi-tenant environment?
- What is the latency of scale-up and scale-down operations?
- How does autoscaling interact with ResourceQuota limits?

**RQ5 — Operational and Economic Considerations**
- What is the operational complexity of deploying and managing namespace-based multi-tenancy?
- What is the cost-effectiveness of namespace isolation compared to alternative approaches (virtual clusters, dedicated clusters)?
- What are the practical limitations and failure modes of namespace-based isolation?

---

## Benchmark Framework

Every claim in this thesis is backed by a reproducible experiment in `experiments/`.
Each experiment runs with **one command** and writes a `results.json` with a fixed schema.

### Formal Metrics

#### Interference Index (II)

Quantifies how much a co-located aggressor degrades the victim tenant's tail latency.

```
II = (P95_stress − P95_baseline) / P95_baseline
```

| II | Interpretation |
|----|----------------|
| 0.00 | No interference — perfect isolation |
| ≤ 0.10 | Negligible — acceptable for production |
| ≤ 0.25 | Moderate — soft isolation boundary |
| > 0.50 | Severe — isolation has failed |

#### Resource Fairness Deviation (RFD)

Measures scheduling drift between requested and actual CPU allocation.

```
RFD = |CPU_actual_millicores − CPU_requested_millicores| / CPU_requested_millicores
```

Collected via `kubectl top pods` during steady-state load. RFD > 0.30 indicates the scheduler is not honouring requests.

#### Autoscaling Stability Score (ASS)

Measures HPA event frequency over an observation window. Lower = more stable.

```
ASS = total_scaling_events / observation_window_seconds
```

| ASS | Interpretation |
|-----|----------------|
| 0.00 | HPA did not fire (load was flat or HPA unresponsive) |
| < 0.05 | Stable autoscaling |
| > 0.20 | Flapping — HPA is oscillating |

### Experiments

| Experiment | Metric Produced | Research Question |
|------------|----------------|-------------------|
| `baseline/` | P95, P99, throughput (reference) | RQ3 |
| `cpu_contention/` | II under CPU aggressor | RQ2, RQ3 |
| `memory_pressure/` | II under memory aggressor + OOM events | RQ2, RQ3 |
| `hpa_burst/` | ASS, scale-up latency | RQ4 |
| `comparison_node_isolation/` | II: namespace vs node isolation | RQ5 |

```bash
# Run all experiments
./experiments/run-all.sh

# Compare two results and get II/RFD/ASS
./experiments/compute-metrics.sh \
  experiments/baseline/results/TIMESTAMP/results.json \
  experiments/cpu_contention/results/TIMESTAMP/results.json
```

---

## Reproducibility

### Hardware Used in Thesis

| Parameter | Value |
|-----------|-------|
| Cloud instance | AWS EC2 t3.micro |
| vCPU | 2 |
| RAM | 1 GB |
| OS | Amazon Linux 2023 |
| Kubernetes | k3s v1.33.6 |
| CNI | Flannel |
| Load generator | `hey` v0.1.4 |
| Fixed random seed | 42 |
| Test duration | 60 s per run |
| Concurrency | 50 workers |
| Warm-up period | 10 s (discarded) |

### Capture Cluster Snapshot Before Running

```bash
mkdir -p experiments/results/cluster-snapshot
kubectl version -o json                             > experiments/results/cluster-snapshot/k8s-version.json
kubectl get nodes -o json                           > experiments/results/cluster-snapshot/nodes.json
kubectl get resourcequota --all-namespaces -o json  > experiments/results/cluster-snapshot/quotas.json
kubectl get limitrange    --all-namespaces -o json  > experiments/results/cluster-snapshot/limitranges.json
kubectl get networkpolicy --all-namespaces -o json  > experiments/results/cluster-snapshot/netpols.json
```

### Replicating on a Different Cluster

1. `git clone https://github.com/Aliipou/multi-tenancy-kubernet`
2. Update image repositories in `helm-charts/saas-app/values.yaml`
3. Run `./experiments/run-all.sh`
4. Compare your `results.json` against each `experiments/*/expected-output.json`

Acceptable variance from thesis values: **±20 %** on P95 latency, **±10 %** on throughput.

---

## Overview

This project implements a multi-tenant SaaS application on Kubernetes with:

- **3 microservices**: Auth, Dashboard, and API services
- **Namespace-based isolation**: Each tenant has its own namespace
- **Resource management**: ResourceQuotas and LimitRanges per tenant
- **Autoscaling**: Horizontal Pod Autoscaler (HPA) for each service
- **Security**: RBAC, NetworkPolicies, and Pod Security Contexts
- **Observability**: Prometheus metrics and health checks
- **FL extension** *(Next-phase)*: Privacy-preserving Federated Learning across tenants

### Tenant Profiles

| Tenant | Tier | CPU Limit | Memory Limit | Use Case |
|--------|------|-----------|--------------|----------|
| Tenant 1 | Standard | 2 cores | 2 Gi | Typical workloads |
| Tenant 2 | Enterprise | 4 cores | 4 Gi | High-demand customers |
| Tenant 3 | Startup | 1 core | 1 Gi | Cost-conscious deployments |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     NGINX Ingress Controller                 │
└────────────┬──────────────┬──────────────┬───────────────────┘
             │              │              │
    ┌────────▼───────┐ ┌───▼─────────┐ ┌──▼──────────────┐
    │ tenant1.local  │ │tenant2.local│ │ tenant3.local   │
    └────────┬───────┘ └───┬─────────┘ └──┬──────────────┘
             │              │              │
    ┌────────▼────────────────────────────▼───────────────┐
    │              Tenant Namespaces                       │
    │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐  │
    │  │  Tenant 1   │ │  Tenant 2   │ │  Tenant 3   │  │
    │  ├─────────────┤ ├─────────────┤ ├─────────────┤  │
    │  │ Dashboard   │ │ Dashboard   │ │ Dashboard   │  │
    │  │ Auth        │ │ Auth        │ │ Auth        │  │
    │  │ API         │ │ API         │ │ API         │  │
    │  └─────────────┘ └─────────────┘ └─────────────┘  │
    │  NetworkPolicy: cross-tenant traffic blocked        │
    └────────────────────────────────────────────────────┘
```

### Isolation Layers

| Layer | Mechanism | What It Prevents |
|-------|-----------|------------------|
| Network | NetworkPolicy | Cross-tenant traffic |
| Compute | ResourceQuota + LimitRange | Resource starvation (noisy neighbour) |
| Control Plane | RBAC | Unauthorised Kubernetes API access |
| Application | JWT tenant claims | Data leakage at the application level |

### Services

Each tenant namespace runs three services:

| Service | Port | Responsibility |
|---------|------|---------------|
| Dashboard | 3000 | Frontend UI |
| Auth | 3001 | JWT authentication |
| API | 3002 | Business logic and task management |

---

## Features

### Multi-Tenancy
- **Namespace Isolation**: Each tenant operates in its own Kubernetes namespace
- **Resource Quotas**: CPU, memory, and pod limits enforced per tenant
- **Network Policies**: Traffic isolation — tenants cannot reach each other
- **RBAC**: Role-based access control scoped to each namespace

### Scalability
- **Horizontal Pod Autoscaling**: Auto-scale on CPU/memory metrics
- **Resource Requests/Limits**: Prevents a single tenant from starving others
- **Pod Disruption Budgets**: Maintain availability during rolling updates

### Security
- **JWT Authentication**: Tenant-scoped token-based auth
- **Non-root Containers**: All services run as UID 1001
- **Dropped Capabilities**: Minimal Linux capabilities per container
- **Secrets Management**: JWT secrets stored in Kubernetes Secrets

### Observability
- **Health Checks**: Liveness, readiness, and startup probes on all services
- **Prometheus Metrics**: `/metrics` endpoint on each service
- **Structured Logging**: JSON-formatted logs with request IDs
- **Tenant Identification**: Every log and metric tagged with tenant context

---

## Prerequisites

### Required
- **Docker** v20.10+
- **Kubernetes** v1.25+ (k3s, kind, minikube, or cloud-managed)
- **kubectl** v1.25+
- **Helm** v3.10+

### Optional
- **hey** or **Apache Bench** — load testing
- **curl** — API testing

---

## Quick Start

### 1. Set Up Kubernetes Cluster

```bash
# Local (Linux/Mac)
./scripts/setup-cluster.sh

# Local (Windows PowerShell)
.\scripts\setup-cluster.ps1
```

### 2. Build and Push Docker Images

```bash
cd services/auth-service      && docker build -t your-registry/auth-service:1.0.0 .
cd ../dashboard-service       && docker build -t your-registry/dashboard-service:1.0.0 .
cd ../api-service              && docker build -t your-registry/api-service:1.0.0 .

docker push your-registry/auth-service:1.0.0
docker push your-registry/dashboard-service:1.0.0
docker push your-registry/api-service:1.0.0
```

### 3. Update Image References

Edit `helm-charts/saas-app/values.yaml`:

```yaml
authService:
  image:
    repository: your-registry/auth-service

dashboardService:
  image:
    repository: your-registry/dashboard-service

apiService:
  image:
    repository: your-registry/api-service
```

### 4. Deploy All Tenants

```bash
# Linux/Mac
./scripts/deploy-all-tenants.sh

# Windows
.\scripts\deploy-all-tenants.ps1
```

### 5. Add Host Entries

Append to `/etc/hosts` (Linux/Mac) or `C:\Windows\System32\drivers\etc\hosts` (Windows):

```
127.0.0.1 tenant1.localhost
127.0.0.1 tenant2.localhost
127.0.0.1 tenant3.localhost
```

Then open:
- http://tenant1.localhost
- http://tenant2.localhost
- http://tenant3.localhost

---

## Project Structure

```
.
├── experiments/                 # Reproducible benchmark suite  ← NEW
│   ├── README.md                # Metric definitions + reproducibility guide
│   ├── run-all.sh               # Run all 5 experiments in sequence
│   ├── compute-metrics.sh       # Compute II / RFD / ASS from result JSONs
│   ├── baseline/                # Clean reference — no contention
│   ├── cpu_contention/          # II under CPU aggressor (same namespace)
│   ├── memory_pressure/         # II under memory aggressor + OOM tracking
│   ├── hpa_burst/               # ASS and scale-up latency under burst traffic
│   └── comparison_node_isolation/  # Namespace isolation vs node isolation II
├── services/                    # Microservices
│   ├── auth-service/            # JWT authentication (port 3001)
│   ├── dashboard-service/       # Frontend dashboard (port 3000)
│   └── api-service/             # Task API (port 3002)
├── helm-charts/
│   └── saas-app/
│       ├── templates/           # Kubernetes manifests
│       ├── values.yaml          # Default values
│       └── values-overrides/    # Per-tenant resource profiles
├── scripts/                     # Automation scripts
│   ├── setup-cluster.*          # Cluster initialisation
│   ├── deploy-tenant.*          # Tenant deployment
│   ├── validate-deployment.*    # Deployment validation
│   ├── test-isolation.sh        # Cross-tenant isolation tests
│   ├── test-autoscaling.sh      # HPA tests
│   ├── test-integration.sh      # End-to-end API tests
│   ├── collect-metrics.sh       # Metrics snapshot
│   └── monitor-live.sh          # Live dashboard
├── Next-phase/                  # Federated Learning extension
│   ├── main.py                  # FL Coordinator (FedAvg server)
│   ├── deployment.yaml          # K8s manifest for FL coordinator
│   ├── networkpolicy.yaml       # FL-specific NetworkPolicies
│   ├── provision-tenant-with-fl.sh  # Tenant provisioning with FL
│   └── ci.yml                   # CI/CD for FL components
├── docs/                        # Thesis documentation
│   ├── INTRODUCTION.md
│   ├── ARCHITECTURE.md
│   ├── IMPLEMENTATION.md
│   ├── TESTING.md
│   ├── SCIENTIFIC_ANALYSIS.md
│   ├── CONCLUSION.md
│   └── REFERENCES.md
└── monitoring/                  # Collected metrics outputs
```

---

## Deployment

### Deploy a Single Tenant

```bash
# Linux/Mac
./scripts/deploy-tenant.sh 1

# Windows
.\scripts\deploy-tenant.ps1 -TenantNumber 1
```

### Dry Run

```bash
./scripts/deploy-tenant.sh 1 --dry-run
```

### Customise Tenant Resources

Edit `helm-charts/saas-app/values-overrides/tenant1.yaml`:

```yaml
apiService:
  replicaCount: 3
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi
```

### Remove a Tenant

```bash
./scripts/cleanup-tenant.sh 1
```

---

## Testing

### Automated Test Suite

```bash
# Full validation for one tenant
./scripts/validate-deployment.sh 1

# Cross-tenant isolation (answers RQ2)
./scripts/test-isolation.sh

# HPA / autoscaling (answers RQ4)
./scripts/test-autoscaling.sh 1 60

# End-to-end integration
./scripts/test-integration.sh 1

# Run everything
./scripts/run-all-tests.sh
```

### Manual API Testing

```bash
# Register a user
curl -X POST http://tenant1.localhost/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","email":"test@example.com","password":"Test123!"}'

# Login
curl -X POST http://tenant1.localhost/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"Test123!"}'

# Create a task (replace YOUR_TOKEN)
curl -X POST http://tenant1.localhost/api/tasks \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Test Task","description":"Testing the API"}'
```

---

## Monitoring

### Collect Metrics Snapshot

```bash
./scripts/collect-metrics.sh
# Output saved to monitoring/metrics_TIMESTAMP/
```

### Performance Benchmarking

```bash
./scripts/performance-benchmark.sh 1 60 50
# Args: <tenant> <duration-seconds> <concurrency>
# Output saved to monitoring/benchmark_tenant1_TIMESTAMP/
```

### Live Dashboard

```bash
./scripts/monitor-live.sh 5   # refresh every 5 seconds
```

### View Logs

```bash
# All services for a tenant
kubectl logs -n tenant1 -l app.kubernetes.io/instance=tenant1-app --tail=100

# Specific service (follow)
kubectl logs -n tenant1 -l app.kubernetes.io/component=api-service --tail=100 -f
```

### Prometheus Metrics

```bash
kubectl port-forward -n tenant1 svc/tenant1-app-api 3002:3002
curl http://localhost:3002/metrics
```

---

## Security

### JWT Secrets

```bash
kubectl get secret -n tenant1 tenant1-app-secrets \
  -o jsonpath='{.data.jwt-secret}' | base64 -d
```

### RBAC

```bash
kubectl get role,rolebinding -n tenant1
kubectl describe role -n tenant1
```

### Network Policies

```bash
kubectl get networkpolicy -n tenant1
kubectl describe networkpolicy -n tenant1
```

### Security Baseline

- All containers run as non-root (UID 1001)
- Linux capabilities dropped (`ALL`)
- Resource limits enforced to prevent DoS between tenants
- Cross-namespace network traffic blocked by default

---

## Next Phase: Federated Learning

The `Next-phase/` directory extends the platform with **privacy-preserving Federated Learning (FL)**. Tenants can collaborate to train a shared ML model without any raw data ever leaving their namespace — only model weight updates travel the network.

### Why This Matters

Healthcare SaaS, fintech, and any regulated industry where data residency is non-negotiable can leverage FL to gain collective intelligence while satisfying data sovereignty requirements.

### FL Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster (k3s)                  │
│                                                              │
│  ┌──────────────┐   weights only    ┌────────────────────┐  │
│  │  fl-system   │◄──────────────────│  tenant-alpha      │  │
│  │  ┌──────────┐│   weights only    │  ┌──────────────┐  │  │
│  │  │   FL     │◄│───────────────────│  │  FL Client   │  │  │
│  │  │Coordinator│ │                  │  │  API Service │  │  │
│  │  └──────────┘ │   global model   │  └──────────────┘  │  │
│  │               │──────────────────►│                    │  │
│  └──────────────┘                   └────────────────────┘  │
│                                                              │
│  NetworkPolicy: tenants CANNOT communicate with each other   │
└─────────────────────────────────────────────────────────────┘
```

### FedAvg Aggregation

Each FL round:

1. Coordinator broadcasts current global model weights
2. Each tenant client pulls global weights and trains locally for N epochs
3. Clients send back updated weights + sample count — **no raw data**
4. Coordinator computes weighted average: `w_global = Σ (n_i / N_total) × w_i`
5. New global model is available for the next round

### FL Isolation Layers

| Layer | Mechanism | What It Prevents |
|-------|-----------|------------------|
| Network | NetworkPolicy | Cross-tenant traffic; FL client can only reach coordinator |
| Protocol | Weights-only | Raw data ever leaving a namespace |
| Auth | Shared secret (extendable to mTLS) | Unauthenticated weight submissions |

### Deploying the FL Extension

```bash
# 1. Create control-plane namespace and shared secret
kubectl create namespace fl-system
kubectl create secret generic fl-shared-secret \
  --from-literal=secret=$(openssl rand -hex 32) \
  -n fl-system

# 2. Apply coordinator manifests
kubectl apply -f Next-phase/deployment.yaml
kubectl apply -f Next-phase/networkpolicy.yaml

# 3. Provision tenants with FL enabled
chmod +x Next-phase/provision-tenant-with-fl.sh
./Next-phase/provision-tenant-with-fl.sh tenant-alpha --enable-fl
./Next-phase/provision-tenant-with-fl.sh tenant-beta  --enable-fl

# 4. Check FL round status
kubectl port-forward svc/fl-coordinator 8080:8080 -n fl-system &
curl http://localhost:8080/round-status \
  -H "x-fl-secret: $(kubectl get secret fl-shared-secret -n fl-system \
      -o jsonpath='{.data.secret}' | base64 -d)"
```

### Extending to Differential Privacy

To add DP noise before weight submission, modify `services/fl-client/main.py`:

```python
def add_dp_noise(weights, epsilon=1.0, delta=1e-5, sensitivity=1.0):
    """Add Gaussian noise for (epsilon, delta)-DP."""
    sigma = sensitivity * (2 * np.log(1.25 / delta)) ** 0.5 / epsilon
    return [w + np.random.normal(0, sigma, w.shape) for w in weights]
```

### Future FL Work

- [ ] Differential Privacy noise injection in FL clients
- [ ] Byzantine-robust aggregation (Krum, Trimmed Mean)
- [ ] Asynchronous FL (remove round-synchronisation requirement)
- [ ] mTLS between FL clients and coordinator (replace shared secret)
- [ ] Tenant billing and resource metering for FL compute

---

## Performance Results

All results collected on single-node k3s, AWS EC2 t3.micro (2 vCPU, 1 GB RAM).
Load generator: `hey` v0.1.4 · Duration: 60 s · Concurrency: 50 · Seed: 42.
Full raw data and scripts in [`experiments/`](experiments/).

### Baseline (no contention)

| Service | Throughput (req/s) | P50 (ms) | P95 (ms) | P99 (ms) | Errors |
|---------|-------------------|----------|----------|----------|--------|
| API Service | 890 | 48 | 135 | 210 | 0 % |
| Auth Service | 412 | 95 | 279 | 450 | 0 % |

### Isolation Experiments — Interference Index (II)

| Experiment | Throughput (req/s) | P95 (ms) | II | Verdict |
|------------|-------------------|----------|----|---------|
| Baseline | 890 | 135 | — | Reference |
| CPU contention (same namespace) | 720 | 162 | **0.20** | WARN — moderate |
| Memory pressure (same namespace) | 780 | 175 | **0.30** | WARN — moderate |
| Node isolation (separate node) | 885 | 138 | **≈ 0** | PASS — negligible |

> **Finding (RQ2, RQ3):** Namespace-based isolation limits interference but does not eliminate it on shared hardware. II = 0.20–0.30 under stress. Node isolation reduces II to near zero at ~2× infrastructure cost.

### Autoscaling — HPA Burst (RQ4)

| Metric | Value |
|--------|-------|
| Burst concurrency | 200 workers |
| Scale-up trigger latency | ~75 s |
| Peak replicas reached | 4 / 5 max |
| Scale-down observed | Yes (~5 min cool-down) |
| Scaling events (420 s window) | 4 |
| Autoscaling Stability Score (ASS) | **0.0095** (stable) |
| P99 during scale-up window | 720 ms |

> **Finding (RQ4):** HPA reacts within 75 s (15 s sync period + ~45 s pod startup). No flapping observed (ASS < 0.05). P99 spikes during the pod-start window are the primary latency risk.

### FL Coordinator (Next-phase)

| Metric | Value |
|--------|-------|
| FedAvg aggregation time (2 clients) | < 50 ms |
| Cross-tenant data leakage violations | 0 |
| Tenant provisioning time | ~10 min |

---

## Troubleshooting

### Pods Not Starting

```bash
kubectl get pods -n tenant1
kubectl describe pod <pod-name> -n tenant1
kubectl get events -n tenant1 --sort-by='.lastTimestamp'
```

### Service Not Accessible

```bash
kubectl get ingress -n tenant1
kubectl get endpoints -n tenant1

# Debug pod
kubectl run -n tenant1 -it --rm debug --image=busybox --restart=Never -- sh
wget -O- http://tenant1-app-auth:3001/health
```

### Resource Quota Exceeded

```bash
kubectl describe resourcequota -n tenant1
# Then increase limits in helm-charts/saas-app/values-overrides/tenant1.yaml
```

### HPA Not Scaling

```bash
kubectl get apiservices | grep metrics
kubectl get hpa -n tenant1
kubectl describe hpa -n tenant1
kubectl top pods -n tenant1
```

---

## Additional Documentation

| Document | Description |
|----------|-------------|
| [Architecture Details](docs/ARCHITECTURE.md) | Full system design |
| [Implementation Guide](docs/IMPLEMENTATION.md) | Code walkthrough |
| [Testing Guide](docs/TESTING.md) | Test strategy and results |
| [Requirements Analysis](docs/REQUIREMENTS_ANALYSIS.md) | Functional and non-functional requirements |
| [Scientific Analysis](docs/SCIENTIFIC_ANALYSIS.md) | Quantitative performance analysis |
| [Performance Charts](docs/PERFORMANCE_CHARTS.md) | Benchmark charts and data |
| [Conclusion](docs/CONCLUSION.md) | Findings and recommendations |
| [References](docs/REFERENCES.md) | Academic and technical references |

---

## Limitations

This system assumes a **trusted-tenant** threat model:

- Shared Kubernetes control plane (not vCluster)
- Shared Linux kernel across all pods
- Namespace isolation is "soft" — not suitable for hostile or untrusted tenants
- In-memory data store only (no database persistence)
- Single-node deployment (no HA)
- Short-term tested (3 hours), not long-term production validated

---

## License

MIT — see [LICENSE](LICENSE)

---

## Author

**Ali Pourrahim**
Bachelor's Thesis — Multi-Tenancy in Kubernetes for SaaS Applications
Centria University of Applied Sciences, 2026
GitHub: [Aliipou/multi-tenancy-kubernet](https://github.com/Aliipou/multi-tenancy-kubernet)

---

## Acknowledgments

- Kubernetes and k3s community
- Helm project
- NGINX Ingress Controller
- Prometheus monitoring ecosystem
- McMahan et al. (2017) — FedAvg algorithm

---

> **Production note:** For real production use, add persistent storage (PostgreSQL), TLS/SSL, external identity (OAuth/SAML), Prometheus + Grafana stack, multi-region deployment, and consider vCluster or dedicated clusters for untrusted tenants.
