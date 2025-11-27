#!/bin/bash
# Run all validation and integration tests

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=========================================="
echo "Multi-Tenant Kubernetes - Full Test Suite"
echo -e "==========================================${NC}"

TOTAL_PASSED=0
TOTAL_FAILED=0

# Test each tenant
for tenant in 1 2 3; do
    echo ""
    echo -e "${CYAN}=========================================="
    echo "Testing Tenant $tenant"
    echo -e "==========================================${NC}"

    # Deployment validation
    echo ""
    echo -e "${YELLOW}Running deployment validation...${NC}"
    if ./scripts/validate-deployment.sh $tenant; then
        ((TOTAL_PASSED++))
    else
        ((TOTAL_FAILED++))
    fi

    # Integration tests
    echo ""
    echo -e "${YELLOW}Running integration tests...${NC}"
    if ./scripts/test-integration.sh $tenant; then
        ((TOTAL_PASSED++))
    else
        ((TOTAL_FAILED++))
    fi
done

# Isolation tests (run once for all tenants)
echo ""
echo -e "${CYAN}=========================================="
echo "Testing Multi-Tenant Isolation"
echo -e "==========================================${NC}"

if ./scripts/test-isolation.sh; then
    ((TOTAL_PASSED++))
else
    ((TOTAL_FAILED++))
fi

# Final summary
echo ""
echo -e "${CYAN}=========================================="
echo "Overall Test Summary"
echo -e "==========================================${NC}"
echo -e "${GREEN}Test Suites Passed: ${TOTAL_PASSED}${NC}"
echo -e "${RED}Test Suites Failed: ${TOTAL_FAILED}${NC}"

if [ $TOTAL_FAILED -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ All test suites passed successfully!${NC}"
    echo -e "${GREEN}✓ Multi-tenant deployment is working correctly${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}✗ Some test suites failed${NC}"
    echo -e "${YELLOW}Review the logs above for details${NC}"
    exit 1
fi
