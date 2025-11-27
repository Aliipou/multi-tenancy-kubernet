#!/bin/bash
# Remove a specific tenant deployment

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

if [ -z "$1" ]; then
    echo "Usage: $0 <tenant-number>"
    echo "Example: $0 1"
    exit 1
fi

TENANT_NUM=$1
TENANT_ID="tenant${TENANT_NUM}"
NAMESPACE="${TENANT_ID}"

echo "=========================================="
echo "Cleaning up Tenant: ${TENANT_ID}"
echo "=========================================="

print_warning "This will delete all resources for tenant ${TENANT_ID}"
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Cleanup cancelled"
    exit 0
fi

# Uninstall Helm release
echo ""
echo "Uninstalling Helm release..."
helm uninstall ${TENANT_ID}-app --namespace ${NAMESPACE} || true

# Delete namespace (this will delete all resources)
echo ""
echo "Deleting namespace ${NAMESPACE}..."
kubectl delete namespace ${NAMESPACE} --timeout=60s || true

print_status "Tenant ${TENANT_ID} cleaned up successfully"
