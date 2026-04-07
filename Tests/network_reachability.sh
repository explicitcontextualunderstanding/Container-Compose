#!/bin/bash
# network_reachability.sh
# Creates a minimal compose file, validates it, and optionally brings up a test container to ping the socat host IP.
# Usage: network_reachability.sh [--run]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared cleanup library
source "$SCRIPT_DIR/../scripts/lib/container-cleanup.sh"

TMP_COMPOSE=$(mktemp /tmp/apple-container-network-test.XXXXXX.yml)
AC_SNAPSHOTS_DIR="$HOME/Library/Application Support/com.apple.container/snapshots"
SOCAT_IP="192.168.64.1"
RUN=${1:-}

# Cleanup function to remove temp compose file and prune orphaned snapshots
cleanup_network_test() {
    rm -f "$TMP_COMPOSE"
    prune_test_snapshots
}

trap cleanup_network_test EXIT

cat > "$TMP_COMPOSE" <<EOF
name: apple-network-test

services:
  test_ping:
    image: alpine:3.18
    command: ["sleep","300"]
    restart: 'no'
    networks:
      default:
        dns_search:
          - "apple"

networks:
  default: {}
EOF

echo "Wrote test compose to $TMP_COMPOSE"

# Validate compose syntax
if command -v container-compose >/dev/null 2>&1; then
    echo "Validating with container-compose config..."
    container-compose -f "$TMP_COMPOSE" config || { echo "Compose validation failed" >&2; exit 3; }
elif command -v container >/dev/null 2>&1; then
    echo "Validating with 'container compose'..."
    container compose -f "$TMP_COMPOSE" config || { echo "Compose validation failed" >&2; exit 3; }
else
    echo "No container-compose or container CLI found; cannot validate or run test" >&2
    exit 4
fi

echo "Compose validated. To actually run the network reachability test, re-run this script with: $0 --run"

if [[ "$RUN" != "--run" ]]; then
    exit 0
fi

echo ""
echo "Starting network reachability test"
echo "===================================="

# Bring up the test container
if command -v container-compose >/dev/null 2>&1; then
    CMD="container-compose"
elif command -v container >/dev/null 2>&1; then
    CMD="container compose"
else
    echo "No container-compose or container CLI found" >&2
    exit 5
fi

echo "Bringing up test container..."
$CMD -f "$TMP_COMPOSE" up -d || { echo "Failed to bring up container" >&2; exit 6; }

# Wait for container to be running
sleep 2

# Get container name
TEST_CONTAINER=$($CMD -f "$TMP_COMPOSE" ps -q | head -n1)

if [ -z "$TEST_CONTAINER" ]; then
    echo "No container found" >&2
    $CMD -f "$TMP_COMPOSE" down
    exit 7
fi

echo "Container: $TEST_CONTAINER"
echo ""

# Test ping to socat host
echo "Testing network reachability to socat host ($SOCAT_IP)..."
echo ""

# Try to ping the socat host
if $CMD -f "$TMP_COMPOSE" exec "$TEST_CONTAINER" ping -c 3 "$SOCAT_IP" >/dev/null 2>&1; then
    echo "✓ SUCCESS: Container can reach $SOCAT_IP"
    echo ""
    echo "Network is properly configured for Apple Container"
    $CMD -f "$TMP_COMPOSE" down
    exit 0
else
    echo "✗ FAILURE: Container cannot reach $SOCAT_IP"
    echo ""
    echo "This may indicate:"
    echo "  - DNS resolution issues"
    echo "  - Network isolation problems"
    echo "  - Firewall configuration issues"
    echo ""
    $CMD -f "$TMP_COMPOSE" down
    exit 1
fi