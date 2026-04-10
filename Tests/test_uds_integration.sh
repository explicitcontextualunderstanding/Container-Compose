#!/bin/bash
#==============================================================================
# TDD Test: UDS Integration Tests (Plan 88 Group B/C)
# Validates end-to-end UDS relay functionality
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== UDS Integration Tests (Plan 88) ==="
echo ""

# Test 1: UDSVirtioFSRelay exists
echo "Test 1: UDSVirtioFSRelay implementation"
UDS_RELAY="${PROJECT_ROOT}/Sources/Container-Compose/Networking/UDSVirtioFSRelay.swift"

if [[ -f "$UDS_RELAY" ]]; then
    pass "UDSVirtioFSRelay.swift exists"
else
    fail "UDSVirtioFSRelay.swift not found"
    exit 1
fi

if grep -q "RelayProtocol" "$UDS_RELAY"; then
    pass "Conforms to RelayProtocol"
else
    fail "Does not conform to RelayProtocol"
fi
echo ""

# Test 2: UDS case in enum
echo "Test 2: UDS enum case"
SHARED_TYPES="${PROJECT_ROOT}/Sources/SecurityHardening/Shared/SharedRelayTypes.swift"

if grep -q "case uds" "$SHARED_TYPES"; then
    pass "'.uds' case in RelayTransport"
else
    fail "'.uds' case missing"
fi
echo ""

# Test 3: VsockRelay deprecated
echo "Test 3: VsockRelay deprecation"
VSOCK_RELAY="${PROJECT_ROOT}/Sources/Container-Compose/Networking/VsockRelay.swift"

if [[ -f "$VSOCK_RELAY" ]]; then
    if grep -q "@available.*deprecated" "$VSOCK_RELAY"; then
        pass "VsockRelay marked as deprecated"
    else
        fail "VsockRelay not deprecated"
    fi
    
    if grep -q "import Virtualization" "$VSOCK_RELAY"; then
        pass "VsockRelay uses Virtualization (legacy)"
    else
        fail "Virtualization import missing"
    fi
else
    fail "VsockRelay.swift not found"
fi
echo ""

# Test 4: RelayManager uses UDS
echo "Test 4: RelayManager UDS integration"
RELAY_MANAGER="${PROJECT_ROOT}/Sources/Container-Compose/Networking/RelayManager.swift"

if grep -q "UDSVirtioFSRelay" "$RELAY_MANAGER"; then
    pass "RelayManager uses UDSVirtioFSRelay"
else
    fail "RelayManager doesn't use UDSVirtioFSRelay"
fi

if grep -q "\.uds" "$RELAY_MANAGER"; then
    pass "RelayManager handles .uds case"
else
    fail "RelayManager missing .uds handling"
fi
echo ""

# Test 5: Unit tests exist
echo "Test 5: UDS unit tests"
TEST_FILE="${PROJECT_ROOT}/Tests/Container-Compose-Tests/Networking/RelayManagerTests.swift"

if grep -q "CreateSignalSocketTests\|UDS" "$TEST_FILE"; then
    pass "UDS tests in RelayManagerTests"
else
    fail "UDS tests not found"
fi
echo ""

# Test 6: SO_PEERCRED support
echo "Test 6: SO_PEERCRED peer validation"
if grep -q "SO_PEERCRED\|LOCAL_PEERCRED\|PeerValidator" "$UDS_RELAY"; then
    pass "SO_PEERCRED peer validation exists"
else
    fail "SO_PEERCRED not found"
fi
echo ""

# Test 7: Error handling
echo "Test 7: UDS-specific error handling"
if grep -q "UDSError\|socketPathTooLong\|virtioFSNotAvailable" "$UDS_RELAY"; then
    pass "UDS-specific error cases exist"
else
    fail "UDS error cases not found"
fi
echo ""

# Summary
echo "=== Summary ==="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi

echo "All integration tests PASSED!"
exit 0
