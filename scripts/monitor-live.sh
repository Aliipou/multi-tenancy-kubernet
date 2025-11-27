#!/bin/bash
# Live monitoring dashboard for all tenants

REFRESH_INTERVAL=${1:-5}

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

while true; do
    clear
    echo -e "${CYAN}=========================================="
    echo "Multi-Tenant Kubernetes Live Monitor"
    echo "$(date)"
    echo -e "==========================================${NC}"

    for tenant_num in 1 2 3; do
        TENANT_ID="tenant${tenant_num}"
        NAMESPACE="${TENANT_ID}"

        echo ""
        echo -e "${YELLOW}========== ${TENANT_ID} ==========${NC}"

        # Pod status
        echo ""
        echo -e "${GREEN}Pods:${NC}"
        kubectl get pods -n ${NAMESPACE} --no-headers 2>/dev/null | awk '{print $1 " - " $3 " (" $2 ")"}' || echo "No pods found"

        # Resource usage
        echo ""
        echo -e "${GREEN}Resource Usage:${NC}"
        kubectl top pods -n ${NAMESPACE} --no-headers 2>/dev/null || echo "Metrics not available"

        # HPA status
        echo ""
        echo -e "${GREEN}HPA:${NC}"
        kubectl get hpa -n ${NAMESPACE} --no-headers 2>/dev/null || echo "No HPA configured"

        # Resource quota
        echo ""
        echo -e "${GREEN}Resource Quota:${NC}"
        kubectl describe resourcequota -n ${NAMESPACE} 2>/dev/null | grep -A 5 "Used" || echo "No quota info"
    done

    # Cluster nodes
    echo ""
    echo -e "${YELLOW}========== Cluster Nodes ==========${NC}"
    kubectl top nodes 2>/dev/null || echo "Metrics not available"

    echo ""
    echo -e "${CYAN}Refreshing every ${REFRESH_INTERVAL} seconds... (Ctrl+C to exit)${NC}"
    sleep ${REFRESH_INTERVAL}
done
