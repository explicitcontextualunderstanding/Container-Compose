#!/bin/bash
# network_reachability.sh
# Creates a minimal compose file, validates it, and optionally brings up a test container to ping the socat host IP.
# Usage: network_reachability.sh [--run]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_COMPOSE="/tmp/apple-container-network-test.yml"
SOCAT_IP="192.168.64.1"
RUN=${1:-}

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

# Run test (destructive: will start and stop a container)
PROJECT_NAME="apple_test_$$"

if command -v container-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(container-compose -f "$TMP_COMPOSE")
else
  COMPOSE_CMD=(container compose -f "$TMP_COMPOSE")
fi

# Start the service
"${COMPOSE_CMD[@]}" up -d
sleep 2

# Find container id/name
# container-compose uses project name; try to list containers and grep
CONTAINER_ID=$(${COMPOSE_CMD[@]/-f/} ps -q test_ping 2>/dev/null || true)
# Fallback: use container ps to find running 'test_ping'
if [[ -z "$CONTAINER_ID" ]]; then
  if command -v container >/dev/null 2>&1; then
    CONTAINER_ID=$(container ps --format '{{.ID}} {{.Names}}' | grep test_ping | awk '{print $1}' || true)
  fi
fi

if [[ -z "$CONTAINER_ID" ]]; then
  echo "Could not determine container id for test_ping; listing containers:" >&2
  ${COMPOSE_CMD[@]} ps
  exit 5
fi

echo "Pinging $SOCAT_IP from container $CONTAINER_ID"

# Exec ping
if command -v container >/dev/null 2>&1; then
  container exec "$CONTAINER_ID" -- ping -c 1 "$SOCAT_IP" && echo "Reachable" || echo "Unreachable"
else
  echo "container CLI not available to exec into container" >&2
fi

# Cleanup
"${COMPOSE_CMD[@]}" down || true

echo "Test complete."
