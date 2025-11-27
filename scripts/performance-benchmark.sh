#!/bin/bash
# Performance benchmark for multi-tenant deployment

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Check for required tools
if ! command -v hey &> /dev/null && ! command -v ab &> /dev/null; then
    echo -e "${RED}Error: Neither 'hey' nor 'ab' (Apache Bench) is installed${NC}"
    echo "Install hey: go install github.com/rakyll/hey@latest"
    echo "Or install Apache Bench: apt-get install apache2-utils"
    exit 1
fi

LOAD_TOOL="hey"
if ! command -v hey &> /dev/null; then
    LOAD_TOOL="ab"
fi

# Check arguments
if [ -z "$1" ]; then
    echo "Usage: $0 <tenant-number> [duration-seconds] [concurrency]"
    echo "Example: $0 1 60 50"
    exit 1
fi

TENANT_NUM=$1
DURATION=${2:-60}
CONCURRENCY=${3:-50}
TENANT_ID="tenant${TENANT_NUM}"
NAMESPACE="${TENANT_ID}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="./monitoring/benchmark_${TENANT_ID}_${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"

echo -e "${CYAN}=========================================="
echo "Performance Benchmark - ${TENANT_ID}"
echo -e "==========================================${NC}"
echo "Duration: ${DURATION}s"
echo "Concurrency: ${CONCURRENCY}"
echo "Results directory: ${RESULTS_DIR}"
echo ""

# Start port-forwards
echo -e "${YELLOW}Setting up port-forwards...${NC}"

AUTH_PORT=$((13000 + TENANT_NUM))
API_PORT=$((14000 + TENANT_NUM))
DASH_PORT=$((15000 + TENANT_NUM))

kubectl port-forward -n ${NAMESPACE} svc/${TENANT_ID}-app-auth ${AUTH_PORT}:3001 &>/dev/null &
PF_AUTH=$!

kubectl port-forward -n ${NAMESPACE} svc/${TENANT_ID}-app-api ${API_PORT}:3002 &>/dev/null &
PF_API=$!

kubectl port-forward -n ${NAMESPACE} svc/${TENANT_ID}-app-dashboard ${DASH_PORT}:3000 &>/dev/null &
PF_DASH=$!

sleep 3
echo -e "${GREEN}✓ Port-forwards established${NC}"

# Collect initial metrics
echo ""
echo -e "${YELLOW}Collecting initial metrics...${NC}"
kubectl top pods -n ${NAMESPACE} > "${RESULTS_DIR}/metrics-before.txt" 2>&1 || echo "Metrics not available" > "${RESULTS_DIR}/metrics-before.txt"
kubectl get hpa -n ${NAMESPACE} >> "${RESULTS_DIR}/metrics-before.txt" 2>&1

# Test 1: Dashboard Service
echo ""
echo -e "${CYAN}Test 1: Dashboard Service Load Test${NC}"
echo "Endpoint: http://localhost:${DASH_PORT}/"

if [ "$LOAD_TOOL" == "hey" ]; then
    hey -z ${DURATION}s -c ${CONCURRENCY} http://localhost:${DASH_PORT}/ > "${RESULTS_DIR}/dashboard-results.txt" 2>&1
else
    REQUESTS=$((DURATION * CONCURRENCY))
    ab -t ${DURATION} -c ${CONCURRENCY} http://localhost:${DASH_PORT}/ > "${RESULTS_DIR}/dashboard-results.txt" 2>&1
fi

echo -e "${GREEN}✓ Dashboard test complete${NC}"
sleep 10

# Test 2: Auth Service - Health Check
echo ""
echo -e "${CYAN}Test 2: Auth Service Load Test (Health)${NC}"
echo "Endpoint: http://localhost:${AUTH_PORT}/health"

if [ "$LOAD_TOOL" == "hey" ]; then
    hey -z ${DURATION}s -c ${CONCURRENCY} http://localhost:${AUTH_PORT}/health > "${RESULTS_DIR}/auth-health-results.txt" 2>&1
else
    ab -t ${DURATION} -c ${CONCURRENCY} http://localhost:${AUTH_PORT}/health > "${RESULTS_DIR}/auth-health-results.txt" 2>&1
fi

echo -e "${GREEN}✓ Auth service health test complete${NC}"
sleep 10

# Test 3: Create a test user and token for authenticated tests
echo ""
echo -e "${CYAN}Setting up authenticated test user...${NC}"

TEST_USER="benchmark-user-$$"
TEST_EMAIL="bench-$$@example.com"
TEST_PASS="BenchPass123!"

REGISTER=$(curl -s -X POST http://localhost:${AUTH_PORT}/api/auth/register \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$TEST_USER\",\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASS\"}")

LOGIN=$(curl -s -X POST http://localhost:${AUTH_PORT}/api/auth/login \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$TEST_USER\",\"password\":\"$TEST_PASS\"}")

TOKEN=$(echo "$LOGIN" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ ! -z "$TOKEN" ]; then
    echo -e "${GREEN}✓ Test user created${NC}"
else
    echo -e "${YELLOW}⚠ Could not create test user, skipping authenticated tests${NC}"
fi

# Test 4: API Service - Task Creation (if token available)
if [ ! -z "$TOKEN" ]; then
    echo ""
    echo -e "${CYAN}Test 3: API Service Load Test (Task Creation)${NC}"
    echo "Endpoint: http://localhost:${API_PORT}/api/tasks"

    # Create a temporary file with the POST data
    cat > /tmp/task-data.json <<EOF
{"title":"Benchmark Task","description":"Performance test task","priority":"medium"}
EOF

    if [ "$LOAD_TOOL" == "hey" ]; then
        hey -z ${DURATION}s -c ${CONCURRENCY} \
            -m POST \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -D /tmp/task-data.json \
            http://localhost:${API_PORT}/api/tasks > "${RESULTS_DIR}/api-create-results.txt" 2>&1
    else
        echo "Note: ab cannot easily POST with authentication, running GET test instead"
        ab -t ${DURATION} -c ${CONCURRENCY} \
            -H "Authorization: Bearer ${TOKEN}" \
            http://localhost:${API_PORT}/api/tasks > "${RESULTS_DIR}/api-get-results.txt" 2>&1
    fi

    rm -f /tmp/task-data.json
    echo -e "${GREEN}✓ API service test complete${NC}"
fi

# Collect final metrics
echo ""
echo -e "${YELLOW}Collecting final metrics...${NC}"
sleep 5
kubectl top pods -n ${NAMESPACE} > "${RESULTS_DIR}/metrics-after.txt" 2>&1 || echo "Metrics not available" > "${RESULTS_DIR}/metrics-after.txt"
kubectl get hpa -n ${NAMESPACE} >> "${RESULTS_DIR}/metrics-after.txt" 2>&1

# Generate summary report
echo ""
echo -e "${YELLOW}Generating benchmark report...${NC}"

REPORT="${RESULTS_DIR}/BENCHMARK_REPORT.txt"

cat > "${REPORT}" <<EOF
Performance Benchmark Report
============================
Tenant: ${TENANT_ID}
Timestamp: $(date)
Duration: ${DURATION}s
Concurrency: ${CONCURRENCY}
Tool: ${LOAD_TOOL}

EOF

# Parse results
echo "Dashboard Service Results:" >> "${REPORT}"
echo "-------------------------" >> "${REPORT}"
if [ -f "${RESULTS_DIR}/dashboard-results.txt" ]; then
    if [ "$LOAD_TOOL" == "hey" ]; then
        grep -A 10 "Summary:" "${RESULTS_DIR}/dashboard-results.txt" >> "${REPORT}" 2>&1 || echo "No summary available" >> "${REPORT}"
    else
        grep "Requests per second" "${RESULTS_DIR}/dashboard-results.txt" >> "${REPORT}" 2>&1 || echo "No data" >> "${REPORT}"
        grep "Time per request" "${RESULTS_DIR}/dashboard-results.txt" >> "${REPORT}" 2>&1
    fi
fi
echo "" >> "${REPORT}"

echo "Auth Service Results:" >> "${REPORT}"
echo "--------------------" >> "${REPORT}"
if [ -f "${RESULTS_DIR}/auth-health-results.txt" ]; then
    if [ "$LOAD_TOOL" == "hey" ]; then
        grep -A 10 "Summary:" "${RESULTS_DIR}/auth-health-results.txt" >> "${REPORT}" 2>&1 || echo "No summary available" >> "${REPORT}"
    else
        grep "Requests per second" "${RESULTS_DIR}/auth-health-results.txt" >> "${REPORT}" 2>&1 || echo "No data" >> "${REPORT}"
        grep "Time per request" "${RESULTS_DIR}/auth-health-results.txt" >> "${REPORT}" 2>&1
    fi
fi
echo "" >> "${REPORT}"

if [ -f "${RESULTS_DIR}/api-create-results.txt" ] || [ -f "${RESULTS_DIR}/api-get-results.txt" ]; then
    echo "API Service Results:" >> "${REPORT}"
    echo "-------------------" >> "${REPORT}"
    if [ -f "${RESULTS_DIR}/api-create-results.txt" ]; then
        if [ "$LOAD_TOOL" == "hey" ]; then
            grep -A 10 "Summary:" "${RESULTS_DIR}/api-create-results.txt" >> "${REPORT}" 2>&1 || echo "No summary available" >> "${REPORT}"
        fi
    elif [ -f "${RESULTS_DIR}/api-get-results.txt" ]; then
        grep "Requests per second" "${RESULTS_DIR}/api-get-results.txt" >> "${REPORT}" 2>&1 || echo "No data" >> "${REPORT}"
        grep "Time per request" "${RESULTS_DIR}/api-get-results.txt" >> "${REPORT}" 2>&1
    fi
    echo "" >> "${REPORT}"
fi

echo "Resource Usage:" >> "${REPORT}"
echo "--------------" >> "${REPORT}"
echo "" >> "${REPORT}"
echo "Before Load Test:" >> "${REPORT}"
cat "${RESULTS_DIR}/metrics-before.txt" >> "${REPORT}"
echo "" >> "${REPORT}"
echo "After Load Test:" >> "${REPORT}"
cat "${RESULTS_DIR}/metrics-after.txt" >> "${REPORT}"

# Cleanup
kill $PF_AUTH $PF_API $PF_DASH 2>/dev/null

echo -e "${GREEN}✓ Benchmark report generated${NC}"

echo ""
echo -e "${CYAN}=========================================="
echo "Benchmark Complete"
echo -e "==========================================${NC}"
echo "Results saved to: ${RESULTS_DIR}"
echo "Report: ${REPORT}"
echo ""

# Display report
cat "${REPORT}"
