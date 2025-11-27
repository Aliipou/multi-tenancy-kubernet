#!/bin/bash
# Deploy a specific tenant using Helm

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check arguments
if [ -z "$1" ]; then
    echo "Usage: $0 <tenant-number> [--dry-run]"
    echo "Example: $0 1"
    echo "Example: $0 2 --dry-run"
    exit 1
fi

TENANT_NUM=$1
DRY_RUN=""

if [ "$2" == "--dry-run" ]; then
    DRY_RUN="--dry-run"
    print_warning "Running in DRY-RUN mode"
fi

TENANT_ID="tenant${TENANT_NUM}"
NAMESPACE="${TENANT_ID}"
VALUES_FILE="./helm-charts/saas-app/values-overrides/tenant${TENANT_NUM}.yaml"

echo "=========================================="
echo "Deploying Tenant: ${TENANT_ID}"
echo "=========================================="

# Check if values file exists
if [ ! -f "$VALUES_FILE" ]; then
    print_error "Values file not found: $VALUES_FILE"
    exit 1
fi

print_status "Values file found: $VALUES_FILE"

# Validate Helm chart
echo ""
echo "Validating Helm chart..."
helm lint ./helm-charts/saas-app -f $VALUES_FILE

if [ $? -eq 0 ]; then
    print_status "Helm chart validation passed"
else
    print_error "Helm chart validation failed"
    exit 1
fi

# Deploy using Helm
echo ""
echo "Deploying tenant ${TENANT_ID}..."

helm upgrade --install ${TENANT_ID}-app ./helm-charts/saas-app \
    --namespace ${NAMESPACE} \
    --create-namespace \
    -f ./helm-charts/saas-app/values.yaml \
    -f $VALUES_FILE \
    --wait \
    --timeout 5m \
    $DRY_RUN

if [ $? -eq 0 ]; then
    print_status "Deployment successful"
else
    print_error "Deployment failed"
    exit 1
fi

if [ -z "$DRY_RUN" ]; then
    echo ""
    echo "=========================================="
    echo "Deployment Summary"
    echo "=========================================="

    # Show deployment status
    echo ""
    echo "Deployments:"
    kubectl get deployments -n ${NAMESPACE}

    echo ""
    echo "Services:"
    kubectl get services -n ${NAMESPACE}

    echo ""
    echo "Ingress:"
    kubectl get ingress -n ${NAMESPACE}

    echo ""
    echo "HPA:"
    kubectl get hpa -n ${NAMESPACE}

    echo ""
    echo "Resource Quota:"
    kubectl get resourcequota -n ${NAMESPACE}

    echo ""
    echo "Network Policy:"
    kubectl get networkpolicy -n ${NAMESPACE}

    echo ""
    print_status "Tenant ${TENANT_ID} deployed successfully!"
    echo ""
    echo "Access your application at: http://tenant${TENANT_NUM}.localhost"
    echo ""
fi
