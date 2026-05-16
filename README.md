# Multi-Tenancy on Kubernetes

Namespace-based tenant isolation with RBAC, NetworkPolicy, ResourceQuota, and Helm-automated provisioning. Developed and validated on k3s as part of a bachelor's thesis at Centria University of Applied Sciences, 2026.

---

## 1. Problem

Running multiple tenants on a shared Kubernetes cluster creates three hard problems:

**Namespace isolation**: By default, Kubernetes workloads can communicate across namespaces. Pod A in `tenant-a` can reach Pod B in `tenant-b` unless policies explicitly prevent it. Enforcing boundaries requires NetworkPolicy, RBAC, and careful namespace topology — none of which is configured by default.

**Resource fairness**: Without quotas, a noisy tenant can exhaust cluster CPU and memory, causing other tenants to be evicted or throttled. Kubernetes does not enforce limits unless ResourceQuota and LimitRange are explicitly set.

**Operational complexity**: Manual per-tenant configuration (namespaces, service accounts, roles, network policies, secrets) is error-prone at scale. Each new tenant requires 10+ YAML manifests applied in the right order. Without automation, drift between tenants is inevitable.

This project addresses all three: namespace-per-tenant isolation enforced by NetworkPolicy and RBAC, quota enforcement at the namespace level, and single-command tenant provisioning via Helm.

---

## 2. Architecture

```
Kubernetes Cluster (k3s, single-node)
           |
    ┌──────┴──────────────────┐
    |                          |
[ingress-nginx]          [monitoring]
    |
    ├── tenant-a (namespace)
    │     ├── auth-service (Deployment + HPA)
    │     ├── api-service  (Deployment + HPA)
    │     ├── dashboard    (Deployment + HPA)
    │     ├── ServiceAccount + Role + RoleBinding
    │     ├── ResourceQuota + LimitRange
    │     └── NetworkPolicy (deny-all + allow ingress)
    │
    ├── tenant-b (namespace)
    │     └── (same structure, fully isolated)
    │
    └── tenant-c (namespace)
          └── ...
```

**Helm chart structure (`helm-charts/saas-app`)**

```
saas-app/
├── Chart.yaml
├── values.yaml               # Per-tenant overrides
└── templates/
    ├── namespace.yaml
    ├── serviceaccount.yaml
    ├── rbac.yaml             # Role + RoleBinding
    ├── resourcequota.yaml
    ├── networkpolicy.yaml
    ├── secrets.yaml          # JWT secret (values-injected)
    ├── deployment-auth.yaml
    ├── deployment-api.yaml
    ├── deployment-dashboard.yaml
    ├── service-*.yaml
    ├── hpa-*.yaml            # HorizontalPodAutoscaler per service
    ├── ingress.yaml
    └── poddisruptionbudget.yaml
```

Each `helm install` provisions a complete, isolated tenant environment in one command.

---

## 3. Design Decisions

**Namespace-per-tenant vs. cluster-per-tenant**
Cluster-per-tenant gives the strongest isolation but multiplies infrastructure cost linearly with tenant count. Namespace isolation is sufficient for most SaaS workloads where tenants are not adversarial. The trade-off: a cluster-admin compromise affects all tenants. For academic and small SaaS use cases, namespace isolation is the right balance.

**RBAC model**
Each tenant gets a dedicated `ServiceAccount` with a `Role` scoped to its namespace. No `ClusterRole` bindings are granted to tenant workloads. The `Role` covers only the resources the services need (`pods`, `configmaps`, `secrets` — read-only where possible). This follows least-privilege: a compromised tenant pod cannot read other namespaces or modify cluster-level resources.

**NetworkPolicy approach**
Default-deny ingress and egress at the namespace level, then explicitly allow:
- Ingress from `ingress-nginx` namespace (to reach the services)
- Egress to same namespace (inter-service communication within tenant)
- Egress to kube-dns (for service discovery)

Cross-tenant traffic is blocked at the CNI layer. This was validated empirically: a pod in `tenant-a` cannot curl services in `tenant-b`.

**No service mesh**
Istio or Linkerd would add mTLS and traffic observability, but the operational overhead (sidecar injection, control plane management) exceeds the scope of a single-node thesis cluster. NetworkPolicy provides adequate isolation for this threat model.

**JWT secret management**
The JWT secret is injected via `--set auth.jwtSecret=...` at install time, never stored in source control. Using `randAlphaNum` in Helm templates was rejected because it rotates the secret on every `helm upgrade`, invalidating all active sessions.

---

## 4. Tech Stack

| Component           | Technology                          |
|---------------------|-------------------------------------|
| Orchestration       | Kubernetes (k3s v1.28+)             |
| Package manager     | Helm 3                              |
| Ingress             | nginx-ingress-controller            |
| Services            | Node.js (auth, api, dashboard)      |
| Autoscaling         | HorizontalPodAutoscaler             |
| Monitoring          | Prometheus + Grafana (optional)     |
| CI                  | GitHub Actions (helm lint + YAML validation) |

---

## 5. Running Locally

**Prerequisites**: `kubectl`, `helm`, and either `minikube` or `kind` installed.

```bash
# Start a local cluster
minikube start --cpus=4 --memory=8g
# or: kind create cluster --name multi-tenant

# Enable nginx ingress (minikube)
minikube addons enable ingress

# Clone the repo
git clone https://github.com/Aliipou/multi-tenancy-kubernet.git
cd multi-tenancy-kubernet

# Provision tenant-a
helm install tenant-a ./helm-charts/saas-app \
  --set tenant.id=tenant-a \
  --set tenant.name="Tenant A" \
  --set tenant.namespace=tenant-a \
  --set auth.jwtSecret="$(openssl rand -base64 32)" \
  --set ingress.host=tenant-a.localhost

# Provision tenant-b (independent namespace)
helm install tenant-b ./helm-charts/saas-app \
  --set tenant.id=tenant-b \
  --set tenant.name="Tenant B" \
  --set tenant.namespace=tenant-b \
  --set auth.jwtSecret="$(openssl rand -base64 32)" \
  --set ingress.host=tenant-b.localhost

# Verify isolation
kubectl get all -n tenant-a
kubectl get all -n tenant-b

# Test cross-tenant network block (should fail)
kubectl run test --rm -it --image=curlimages/curl -n tenant-a -- \
  curl http://api-service.tenant-b.svc.cluster.local:3002 --max-time 3
```

---

## 6. Known Limitations

- **Manual tenant provisioning**: There is no tenant controller or operator. Each new tenant requires a `helm install`. Automating this (e.g., via a Kubernetes operator or a provisioning API) is the natural next step.
- **No service mesh**: mTLS between services within a tenant is not enforced. Traffic is encrypted at the ingress layer only. Internal pod-to-pod traffic is plaintext.
- **Single-node validation**: The cluster was tested on a single-node k3s instance. Multi-node scheduling, pod affinity, and zone-aware networking were not validated.
- **Image placeholders**: Service images reference `your-registry/auth-service:1.0.0`. You must build and push your own images or substitute with real ones before the deployments will run.
- **No tenant offboarding automation**: Deprovisioning a tenant (`helm uninstall`) removes Helm-managed resources but does not guarantee PersistentVolumeClaims are deleted. Manual cleanup may be needed.
- **ResourceQuota tuning**: Default quota values in `values.yaml` are conservative estimates. Production deployments require profiling under realistic load to set appropriate CPU/memory limits.

---

## License

MIT
