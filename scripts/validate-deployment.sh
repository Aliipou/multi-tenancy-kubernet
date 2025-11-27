#!/bin/bash
# Validate multi-tenant deployment

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

print_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
}

# Check arguments
if [ -z "$1" ]; then
    echo "Usage: $0 <tenant-number>"
    echo "Example: $0 1"
    exit 1
fi

TENANT_NUM=$1
TENANT_ID="tenant${TENANT_NUM}"
NAMESPACE="${TENANT_ID}"

echo "=========================================="
echo "Validating Tenant: ${TENANT_ID}"
echo "=========================================="

# Test 1: Namespace exists
print_test "Checking if namespace exists"
if kubectl get namespace ${NAMESPACE} &> /dev/null; then
    print_pass "Namespace ${NAMESPACE} exists"
else
    print_fail "Namespace ${NAMESPACE} does not exist"
fi

# Test 2: All deployments are ready
print_test "Checking deployments status"
DEPLOYMENTS=$(kubectl get deployments -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}')

for deployment in $DEPLOYMENTS; do
    READY=$(kubectl get deployment $deployment -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
    if [ "$READY" == "True" ]; then
        print_pass "Deployment $deployment is ready"
    else
        print_fail "Deployment $deployment is not ready"
    fi
done

# Test 3: All pods are running
print_test "Checking pods status"
PODS=$(kubectl get pods -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}')

for pod in $PODS; do
    STATUS=$(kubectl get pod $pod -n ${NAMESPACE} -o jsonpath='{.status.phase}')
    if [ "$STATUS" == "Running" ]; then
        print_pass "Pod $pod is running"
    else
        print_fail "Pod $pod is not running (Status: $STATUS)"
    fi
done

# Test 4: Services exist
print_test "Checking services"
EXPECTED_SERVICES=("auth" "dashboard" "api")

for svc in "${EXPECTED_SERVICES[@]}"; do
    if kubectl get service ${TENANT_ID}-app-$svc -n ${NAMESPACE} &> /dev/null; then
        print_pass "Service ${TENANT_ID}-app-$svc exists"
    else
        print_fail "Service ${TENANT_ID}-app-$svc does not exist"
    fi
done

# Test 5: Ingress exists and has host configured
print_test "Checking ingress configuration"
if kubectl get ingress -n ${NAMESPACE} &> /dev/null; then
    HOST=$(kubectl get ingress -n ${NAMESPACE} -o jsonpath='{.items[0].spec.rules[0].host}')
    if [ ! -z "$HOST" ]; then
        print_pass "Ingress exists with host: $HOST"
    else
        print_fail "Ingress exists but no host configured"
    fi
else
    print_fail "Ingress does not exist"
fi

# Test 6: ResourceQuota exists
print_test "Checking resource quota"
if kubectl get resourcequota -n ${NAMESPACE} &> /dev/null; then
    print_pass "ResourceQuota exists"
else
    print_fail "ResourceQuota does not exist"
fi

# Test 7: NetworkPolicy exists
print_test "Checking network policy"
if kubectl get networkpolicy -n ${NAMESPACE} &> /dev/null; then
    print_pass "NetworkPolicy exists"
else
    print_fail "NetworkPolicy does not exist"
fi

# Test 8: HPA exists for each service
print_test "Checking HPA configuration"
EXPECTED_HPAS=("auth" "dashboard" "api")

for hpa in "${EXPECTED_HPAS[@]}"; do
    if kubectl get hpa -n ${NAMESPACE} | grep -q "$hpa"; then
        print_pass "HPA for $hpa exists"
    else
        print_fail "HPA for $hpa does not exist"
    fi
done

# Test 9: Health checks
print_test "Checking service health endpoints"

# Get a pod from auth service
AUTH_POD=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=auth-service -o jsonpath='{.items[0].metadata.name}')
if [ ! -z "$AUTH_POD" ]; then
    HEALTH=$(kubectl exec -n ${NAMESPACE} $AUTH_POD -- wget -q -O- http://localhost:3001/health/live 2>/dev/null | grep -o '"status":"alive"')
    if [ ! -z "$HEALTH" ]; then
        print_pass "Auth service health check passed"
    else
        print_fail "Auth service health check failed"
    fi
fi

# Test 10: RBAC configuration
print_test "Checking RBAC configuration"
if kubectl get role -n ${NAMESPACE} &> /dev/null && kubectl get rolebinding -n ${NAMESPACE} &> /dev/null; then
    print_pass "RBAC Role and RoleBinding exist"
else
    print_fail "RBAC configuration incomplete"
fi

# Summary
echo ""
echo "=========================================="
echo "Validation Summary"
echo "=========================================="
echo -e "${GREEN}Tests Passed: ${TESTS_PASSED}${NC}"
echo -e "${RED}Tests Failed: ${TESTS_FAILED}${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
