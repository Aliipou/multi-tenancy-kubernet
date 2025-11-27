#!/bin/bash
# End-to-end integration tests

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
AUTH_PORT=$((13000 + TENANT_NUM))
API_PORT=$((14000 + TENANT_NUM))

echo "=========================================="
echo "Integration Tests for Tenant: ${TENANT_ID}"
echo "=========================================="

# Start port-forwards
print_test "Setting up port-forwards"
kubectl port-forward -n ${NAMESPACE} svc/${TENANT_ID}-app-auth ${AUTH_PORT}:3001 &>/dev/null &
PF_AUTH=$!

kubectl port-forward -n ${NAMESPACE} svc/${TENANT_ID}-app-api ${API_PORT}:3002 &>/dev/null &
PF_API=$!

sleep 3
print_pass "Port-forwards established"

# Test 1: Health checks
print_test "Testing health endpoints"

AUTH_HEALTH=$(curl -s http://localhost:${AUTH_PORT}/health/live)
if echo "$AUTH_HEALTH" | grep -q '"status":"alive"'; then
    print_pass "Auth service is alive"
else
    print_fail "Auth service health check failed"
fi

API_HEALTH=$(curl -s http://localhost:${API_PORT}/health/live)
if echo "$API_HEALTH" | grep -q '"status":"alive"'; then
    print_pass "API service is alive"
else
    print_fail "API service health check failed"
fi

# Test 2: User registration
print_test "Testing user registration"

TEST_USER="integration-test-$$"
TEST_EMAIL="test-$$@example.com"
TEST_PASS="TestPass123!"

REGISTER_RESPONSE=$(curl -s -X POST http://localhost:${AUTH_PORT}/api/auth/register \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$TEST_USER\",\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASS\"}")

if echo "$REGISTER_RESPONSE" | grep -q '"success":true'; then
    print_pass "User registration successful"
else
    print_fail "User registration failed: $REGISTER_RESPONSE"
fi

# Test 3: User login
print_test "Testing user login"

LOGIN_RESPONSE=$(curl -s -X POST http://localhost:${AUTH_PORT}/api/auth/login \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$TEST_USER\",\"password\":\"$TEST_PASS\"}")

if echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    print_pass "User login successful"
    TOKEN=$(echo "$LOGIN_RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
else
    print_fail "User login failed"
    TOKEN=""
fi

# Test 4: Token verification
if [ ! -z "$TOKEN" ]; then
    print_test "Testing token verification"

    VERIFY_RESPONSE=$(curl -s -X POST http://localhost:${AUTH_PORT}/api/auth/verify \
        -H "Authorization: Bearer $TOKEN")

    if echo "$VERIFY_RESPONSE" | grep -q '"success":true'; then
        print_pass "Token verification successful"
    else
        print_fail "Token verification failed"
    fi
fi

# Test 5: Create task (API service)
if [ ! -z "$TOKEN" ]; then
    print_test "Testing task creation"

    TASK_RESPONSE=$(curl -s -X POST http://localhost:${API_PORT}/api/tasks \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"title":"Integration Test Task","description":"This is a test task","priority":"high"}')

    if echo "$TASK_RESPONSE" | grep -q '"success":true'; then
        print_pass "Task creation successful"
        TASK_ID=$(echo "$TASK_RESPONSE" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
    else
        print_fail "Task creation failed"
        TASK_ID=""
    fi
fi

# Test 6: Get tasks list
if [ ! -z "$TOKEN" ]; then
    print_test "Testing task retrieval"

    TASKS_RESPONSE=$(curl -s http://localhost:${API_PORT}/api/tasks \
        -H "Authorization: Bearer $TOKEN")

    if echo "$TASKS_RESPONSE" | grep -q '"success":true'; then
        TASK_COUNT=$(echo "$TASKS_RESPONSE" | grep -o '"count":[0-9]*' | cut -d':' -f2)
        print_pass "Task retrieval successful (found $TASK_COUNT tasks)"
    else
        print_fail "Task retrieval failed"
    fi
fi

# Test 7: Update task
if [ ! -z "$TOKEN" ] && [ ! -z "$TASK_ID" ]; then
    print_test "Testing task update"

    UPDATE_RESPONSE=$(curl -s -X PUT http://localhost:${API_PORT}/api/tasks/${TASK_ID} \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"status":"completed"}')

    if echo "$UPDATE_RESPONSE" | grep -q '"success":true'; then
        print_pass "Task update successful"
    else
        print_fail "Task update failed"
    fi
fi

# Test 8: Task statistics
if [ ! -z "$TOKEN" ]; then
    print_test "Testing task statistics"

    STATS_RESPONSE=$(curl -s http://localhost:${API_PORT}/api/tasks/stats/overview \
        -H "Authorization: Bearer $TOKEN")

    if echo "$STATS_RESPONSE" | grep -q '"success":true'; then
        print_pass "Task statistics retrieval successful"
    else
        print_fail "Task statistics retrieval failed"
    fi
fi

# Test 9: Delete task
if [ ! -z "$TOKEN" ] && [ ! -z "$TASK_ID" ]; then
    print_test "Testing task deletion"

    DELETE_RESPONSE=$(curl -s -X DELETE http://localhost:${API_PORT}/api/tasks/${TASK_ID} \
        -H "Authorization: Bearer $TOKEN")

    if echo "$DELETE_RESPONSE" | grep -q '"success":true'; then
        print_pass "Task deletion successful"
    else
        print_fail "Task deletion failed"
    fi
fi

# Test 10: Unauthorized access (no token)
print_test "Testing unauthorized access protection"

UNAUTH_RESPONSE=$(curl -s http://localhost:${API_PORT}/api/tasks)

if echo "$UNAUTH_RESPONSE" | grep -q '"success":false'; then
    print_pass "Unauthorized access properly blocked"
else
    print_fail "Unauthorized access not properly blocked"
fi

# Cleanup
kill $PF_AUTH $PF_API 2>/dev/null

# Summary
echo ""
echo "=========================================="
echo "Integration Test Summary"
echo "=========================================="
echo -e "${GREEN}Tests Passed: ${TESTS_PASSED}${NC}"
echo -e "${RED}Tests Failed: ${TESTS_FAILED}${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All integration tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some integration tests failed!${NC}"
    exit 1
fi
