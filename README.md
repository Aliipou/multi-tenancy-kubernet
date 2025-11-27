# Multi-Tenant Kubernetes SaaS Platform

A production-ready implementation of a multi-tenant SaaS platform on Kubernetes using namespace-based isolation. This project demonstrates best practices for resource management, security, autoscaling, and tenant isolation in cloud-native environments.

## 📋 Table of Contents

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
- [Troubleshooting](#troubleshooting)

## 🎯 Overview

This project implements a multi-tenant SaaS application on Kubernetes with:

- **3 microservices**: Auth, Dashboard, and API services
- **Namespace-based isolation**: Each tenant has its own namespace
- **Resource management**: ResourceQuotas and LimitRanges per tenant
- **Autoscaling**: Horizontal Pod Autoscaler (HPA) for each service
- **Security**: RBAC, NetworkPolicies, and Pod Security Contexts
- **Monitoring**: Prometheus metrics and health checks

### Tenants

The platform comes pre-configured with three tenant profiles:

1. **Tenant 1** (Standard): Moderate resources for typical workloads
2. **Tenant 2** (Enterprise): Higher resources for enterprise customers
3. **Tenant 3** (Startup): Minimal resources for cost-conscious startups

## 🏗️ Architecture

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
    └────────────────────────────────────────────────────┘
```

### Services

Each tenant deployment includes:

- **Dashboard Service** (Port 3000): Frontend UI
- **Auth Service** (Port 3001): User authentication with JWT
- **API Service** (Port 3002): Business logic and data management

## ✨ Features

### Multi-Tenancy

- **Namespace Isolation**: Each tenant operates in its own namespace
- **Resource Quotas**: CPU, memory, and pod limits per tenant
- **Network Policies**: Network traffic isolation between tenants
- **RBAC**: Role-based access control per namespace

### Scalability

- **Horizontal Pod Autoscaling**: Auto-scale based on CPU/memory usage
- **Resource Requests/Limits**: Proper resource allocation
- **Pod Disruption Budgets**: Ensure availability during updates

### Security

- **JWT Authentication**: Secure token-based auth
- **Non-root Containers**: All services run as non-root users
- **Network Policies**: Restrict inter-tenant communication
- **Security Contexts**: Drop capabilities and read-only root filesystem

### Observability

- **Health Checks**: Liveness, readiness, and startup probes
- **Prometheus Metrics**: Built-in metrics endpoints
- **Structured Logging**: JSON-formatted logs
- **Request Tracking**: Request IDs and tenant identification

## 📦 Prerequisites

### Required Software

- **Docker** (v20.10+)
- **Kubernetes Cluster** (v1.25+)
  - Local: kind, minikube, or Docker Desktop
  - Cloud: GKE, EKS, or AKS
- **kubectl** (v1.25+)
- **Helm** (v3.10+)

### Optional Tools

- **hey** or **Apache Bench** (for load testing)
- **curl** (for API testing)

## 🚀 Quick Start

### 1. Setup Kubernetes Cluster

```bash
# For Linux/Mac
./scripts/setup-cluster.sh

# For Windows (PowerShell)
.\scripts\setup-cluster.ps1
```

### 2. Build Docker Images

```bash
# Build all services
cd services/auth-service && docker build -t your-registry/auth-service:1.0.0 .
cd ../dashboard-service && docker build -t your-registry/dashboard-service:1.0.0 .
cd ../api-service && docker build -t your-registry/api-service:1.0.0 .

# Push to registry
docker push your-registry/auth-service:1.0.0
docker push your-registry/dashboard-service:1.0.0
docker push your-registry/api-service:1.0.0
```

### 3. Update Image References

Edit `helm-charts/saas-app/values.yaml` and update the image repositories:

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
# For Linux/Mac
./scripts/deploy-all-tenants.sh

# For Windows (PowerShell)
.\scripts\deploy-all-tenants.ps1
```

### 5. Access Tenants

Add to your `/etc/hosts` (Linux/Mac) or `C:\Windows\System32\drivers\etc\hosts` (Windows):

```
127.0.0.1 tenant1.localhost
127.0.0.1 tenant2.localhost
127.0.0.1 tenant3.localhost
```

Access in browser:
- http://tenant1.localhost
- http://tenant2.localhost
- http://tenant3.localhost

## 📁 Project Structure

```
.
├── services/                    # Microservices
│   ├── auth-service/           # Authentication service
│   ├── dashboard-service/      # Frontend dashboard
│   └── api-service/            # Backend API
├── helm-charts/                # Helm charts
│   └── saas-app/              # Main application chart
│       ├── templates/          # Kubernetes manifests
│       ├── values.yaml         # Default values
│       └── values-overrides/   # Tenant-specific configs
├── scripts/                    # Automation scripts
│   ├── setup-cluster.*         # Cluster setup
│   ├── deploy-tenant.*         # Tenant deployment
│   ├── validate-deployment.*   # Deployment validation
│   ├── test-*.sh               # Test scripts
│   ├── collect-metrics.sh      # Metrics collection
│   └── monitor-live.sh         # Live monitoring
├── docs/                       # Documentation
└── monitoring/                 # Monitoring outputs
```

## 🔧 Deployment

### Deploy Single Tenant

```bash
# Linux/Mac
./scripts/deploy-tenant.sh 1

# Windows
.\scripts\deploy-tenant.ps1 -TenantNumber 1
```

### Deploy with Dry-Run

```bash
# Linux/Mac
./scripts/deploy-tenant.sh 1 --dry-run

# Windows
.\scripts\deploy-tenant.ps1 -TenantNumber 1 -DryRun
```

### Customize Tenant Resources

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

### Delete Tenant

```bash
# Linux/Mac
./scripts/cleanup-tenant.sh 1

# Windows
.\scripts\cleanup-tenant.ps1 -TenantNumber 1
```

## 🧪 Testing

### Validation Tests

```bash
# Validate deployment
./scripts/validate-deployment.sh 1

# Test isolation between tenants
./scripts/test-isolation.sh

# Test autoscaling
./scripts/test-autoscaling.sh 1 60

# Integration tests
./scripts/test-integration.sh 1

# Run all tests
./scripts/run-all-tests.sh
```

### Manual Testing

```bash
# Register a user
curl -X POST http://tenant1.localhost/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","email":"test@example.com","password":"Test123!"}'

# Login
curl -X POST http://tenant1.localhost/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"Test123!"}'

# Create task (use token from login)
curl -X POST http://tenant1.localhost/api/tasks \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Test Task","description":"Testing API"}'
```

## 📊 Monitoring

### Collect Metrics

```bash
./scripts/collect-metrics.sh
```

Metrics are saved to `monitoring/metrics_TIMESTAMP/`

### Performance Benchmarking

```bash
./scripts/performance-benchmark.sh 1 60 50
# Args: tenant-number duration concurrency
```

Results saved to `monitoring/benchmark_tenant1_TIMESTAMP/`

### Live Monitoring

```bash
./scripts/monitor-live.sh 5
# Refreshes every 5 seconds
```

### View Logs

```bash
# All logs for a tenant
kubectl logs -n tenant1 -l app.kubernetes.io/instance=tenant1-app --tail=100

# Specific service
kubectl logs -n tenant1 -l app.kubernetes.io/component=api-service --tail=100 -f
```

### Prometheus Metrics

Each service exposes metrics at `/metrics`:

```bash
kubectl port-forward -n tenant1 svc/tenant1-app-api 3002:3002
curl http://localhost:3002/metrics
```

## 🔒 Security

### JWT Secrets

Each tenant has a unique JWT secret stored in Kubernetes secrets:

```bash
kubectl get secret -n tenant1 tenant1-app-secrets -o jsonpath='{.data.jwt-secret}' | base64 -d
```

### RBAC

View tenant RBAC configuration:

```bash
kubectl get role,rolebinding -n tenant1
kubectl describe role -n tenant1
```

### Network Policies

View network policies:

```bash
kubectl get networkpolicy -n tenant1
kubectl describe networkpolicy -n tenant1
```

### Security Best Practices

- All containers run as non-root (UID 1001)
- Capabilities dropped
- Resource limits enforced
- Network traffic restricted
- Secrets managed by Kubernetes

## 🐛 Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -n tenant1

# Describe pod
kubectl describe pod <pod-name> -n tenant1

# Check events
kubectl get events -n tenant1 --sort-by='.lastTimestamp'
```

### Service Not Accessible

```bash
# Check ingress
kubectl get ingress -n tenant1

# Check service endpoints
kubectl get endpoints -n tenant1

# Test service internally
kubectl run -n tenant1 -it --rm debug --image=busybox --restart=Never -- sh
wget -O- http://tenant1-app-auth:3001/health
```

### Resource Quota Exceeded

```bash
# Check quota usage
kubectl describe resourcequota -n tenant1

# Increase quota in values-overrides/tenant1.yaml
```

### HPA Not Scaling

```bash
# Check metrics server
kubectl get apiservices | grep metrics

# Check HPA status
kubectl get hpa -n tenant1
kubectl describe hpa -n tenant1

# View current metrics
kubectl top pods -n tenant1
```

## 📚 Additional Documentation

- [Architecture Details](docs/ARCHITECTURE.md)
- [Deployment Guide](docs/DEPLOYMENT.md)
- [Testing Guide](docs/TESTING.md)
- [Evaluation & Comparison](docs/EVALUATION.md)
- [API Documentation](docs/API.md)

## 🤝 Contributing

This is a thesis project. For questions or suggestions, please contact the author.

## 📄 License

MIT License - See LICENSE file for details.

## 👤 Author

Thesis Project - Multi-Tenant Kubernetes Implementation

## 🙏 Acknowledgments

- Kubernetes community
- Helm project
- NGINX Ingress Controller
- Prometheus monitoring

---

**Note**: This is a demonstration/thesis project. For production use, consider:
- Persistent storage for data
- Database integration (PostgreSQL, MongoDB)
- TLS/SSL certificates
- External authentication (OAuth, SAML)
- Advanced monitoring (Prometheus, Grafana)
- Backup and disaster recovery
- Multi-region deployment
