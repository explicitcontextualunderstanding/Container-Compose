#!/bin/bash
# Test Socket Path Implementation for vsock-db relay
# Validates Plan 84 Phase 3-4 implementation changes

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASSED=0
FAILED=0

log_pass() { echo "[PASS] $1"; PASSED=$((PASSED + 1)); }
log_fail() { echo "[FAIL] $1"; FAILED=$((FAILED + 1)); }
log_info() { echo "[INFO] $1"; }

echo "=== Socket Path Implementation Validation ==="
echo ""

# Test 1: Build compiles successfully
log_info "Test 1: Building Container-Compose..."
if cd "$PROJECT_ROOT" && swift build >/dev/null 2>&1; then
    log_pass "Swift build successful"
else
    log_fail "Swift build failed"
    exit 1
fi

# Test 2: socket_path field exists in AppleRelayConfig
log_info "Test 2: Checking socket_path field in AppleRelayConfig..."
if grep -q "socket_path.*String" "$PROJECT_ROOT/Sources/Container-Compose/Codable Structs/Service.swift"; then
    log_pass "socket_path field exists in AppleRelayConfig"
else
    log_fail "socket_path field not found in AppleRelayConfig"
fi

# Test 3: VsockRelay has createSignalSocket parameter
log_info "Test 3: Checking createSignalSocket parameter in VsockRelay..."
if grep -q "createSignalSocket.*Bool" "$PROJECT_ROOT/Sources/Container-Compose/Networking/VsockRelay.swift"; then
    log_pass "createSignalSocket parameter exists in VsockRelay"
else
    log_fail "createSignalSocket parameter not found in VsockRelay"
fi

# Test 4: RelayManager detects Virtio-FS volume paths
log_info "Test 4: Checking Virtio-FS volume detection in RelayManager..."
if grep -q "\.containers/Volumes" "$PROJECT_ROOT/Sources/Container-Compose/Networking/RelayManager.swift"; then
    log_pass "Virtio-FS volume detection exists in RelayManager"
else
    log_fail "Virtio-FS volume detection not found in RelayManager"
fi

# Test 5: Transport type preserved in startDeclarativeRelay
log_info "Test 5: Checking transport type preservation in ComposeUp..."
if grep -q "transport = .vsock" "$PROJECT_ROOT/Sources/Container-Compose/Commands/ComposeUp.swift" && \
   grep -q "transport: transport" "$PROJECT_ROOT/Sources/Container-Compose/Commands/ComposeUp.swift"; then
    log_pass "Transport type preservation exists in startDeclarativeRelay"
else
    log_fail "Transport type preservation not found in startDeclarativeRelay"
fi

# Test 6: socket_path in YAML configuration
log_info "Test 6: Checking socket_path in YAML configuration..."
if grep -q "socket_path:.*Volumes" "$PROJECT_ROOT/../isaac_ros_custom/.appcontainer/honcho-stack-with-derivers.yml"; then
    log_pass "socket_path configured in YAML"
else
    log_fail "socket_path not found in YAML"
fi

# Test 7: createSignalSocket controls socket creation
log_info "Test 7: Checking createSignalSocket conditional logic..."
if grep -q "if createSignalSocket" "$PROJECT_ROOT/Sources/Container-Compose/Networking/VsockRelay.swift"; then
    log_pass "createSignalSocket conditional logic exists"
else
    log_fail "createSignalSocket conditional logic not found"
fi

# Test 8: VsockRelay passes createSignalSocket to createUnixSocketListener
log_info "Test 8: Checking createSignalSocket usage in start()..."
if grep -A2 "if createSignalSocket" "$PROJECT_ROOT/Sources/Container-Compose/Networking/VsockRelay.swift" | grep -q "createUnixSocketListener"; then
    log_pass "createSignalSocket correctly gates socket creation"
else
    log_fail "createSignalSocket gating not found"
fi

echo ""
echo "=== Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo "All validation tests passed!"
    exit 0
else
    echo "Some validation tests failed!"
    exit 1
fi