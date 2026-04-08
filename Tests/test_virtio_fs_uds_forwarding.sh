#!/bin/bash
# Test Virtio-FS UDS Forwarding
# Validates that Unix Domain Sockets created in containers are visible on host via Virtio-FS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/TestHelpers/test_helpers.sh" 2>/dev/null || true

# Test configuration
TEST_SOCKET="/tmp/virtio_fs_test.sock"
TEST_CONTAINER="virtio-fs-test"
TEST_TIMEOUT=30
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
    else
        echo -e "${RED}[FAIL]${NC} $test_name"
        ((FAIL_COUNT++))
    fi
}

cleanup() {
    log_info "Cleaning up test artifacts..."
    container stop "$TEST_CONTAINER" 2>/dev/null || true
    container rm "$TEST_CONTAINER" 2>/dev/null || true
    rm -f "$TEST_SOCKET" 2>/dev/null || true
}

trap cleanup EXIT

log_info "=== Virtio-FS UDS Forwarding Test Suite ==="
log_info "Test socket: $TEST_SOCKET"
log_info "Test container: $TEST_CONTAINER"
echo ""

# Test 1: Create test container with Virtio-FS mount
log_info "Test 1: Creating test container with Virtio-FS mount..."
if container run -d --name "$TEST_CONTAINER" \
    -v /var/run:/var/run \
    --restart unless-stopped \
    alpine:latest \
    sleep 300 > /dev/null 2>&1; then
    test_result "Container creation" "PASS"
else
    test_result "Container creation" "FAIL"
    log_error "Failed to create test container"
    exit 1
fi

# Wait for container to be ready
sleep 2

# Test 2: Create Unix socket in container
log_info "Test 2: Creating Unix socket in container..."
if container exec "$TEST_CONTAINER" sh -c "nc -lU $TEST_SOCKET &" > /dev/null 2>&1; then
    test_result "Socket creation in container" "PASS"
else
    test_result "Socket creation in container" "FAIL"
    log_error "Failed to create socket in container"
    exit 1
fi

# Wait for socket to be created
sleep 2

# Test 3: Verify socket exists in container
log_info "Test 3: Verifying socket exists in container..."
if container exec "$TEST_CONTAINER" test -S "$TEST_SOCKET"; then
    test_result "Socket exists in container" "PASS"
else
    test_result "Socket exists in container" "FAIL"
    log_error "Socket file not found in container"
fi

# Test 4: Check socket file type in container
log_info "Test 4: Checking socket file type in container..."
SOCKET_TYPE=$(container exec "$TEST_CONTAINER" stat -c "%F" "$TEST_SOCKET" 2>/dev/null || echo "unknown")
if [[ "$SOCKET_TYPE" == "socket" ]]; then
    test_result "Socket file type correct" "PASS"
else
    test_result "Socket file type correct" "FAIL"
    log_error "Expected 'socket', got '$SOCKET_TYPE'"
fi

# Test 5: Verify socket permissions in container
log_info "Test 5: Verifying socket permissions in container..."
SOCKET_PERMS=$(container exec "$TEST_CONTAINER" stat -c "%a" "$TEST_SOCKET" 2>/dev/null || echo "000")
if [[ "$SOCKET_PERMS" =~ ^[0-7]{3}$ ]]; then
    test_result "Socket permissions readable" "PASS"
    log_info "Socket permissions: $SOCKET_PERMS"
else
    test_result "Socket permissions readable" "FAIL"
    log_error "Invalid socket permissions: $SOCKET_PERMS"
fi

# Test 6: Test bidirectional communication
log_info "Test 6: Testing bidirectional communication through socket..."
container exec "$TEST_CONTAINER" sh -c "echo 'TEST_MESSAGE' | nc -U $TEST_SOCKET" > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    test_result "Bidirectional communication" "PASS"
else
    test_result "Bidirectional communication" "FAIL"
    log_warn "Bidirectional communication test failed (may be expected for nc -lU)"
fi

# Test 7: Check if socket is visible on host (if Virtio-FS mount exists)
log_info "Test 7: Checking if socket is visible on host via Virtio-FS..."
if [[ -S "$TEST_SOCKET" ]]; then
    test_result "Socket visible on host" "PASS"
    HOST_SOCKET_TYPE=$(stat -c "%F" "$TEST_SOCKET" 2>/dev/null || stat -f "%HT" "$TEST_SOCKET" 2>/dev/null || echo "unknown")
    log_info "Host socket type: $HOST_SOCKET_TYPE"
else
    test_result "Socket visible on host" "FAIL"
    log_warn "Socket not visible on host - Virtio-FS may not be forwarding UDS"
    log_warn "This is expected if /var/run is not mounted via Virtio-FS"
fi

# Test 8: Test socket cleanup
log_info "Test 8: Testing socket cleanup..."
container exec "$TEST_CONTAINER" rm -f "$TEST_SOCKET"
if ! container exec "$TEST_CONTAINER" test -S "$TEST_SOCKET"; then
    test_result "Socket cleanup" "PASS"
else
    test_result "Socket cleanup" "FAIL"
    log_error "Failed to remove socket"
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