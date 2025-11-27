#!/bin/bash
# Deploy all tenants

set -e

GREEN='\033[0;32m'
NC='\033[0m'

echo "=========================================="
echo "Deploying All Tenants"
echo "=========================================="

for tenant in 1 2 3; do
    echo ""
    echo -e "${GREEN}Deploying Tenant ${tenant}...${NC}"
    ./scripts/deploy-tenant.sh $tenant

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Tenant ${tenant} deployed successfully${NC}"
    else
        echo "Failed to deploy tenant ${tenant}"
        exit 1
    fi

    echo ""
    echo "Waiting 10 seconds before next deployment..."
    sleep 10
done

echo ""
echo "=========================================="
echo "All Tenants Deployed Successfully!"
echo "=========================================="
echo ""
echo "Access URLs:"
echo "  Tenant 1: http://tenant1.localhost"
echo "  Tenant 2: http://tenant2.localhost"
echo "  Tenant 3: http://tenant3.localhost"
echo ""
