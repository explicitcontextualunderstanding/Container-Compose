#!/bin/bash
#==============================================================================
# TDD Test: UDS Deployment Validation (Plan 88 Phase 5)
# Validates production deployment with UDS-over-Virtio-FS
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== UDS Deployment Validation Tests (Plan 88 Phase 5) ==="
echo ""

# Test 1: Prerequisites
echo "Test 1: Prerequisites"
if command -v container-compose &> /dev/null; then
    pass "container-compose binary found"
else
    fail "container-compose not found"
fi

if [[ -d "$HOME/.containers/Volumes" ]]; then
    pass "Production volumes directory exists"
else
    fail "Production volumes directory not found"
fi
echo ""

# Test 2: Virtio-FS volume detection
echo "Test 2: Virtio-FS volume detection"
RELAY_MANAGER="${PROJECT_ROOT}/Sources/Container-Compose/Networking/RelayManager.swift"

if grep -q "\.containers/Volumes" "$RELAY_MANAGER"; then
    pass "Virtio-FS volume detection in RelayManager"
else
    fail "Virtio-FS detection not found"
fi

if grep -q "detectVirtioFSMount\|Virtio-FS\|virtiofs" "$RELAY_MANAGER"; then
    pass "Virtio-FS mount detection logic exists"
else
    fail "Virtio-FS mount detection not found"
fi
echo ""

# Test 3: Socket path configuration
echo "Test 3: Socket path validation"
UDS_RELAY="${PROJECT_ROOT}/Sources/Container-Compose/Networking/UDSVirtioFSRelay.swift"

if grep -q "socketPath.*String" "$UDS_RELAY"; then
    pass "Socket path parameter exists"
else
    fail "Socket path parameter not found"
fi

if grep -q "sunPathMax.*104" "$UDS_RELAY"; then
    pass "104-char limit validation exists"
else
    fail "104-char limit not enforced"
fi
echo ""

# Test 4: createSignalSocket parameter
echo "Test 4: createSignalSocket parameter"
if grep -q "createSignalSocket.*Bool" "$UDS_RELAY"; then
    pass "createSignalSocket parameter exists"
else
    fail "createSignalSocket parameter not found"
fi

if grep -q "if createSignalSocket" "$UDS_RELAY"; then
    pass "createSignalSocket conditional logic exists"
else
    fail "createSignalSocket conditional not found"
fi
echo ""

# Test 5: Production compose file
echo "Test 5: Production compose file validation"
PROD_COMPOSE="${PROJECT_ROOT}/../isaac_ros_custom/.appcontainer/honcho-stack-with-derivers.yml"

if [[ -f "$PROD_COMPOSE" ]]; then
    pass "Production compose file exists"
    
    if grep -q "x-apple-relays" "$PROD_COMPOSE"; then
        pass "x-apple-relays configuration found"
    else
        fail "x-apple-relays not found"
    fi
    
    if grep -q "socket_path" "$PROD_COMPOSE"; then
        pass "socket_path field exists"
    else
        fail "socket_path not found"
    fi
else
    fail "Production compose file not found"
fi
echo ""

# Test 6: Security gates
echo "Test 6: Security gates (Plan 85)"
SEC_MANAGER="${PROJECT_ROOT}/Sources/SecurityHardening/Integration/SecureRelayManager.swift"

if [[ -f "$SEC_MANAGER" ]]; then
    pass "SecureRelayManager exists"
    
    if grep -q "validateRelayStartup" "$SEC_MANAGER"; then
        pass "validateRelayStartup method exists"
    else
        fail "validateRelayStartup not found"
    fi
else
    fail "SecureRelayManager not found"
fi
echo ""

# Summary
echo "=== Summary ==="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi

echo "All deployment validation tests PASSED!"
exit 0
