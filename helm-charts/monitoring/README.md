# Monitoring Stack — Prometheus + Grafana

Deploys **kube-prometheus-stack** with a pre-built Grafana dashboard covering
tenant service metrics, HPA autoscaling, and FL coordinator telemetry.

## Quick Deploy

```bash
# 1. Add the chart repo (once)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 2. Deploy
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    -f helm-charts/monitoring/kube-prometheus-values.yaml

# 3. Import dashboard
kubectl apply -f helm-charts/monitoring/dashboards/grafana-configmap.yaml

# 4. Open Grafana
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# http://localhost:3000  (admin / changeme)
```

## Dashboard Panels

| Panel | Metric | Source |
|-------|--------|--------|
| HTTP Request Rate by Namespace | `http_requests_total` | Service annotation |
| P95 / P99 Latency by Namespace | `http_request_duration_seconds_bucket` | Service annotation |
| CPU Usage by Tenant Namespace | `container_cpu_usage_seconds_total` | cAdvisor |
| Memory Working Set by Tenant | `container_memory_working_set_bytes` | cAdvisor |
| HPA Replica Count by Tenant | `kube_horizontalpodautoscaler_*` | kube-state-metrics |
| HPA CPU Utilisation % | `kube_horizontalpodautoscaler_status_*` | kube-state-metrics |
| FL Rounds Completed | `fl_rounds_total` | FL coordinator `/metrics` |
| FL Rounds by Tenant | `fl_tenant_rounds_total` | FL coordinator `/metrics` |
| FL Samples by Tenant | `fl_tenant_samples_total` | FL coordinator `/metrics` |
| FL Pending Updates | `fl_pending_updates` | FL coordinator `/metrics` |
| FL Rejected Updates | `fl_rejected_updates_total` | FL coordinator `/metrics` |
| FL Aggregation Duration | `fl_aggregation_duration_seconds` | FL coordinator `/metrics` |

## Scraping

The FL coordinator pod is annotated for automatic Prometheus discovery:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```

Tenant service pods inherit the same annotation pattern via the saas-app Helm chart.
