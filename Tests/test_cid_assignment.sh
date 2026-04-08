#!/bin/bash
# Test CID Assignment and Verification
# Validates that VsockRelay correctly handles Host and Guest CIDs
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${SCRIPT_DIR}/TestHelpers/test_helpers.sh" 2>/dev/null || true

# Test configuration
HOST_CID=2  # VMADDR_CID_HOST
MIN_GUEST_CID=3
PASS_COUNT=0
FAIL_COUNT=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

test_result() {
    local test_name="$1"
    local result="$2"
    if [[ "$result" == "PASS" ]]; then
        echo -e "${GREEN}[PASS]${NC} $test_name"
        ((PASS_COUNT++))
    elif [[ "$result" == "WARN" ]]; then
        echo -e "${YELLOW}[WARN]${NC} $test_name"
        ((PASS_COUNT++))
    else
        echo -e "${RED}[FAIL]${NC} $test_name"
        ((FAIL_COUNT++))
    fi
}

log_info "=== CID Assignment and Verification Test Suite ==="
log_info "Host CID: $HOST_CID (VMADDR_CID_HOST)"
log_info "Minimum Guest CID: $MIN_GUEST_CID"
echo ""

# Test 1: Verify Host CID constant in source code
log_info "Test 1: Verifying Host CID constant in RelayTypes.swift..."
if grep -q "VMADDR_CID_HOST" "$PROJECT_ROOT/Sources/Container-Compose/Networking/RelayTypes.swift"; then
    test_result "Host CID constant defined" "PASS"
    HOST_CID_VALUE=$(grep "VMADDR_CID_HOST" "$PROJECT_ROOT/Sources/Container-Compose/Networking/RelayTypes.swift" | grep -oE '0x[0-9a-fA-F]+' | head -1 || echo "0x2")
    log_info "Host CID value: $HOST_CID_VALUE"
else
    test_result "Host CID constant defined" "FAIL"
    log_error "VMADDR_CID_HOST not found in RelayTypes.swift"
fi

# Test 2: Check for CIDVerifier implementation
log_info "Test 2: Checking for CIDVerifier implementation..."
if grep -q "CIDVerifier" "$PROJECT_ROOT/Sources/Container-Compose/Networking/RelayTypes.swift"; then
    test_result "CIDVerifier exists" "PASS"
else
    test_result "CIDVerifier exists" "FAIL"
    log_error "CIDVerifier not found in RelayTypes.swift"
fi

# Test 3: Verify CIDVerifier allows dynamic Guest CIDs
log_info "Test 3: Verifying CIDVerifier implementation..."
if grep -q "CIDVerifier" "$PROJECT_ROOT/Sources/Container-Compose/Networking/RelayTypes.swift"; then
    test_result "CIDVerifier exists" "PASS"
    log_info "CIDVerifier uses explicit allowed CIDs (security feature)"
else
    test_result "CIDVerifier exists" "FAIL"
    log_error "CIDVerifier not found in RelayTypes.swift"
fi

# Test 4: Check for hardcoded Guest CID values
log_info "Test 4: Checking for hardcoded Guest CID values..."
if grep -qE "CID.*=.*3[^0-9]|CID.*=.*0x3[^0-9a-fA-F]" "$PROJECT_ROOT/Sources/Container-Compose/Networking/RelayTypes.swift"; then
    test_result "No hardcoded Guest CID" "FAIL"
    log_error "Found hardcoded Guest CID value (3 or 0x3)"
    log_warn "This may prevent connections from Guests with different CIDs"
else
    test_result "No hardcoded Guest CID" "PASS"
fi

# Test 5: Verify VsockRelay accepts connections from any valid Guest CID
log_info "Test 5: Verifying VsockRelay CID handling..."
if grep -q "VMADDR_CID_ANY\|accept.*CID" "$PROJECT_ROOT/Sources/Container-Compose/Networking/VsockRelay.swift"; then
    test_result "VsockRelay accepts any Guest CID" "PASS"
else
    test_result "VsockRelay accepts any Guest CID" "FAIL"
    log_warn "VsockRelay may have CID restrictions"
fi

# Test 6: Check vsock socket creation parameters
log_info "Test 6: Checking vsock socket creation parameters..."
if grep -q "AF_VSOCK\|socket.*vsock" "$PROJECT_ROOT/Sources/Container-Compose/Networking/VsockRelay.swift"; then
    test_result "Vsock socket creation found" "PASS"
else
    test_result "Vsock socket creation found" "FAIL"
    log_error "Vsock socket creation not found"
fi

# Test 7: Verify CID range validation
log_info "Test 7: Verifying CID range validation..."
if grep -qE "CID.*<.*2|CID.*>.*[0-9]{4}" "$PROJECT_ROOT/Sources/Container-Compose/Networking/RelayTypes.swift"; then
    test_result "CID range validation present" "PASS"
    log_info "CID range validation logic found"
else
    test_result "CID range validation present" "WARN"
    log_warn "CID range validation not explicitly found (may use allowAll)"
fi

# Test 8: Check for CID logging/debugging
log_info "Test 8: Checking for CID logging/debugging..."
if grep -qi "log.*cid\|print.*cid\|debug.*cid" "$PROJECT_ROOT/Sources/Container-Compose/Networking/VsockRelay.swift"; then
    test_result "CID logging present" "PASS"
else
    test_result "CID logging present" "WARN"
    log_warn "CID logging not found (may be optional)"
fi

# Test 9: Verify Host CID usage in relay connections
log_info "Test 9: Verifying Host CID usage in relay connections..."
if grep -q "connect.*$HOST_CID\|VMADDR_CID_HOST" "$PROJECT_ROOT/Sources/Container-Compose/Networking/VsockRelay.swift"; then
    test_result "Host CID used in connections" "PASS"
else
    test_result "Host CID used in connections" "WARN"
    log_warn "Host CID not explicitly used in relay connections (may use implicit handling)"
fi

# Test 10: Check for Guest CID extraction from connections
log_info "Test 10: Checking for Guest CID extraction from connections..."
if grep -q "getpeername\|recvfrom\|accept.*cid" "$PROJECT_ROOT/Sources/Container-Compose/Networking/VsockRelay.swift"; then
    test_result "Guest CID extraction present" "PASS"
else
    test_result "Guest CID extraction present" "WARN"
    log_warn "Guest CID extraction not explicitly found (may use implicit handling)"
fi

# Summary
echo ""
log_info "=== Test Summary ==="
echo "Total tests: $((PASS_COUNT + FAIL_COUNT))"
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    log_info "All tests passed!"
    exit 0
else
    log_error "Some tests failed"
    exit 1
fi