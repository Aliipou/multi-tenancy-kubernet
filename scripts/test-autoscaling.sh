#!/bin/bash
# Test Horizontal Pod Autoscaling

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

# Check arguments
if [ -z "$1" ]; then
    echo "Usage: $0 <tenant-number> [duration-seconds]"
    echo "Example: $0 1 60"
    exit 1
fi

TENANT_NUM=$1
DURATION=${2:-60}
TENANT_ID="tenant${TENANT_NUM}"
NAMESPACE="${TENANT_ID}"

echo "=========================================="
echo "Testing HPA for Tenant: ${TENANT_ID}"
echo "=========================================="

# Check if HPA exists
print_info "Checking HPA configuration"
kubectl get hpa -n ${NAMESPACE}

# Get initial replica count
INITIAL_REPLICAS=$(kubectl get deployment ${TENANT_ID}-app-api -n ${NAMESPACE} -o jsonpath='{.spec.replicas}')
print_info "Initial replica count for API service: $INITIAL_REPLICAS"

# Start port-forward for load testing
print_info "Starting port-forward to API service..."
kubectl port-forward -n ${NAMESPACE} svc/${TENANT_ID}-app-api 8002:3002 &>/dev/null &
PF_PID=$!
sleep 3

# Install hey if not available (load testing tool)
if ! command -v hey &> /dev/null; then
    print_info "Installing 'hey' load testing tool..."
    go install github.com/rakyll/hey@latest 2>/dev/null || {
        print_fail "'hey' installation failed. Please install it manually or use 'ab' (Apache Bench)"
        kill $PF_PID 2>/dev/null
        exit 1
    }
fi

# Generate load
print_info "Generating load for ${DURATION} seconds..."
print_info "This will send continuous requests to trigger autoscaling"

hey -z ${DURATION}s -c 50 -q 10 http://localhost:8002/health &>/dev/null &
LOAD_PID=$!

# Monitor HPA and replica count
print_info "Monitoring HPA status (every 10 seconds)..."
for i in $(seq 1 $((DURATION/10))); do
    sleep 10
    echo ""
    print_info "Status at ${i}0 seconds:"
    kubectl get hpa ${TENANT_ID}-app-api-hpa -n ${NAMESPACE}
    CURRENT_REPLICAS=$(kubectl get deployment ${TENANT_ID}-app-api -n ${NAMESPACE} -o jsonpath='{.spec.replicas}')
    print_info "Current replica count: $CURRENT_REPLICAS"
done

# Wait for load test to complete
wait $LOAD_PID 2>/dev/null

# Stop port-forward
kill $PF_PID 2>/dev/null

# Get final replica count
sleep 5
FINAL_REPLICAS=$(kubectl get deployment ${TENANT_ID}-app-api -n ${NAMESPACE} -o jsonpath='{.spec.replicas}')

echo ""
echo "=========================================="
echo "HPA Test Results"
echo "=========================================="
echo "Initial replicas: $INITIAL_REPLICAS"
echo "Final replicas: $FINAL_REPLICAS"

if [ $FINAL_REPLICAS -gt $INITIAL_REPLICAS ]; then
    print_pass "HPA scaled up from $INITIAL_REPLICAS to $FINAL_REPLICAS replicas"
    print_info "HPA is working correctly!"
else
    print_fail "HPA did not scale up (may need more load or time)"
    print_info "Try increasing duration or load"
fi

echo ""
print_info "Final HPA status:"
kubectl get hpa -n ${NAMESPACE}

echo ""
print_info "Note: Pods will scale down after cooldown period (default 5 minutes)"
