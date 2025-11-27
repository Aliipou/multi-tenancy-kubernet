#!/bin/bash
# Collect metrics from all tenants

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
METRICS_DIR="./monitoring/metrics_${TIMESTAMP}"

mkdir -p "${METRICS_DIR}"

echo -e "${CYAN}=========================================="
echo "Collecting Metrics from All Tenants"
echo -e "==========================================${NC}"
echo "Output directory: ${METRICS_DIR}"
echo ""

# Collect metrics for each tenant
for tenant_num in 1 2 3; do
    TENANT_ID="tenant${tenant_num}"
    NAMESPACE="${TENANT_ID}"
    TENANT_DIR="${METRICS_DIR}/${TENANT_ID}"

    mkdir -p "${TENANT_DIR}"

    echo -e "${YELLOW}Collecting metrics for ${TENANT_ID}...${NC}"

    # Resource usage
    echo "# Resource Usage - $(date)" > "${TENANT_DIR}/resource-usage.txt"
    kubectl top pods -n ${NAMESPACE} >> "${TENANT_DIR}/resource-usage.txt" 2>&1 || echo "Metrics not available" >> "${TENANT_DIR}/resource-usage.txt"

    # Resource quota status
    echo "# Resource Quota Status - $(date)" > "${TENANT_DIR}/resource-quota.txt"
    kubectl describe resourcequota -n ${NAMESPACE} >> "${TENANT_DIR}/resource-quota.txt" 2>&1

    # Pod status
    echo "# Pod Status - $(date)" > "${TENANT_DIR}/pod-status.txt"
    kubectl get pods -n ${NAMESPACE} -o wide >> "${TENANT_DIR}/pod-status.txt" 2>&1

    # Deployment status
    echo "# Deployment Status - $(date)" > "${TENANT_DIR}/deployment-status.txt"
    kubectl get deployments -n ${NAMESPACE} -o wide >> "${TENANT_DIR}/deployment-status.txt" 2>&1

    # HPA status
    echo "# HPA Status - $(date)" > "${TENANT_DIR}/hpa-status.txt"
    kubectl get hpa -n ${NAMESPACE} >> "${TENANT_DIR}/hpa-status.txt" 2>&1

    # Service status
    echo "# Service Status - $(date)" > "${TENANT_DIR}/service-status.txt"
    kubectl get services -n ${NAMESPACE} -o wide >> "${TENANT_DIR}/service-status.txt" 2>&1

    # Ingress status
    echo "# Ingress Status - $(date)" > "${TENANT_DIR}/ingress-status.txt"
    kubectl get ingress -n ${NAMESPACE} -o wide >> "${TENANT_DIR}/ingress-status.txt" 2>&1

    # Pod events
    echo "# Pod Events - $(date)" > "${TENANT_DIR}/pod-events.txt"
    kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' >> "${TENANT_DIR}/pod-events.txt" 2>&1

    # Collect Prometheus metrics from each service
    echo "# Collecting Prometheus metrics..."

    AUTH_POD=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=auth-service -o jsonpath='{.items[0].metadata.name}')
    if [ ! -z "$AUTH_POD" ]; then
        kubectl exec -n ${NAMESPACE} ${AUTH_POD} -- wget -q -O- http://localhost:3001/metrics > "${TENANT_DIR}/auth-service-metrics.txt" 2>&1 || echo "Failed to collect" > "${TENANT_DIR}/auth-service-metrics.txt"
    fi

    API_POD=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=api-service -o jsonpath='{.items[0].metadata.name}')
    if [ ! -z "$API_POD" ]; then
        kubectl exec -n ${NAMESPACE} ${API_POD} -- wget -q -O- http://localhost:3002/metrics > "${TENANT_DIR}/api-service-metrics.txt" 2>&1 || echo "Failed to collect" > "${TENANT_DIR}/api-service-metrics.txt"
    fi

    DASH_POD=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=dashboard-service -o jsonpath='{.items[0].metadata.name}')
    if [ ! -z "$DASH_POD" ]; then
        kubectl exec -n ${NAMESPACE} ${DASH_POD} -- wget -q -O- http://localhost:3000/metrics > "${TENANT_DIR}/dashboard-service-metrics.txt" 2>&1 || echo "Failed to collect" > "${TENANT_DIR}/dashboard-service-metrics.txt"
    fi

    echo -e "${GREEN}✓ Metrics collected for ${TENANT_ID}${NC}"
done

# Collect cluster-wide metrics
echo ""
echo -e "${YELLOW}Collecting cluster-wide metrics...${NC}"
CLUSTER_DIR="${METRICS_DIR}/cluster"
mkdir -p "${CLUSTER_DIR}"

# Node resources
echo "# Node Resources - $(date)" > "${CLUSTER_DIR}/nodes.txt"
kubectl top nodes >> "${CLUSTER_DIR}/nodes.txt" 2>&1 || echo "Metrics not available" >> "${CLUSTER_DIR}/nodes.txt"

# All namespaces
echo "# All Namespaces - $(date)" > "${CLUSTER_DIR}/namespaces.txt"
kubectl get namespaces >> "${CLUSTER_DIR}/namespaces.txt" 2>&1

# Cluster info
echo "# Cluster Info - $(date)" > "${CLUSTER_DIR}/cluster-info.txt"
kubectl cluster-info >> "${CLUSTER_DIR}/cluster-info.txt" 2>&1

echo -e "${GREEN}✓ Cluster metrics collected${NC}"

# Generate summary report
echo ""
echo -e "${YELLOW}Generating summary report...${NC}"

REPORT="${METRICS_DIR}/SUMMARY_REPORT.txt"

cat > "${REPORT}" <<EOF
Multi-Tenant Kubernetes Metrics Summary
========================================
Collection Time: $(date)
Collection Directory: ${METRICS_DIR}

EOF

for tenant_num in 1 2 3; do
    TENANT_ID="tenant${tenant_num}"
    NAMESPACE="${TENANT_ID}"

    cat >> "${REPORT}" <<EOF

Tenant: ${TENANT_ID}
--------------------
EOF

    # Pod count
    POD_COUNT=$(kubectl get pods -n ${NAMESPACE} --no-headers 2>/dev/null | wc -l)
    echo "Total Pods: ${POD_COUNT}" >> "${REPORT}"

    # Running pods
    RUNNING_PODS=$(kubectl get pods -n ${NAMESPACE} --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    echo "Running Pods: ${RUNNING_PODS}" >> "${REPORT}"

    # Resource quota usage
    echo "" >> "${REPORT}"
    echo "Resource Quota:" >> "${REPORT}"
    kubectl get resourcequota -n ${NAMESPACE} -o custom-columns=NAME:.metadata.name,CPU_USED:.status.used.requests\\.cpu,CPU_LIMIT:.status.hard.requests\\.cpu,MEMORY_USED:.status.used.requests\\.memory,MEMORY_LIMIT:.status.hard.requests\\.memory --no-headers >> "${REPORT}" 2>&1

    # HPA status
    echo "" >> "${REPORT}"
    echo "HPA Status:" >> "${REPORT}"
    kubectl get hpa -n ${NAMESPACE} --no-headers >> "${REPORT}" 2>&1

    echo "" >> "${REPORT}"
done

echo -e "${GREEN}✓ Summary report generated${NC}"

echo ""
echo -e "${CYAN}=========================================="
echo "Metrics Collection Complete"
echo -e "==========================================${NC}"
echo "Results saved to: ${METRICS_DIR}"
echo "Summary report: ${REPORT}"
echo ""

# Display summary
cat "${REPORT}"
