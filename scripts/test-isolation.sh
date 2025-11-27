#!/bin/bash
# Test multi-tenancy isolation

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

echo "=========================================="
echo "Testing Multi-Tenancy Isolation"
echo "=========================================="

# Test 1: Namespace isolation - tenant1 cannot access tenant2 pods
print_test "Testing namespace isolation: tenant1 cannot list pods in tenant2"

POD_TENANT1=$(kubectl get pods -n tenant1 -l app.kubernetes.io/component=auth-service -o jsonpath='{.items[0].metadata.name}')

if [ ! -z "$POD_TENANT1" ]; then
    # Try to list pods in tenant2 from tenant1 pod (should fail with RBAC)
    RESULT=$(kubectl exec -n tenant1 $POD_TENANT1 -- wget -q -O- --header="Authorization: Bearer fake-token" http://kubernetes.default.svc/api/v1/namespaces/tenant2/pods 2>&1 || true)

    if echo "$RESULT" | grep -q "Forbidden\|403\|Unauthorized\|401"; then
        print_pass "Tenant1 cannot access tenant2 namespace (isolation working)"
    else
        # Also consider it passing if connection is refused (network policy working)
        if echo "$RESULT" | grep -q "refused\|timeout"; then
            print_pass "Tenant1 cannot connect to tenant2 (network isolation working)"
        else
            print_fail "Tenant1 may have access to tenant2 namespace"
        fi
    fi
else
    print_fail "Cannot find tenant1 pod for testing"
fi

# Test 2: Network policy - cross-namespace traffic should be blocked
print_test "Testing network policy: tenant1 cannot connect to tenant2 services"

AUTH_POD_T1=$(kubectl get pods -n tenant1 -l app.kubernetes.io/component=auth-service -o jsonpath='{.items[0].metadata.name}')
AUTH_SVC_T2=$(kubectl get svc -n tenant2 -l app.kubernetes.io/component=auth-service -o jsonpath='{.items[0].metadata.name}')

if [ ! -z "$AUTH_POD_T1" ] && [ ! -z "$AUTH_SVC_T2" ]; then
    # Try to connect from tenant1 pod to tenant2 service
    RESULT=$(kubectl exec -n tenant1 $AUTH_POD_T1 -- timeout 5 wget -q -O- http://${AUTH_SVC_T2}.tenant2.svc.cluster.local:3001/health 2>&1 || true)

    if echo "$RESULT" | grep -q "timed out\|Connection refused"; then
        print_pass "Cross-tenant network traffic is blocked"
    else
        print_fail "Cross-tenant network traffic is allowed (network policy may not be working)"
    fi
else
    print_fail "Cannot find pods/services for network policy testing"
fi

# Test 3: Resource quota enforcement
print_test "Testing resource quota limits"

for tenant in tenant1 tenant2 tenant3; do
    QUOTA_USED=$(kubectl get resourcequota -n $tenant -o jsonpath='{.items[0].status.used}' 2>/dev/null || echo "{}")
    QUOTA_HARD=$(kubectl get resourcequota -n $tenant -o jsonpath='{.items[0].status.hard}' 2>/dev/null || echo "{}")

    if [ "$QUOTA_USED" != "{}" ] && [ "$QUOTA_HARD" != "{}" ]; then
        print_pass "Resource quota is configured and tracking for $tenant"
    else
        print_fail "Resource quota is not properly configured for $tenant"
    fi
done

# Test 4: Tenant data isolation - create user in tenant1, verify not in tenant2
print_test "Testing tenant data isolation"

# Get auth service for tenant1
AUTH_SVC_T1="tenant1-app-auth.tenant1.svc.cluster.local"
AUTH_SVC_T2="tenant2-app-auth.tenant2.svc.cluster.local"

# Create a test user in tenant1
TEST_USER="isolation-test-user-$$"
TEST_EMAIL="test-$$@example.com"
TEST_PASS="TestPass123!"

# Try to register user in tenant1 (using port-forward in background)
kubectl port-forward -n tenant1 svc/tenant1-app-auth 13001:3001 &>/dev/null &
PF_PID_T1=$!
sleep 2

REGISTER_RESULT=$(curl -s -X POST http://localhost:13001/api/auth/register \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$TEST_USER\",\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASS\"}" 2>/dev/null || echo '{"success":false}')

kill $PF_PID_T1 2>/dev/null || true

if echo "$REGISTER_RESULT" | grep -q '"success":true'; then
    print_pass "User registered in tenant1"

    # Now check if user exists in tenant2 (should not)
    kubectl port-forward -n tenant2 svc/tenant2-app-auth 13002:3001 &>/dev/null &
    PF_PID_T2=$!
    sleep 2

    LOGIN_RESULT=$(curl -s -X POST http://localhost:13002/api/auth/login \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$TEST_USER\",\"password\":\"$TEST_PASS\"}" 2>/dev/null || echo '{"success":false}')

    kill $PF_PID_T2 2>/dev/null || true

    if echo "$LOGIN_RESULT" | grep -q '"success":false'; then
        print_pass "User from tenant1 cannot login to tenant2 (data isolation working)"
    else
        print_fail "User from tenant1 can login to tenant2 (data isolation NOT working)"
    fi
else
    print_fail "Failed to create test user in tenant1"
fi

# Test 5: Each tenant has its own secrets
print_test "Testing tenant secret isolation"

SECRET_T1=$(kubectl get secret -n tenant1 -o jsonpath='{.items[?(@.metadata.name=="tenant1-app-secrets")].data.jwt-secret}')
SECRET_T2=$(kubectl get secret -n tenant2 -o jsonpath='{.items[?(@.metadata.name=="tenant2-app-secrets")].data.jwt-secret}')
SECRET_T3=$(kubectl get secret -n tenant3 -o jsonpath='{.items[?(@.metadata.name=="tenant3-app-secrets")].data.jwt-secret}')

if [ "$SECRET_T1" != "$SECRET_T2" ] && [ "$SECRET_T2" != "$SECRET_T3" ] && [ "$SECRET_T1" != "$SECRET_T3" ]; then
    print_pass "Each tenant has unique secrets"
else
    print_fail "Tenants may be sharing secrets"
fi

# Summary
echo ""
echo "=========================================="
echo "Isolation Test Summary"
echo "=========================================="
echo -e "${GREEN}Tests Passed: ${TESTS_PASSED}${NC}"
echo -e "${RED}Tests Failed: ${TESTS_FAILED}${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All isolation tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some isolation tests failed!${NC}"
    exit 1
fi
