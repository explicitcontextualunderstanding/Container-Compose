#!/bin/bash
# Master Test Runner for Vsock Native Relay Finalization
# Runs all validation tests and generates comprehensive report
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${SCRIPT_DIR}/TestReports"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="${REPORT_DIR}/vsock_relay_test_report_${TIMESTAMP}.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Create report directory
mkdir -p "$REPORT_DIR"

# Initialize report
cat > "$REPORT_FILE" << EOF
Vsock Native Relay Finalization - Test Report
Generated: $(date)
Plan: 84-vsock-native-relay-finalization
Version: 1.3.0

EOF

# Function to run test and capture output
run_test() {
    local test_name="$1"
    local test_script="$2"
    
    log_header "Running: $test_name"
    echo "" | tee -a "$REPORT_FILE"
    echo "## $test_name" | tee -a "$REPORT_FILE"
    echo "Script: $test_script" | tee -a "$REPORT_FILE"
    echo "Started: $(date)" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    
    if [[ -x "$test_script" ]]; then
        if "$test_script" 2>&1 | tee -a "$REPORT_FILE"; then
            local result="PASS"
            echo "" | tee -a "$REPORT_FILE"
            echo "Result: PASS" | tee -a "$REPORT_FILE"
            echo "" | tee -a "$REPORT_FILE"
            log_info "$test_name: PASSED"
            return 0
        else
            local result="FAIL"
            echo "" | tee -a "$REPORT_FILE"
            echo "Result: FAIL" | tee -a "$REPORT_FILE"
            echo "" | tee -a "$REPORT_FILE"
            log_error "$test_name: FAILED"
            return 1
        fi
    else
        log_error "Test script not executable: $test_script"
        echo "ERROR: Test script not executable" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        return 1
    fi
}

# Main execution
log_header "Vsock Native Relay Finalization - Test Suite"
echo "" | tee -a "$REPORT_FILE"
echo "Test Suite: Vsock Native Relay Finalization" | tee -a "$REPORT_FILE"
echo "Plan ID: 84" | tee -a "$REPORT_FILE"
echo "Workspace: $(pwd)" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

# Track overall results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Test 1: Virtio-FS UDS Forwarding
if run_test "Virtio-FS UDS Forwarding Test" "${SCRIPT_DIR}/test_virtio_fs_uds_forwarding.sh"; then
    ((PASSED_TESTS++))
else
    ((FAILED_TESTS++))
fi
((TOTAL_TESTS++))

# Test 2: CID Assignment and Verification
if run_test "CID Assignment and Verification Test" "${SCRIPT_DIR}/test_cid_assignment.sh"; then
    ((PASSED_TESTS++))
else
    ((FAILED_TESTS++))
fi
((TOTAL_TESTS++))

# Test 3: Vsock Relay Integration
if run_test "Vsock Relay Integration Test" "${SCRIPT_DIR}/test_vsock_relay_integration.sh"; then
    ((PASSED_TESTS++))
else
    ((FAILED_TESTS++))
fi
((TOTAL_TESTS++))

# Test 4: Vsock Relay Performance
if run_test "Vsock Relay Performance Benchmark" "${SCRIPT_DIR}/test_vsock_relay_performance.sh"; then
    ((PASSED_TESTS++))
else
    ((FAILED_TESTS++))
fi
((TOTAL_TESTS++))

# Generate summary
log_header "Test Suite Summary"
echo "" | tee -a "$REPORT_FILE"
echo "## Summary" | tee -a "$REPORT_FILE"
echo "Total Tests: $TOTAL_TESTS" | tee -a "$REPORT_FILE"
echo "Passed: $PASSED_TESTS" | tee -a "$REPORT_FILE"
echo "Failed: $FAILED_TESTS" | tee -a "$REPORT_FILE"
echo "Pass Rate: $(awk "BEGIN {printf \"%.1f\", ($PASSED_TESTS/$TOTAL_TESTS)*100}")%" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

if [[ $FAILED_TESTS -eq 0 ]]; then
    echo "Overall Result: PASS" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    log_info "All tests passed!"
    log_info "Report saved to: $REPORT_FILE"
    exit 0
else
    echo "Overall Result: FAIL" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    log_error "Some tests failed"
    log_info "Report saved to: $REPORT_FILE"
    exit 1
fi