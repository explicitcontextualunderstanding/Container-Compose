#!/bin/bash
# Run Container-Compose tests with proper privilege handling
# Usage: ./run-tests.sh [--auto-clean] [--no-sudo] [test-filter]
#
# CLEANUP STRATEGY:
# 1. PRE-CLEAN: Aggressively remove ALL CCT_* containers and snapshots BEFORE testing
# 2. POST-CLEAN: Remove ALL CCT_* containers and snapshots AFTER testing (via trap)
# 3. This prevents resource exhaustion from accumulated test artifacts

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load library modules
source "$SCRIPT_DIR/scripts/lib/container-cleanup.sh"
source "$SCRIPT_DIR/scripts/lib/test-runner.sh"
source "$SCRIPT_DIR/scripts/env-setup.sh"

# Setup logging (pass SCRIPT_DIR to use project root, not library directory)
setup_test_logging "$SCRIPT_DIR"

# Register cleanup function to run on exit (POST-TEST)
trap cleanup_test_containers EXIT

# Aggressive PRE-TEST cleanup - ALWAYS run before tests
# This ensures a clean state and prevents resource exhaustion
aggressive_cleanup_before_tests

echo "=========================================="
echo "Container-Compose Test Runner"
echo "=========================================="
echo ""

# Neutralize conda environment contamination (shared with build-sign-install.sh)
[ -n "$_ENV_SETUP_SUMMARY" ] && echo " Env: $_ENV_SETUP_SUMMARY"

# Check for stale lock files in temp directory
AUTO_CLEAN=false
for arg in "$@"; do
    if [[ "$arg" == "--auto-clean" ]]; then
        AUTO_CLEAN=true
        break
    fi
done
check_stale_lock_files

# Check for root-owned files in .build if not running as root
check_root_owned_files

# Set configurable test ports to avoid conflicts with existing services
# Override these via environment variables if needed
export TEST_PORT_WORDPRESS="${TEST_PORT_WORDPRESS:-18080}"
export TEST_PORT_WEB="${TEST_PORT_WEB:-18081}"
export TEST_PORT_GATEWAY="${TEST_PORT_GATEWAY:-18082}"
export TEST_PORT_API="${TEST_PORT_API:-18083}"
export TEST_PORT_APP="${TEST_PORT_APP:-13000}"
export TEST_PORT_WEB2="${TEST_PORT_WEB2:-18084}"

echo "Test ports configured:"
echo "  WordPress: $TEST_PORT_WORDPRESS"
echo "  Web/Nginx: $TEST_PORT_WEB"
echo "  API Gateway: $TEST_PORT_GATEWAY"
echo "  API Service: $TEST_PORT_API"
echo "  App/Node.js: $TEST_PORT_APP"
echo "  Web Service 2: $TEST_PORT_WEB2"
echo ""

# Parse --auto-clean flag early (needed before prune step)
AUTO_CLEAN=false
for arg in "$@"; do
    if [[ "$arg" == "--auto-clean" ]]; then
        AUTO_CLEAN=true
        break
    fi
done

# Check if we're in CI
if [ -n "$CI" ] || [ -n "$GITHUB_ACTIONS" ]; then
    echo "✓ Running in CI environment"
    echo "  Tests will run with existing privileges"
    echo ""
    swift test "$@"
    exit $?
fi

# Local development - check container runtime
echo "Local development environment detected"
echo ""

# Check for OCI_REGISTRY_URL (loaded from ops.env by env-setup.sh if available)
if [ -n "$OCI_REGISTRY_URL" ]; then
  echo "✓ OCI_REGISTRY_URL: $OCI_REGISTRY_URL"
  echo ""
fi

# Check if container runtime is available
if ! command -v container &> /dev/null; then
    echo "⚠️  'container' CLI not found in PATH"
    echo " Tests requiring container runtime will fail"
    echo ""
fi

# Check if we can run privileged tests
PRIVILEGED_TESTS=(
    "Test WordPress"
    "Test compose with complex dependency chain"
    "What goes up must come down"
    "Test stopped container"
    "Test container created with non-default"
)

echo "Tests requiring container runtime (privileged):"
for test in "${PRIVILEGED_TESTS[@]}"; do
    echo "  - $test"
done
echo ""

# Parse arguments for flags (filters out --auto-clean and --no-sudo)
# Also handles test filter arguments - validates and adds --filter if needed
FORCE_NO_SUDO=false
FILTERED_ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--no-sudo" ]]; then
    FORCE_NO_SUDO=true
  elif [[ "$arg" == "--auto-clean" ]]; then
    AUTO_CLEAN=true
  elif [[ "$arg" == "--filter" ]]; then
    FILTERED_ARGS+=("$arg") # keep --filter as-is
  elif [[ "$arg" =~ ^[A-Za-z].*Tests?$ ]]; then
    # Argument looks like a test name without --filter, add --filter prefix
    FILTERED_ARGS+=("--filter" "$arg")
  else
    FILTERED_ARGS+=("$arg")
  fi
done

# Check if already running as root/sudo
if [ "$EUID" -eq 0 ]; then
    echo "⚠️  ERROR: Running as root (EUID=0) is NOT supported."
    echo " Apple Container runtime rejects sudo/root access with 'unauthorized request'."
    echo ""
    echo "Please run WITHOUT sudo:"
    echo " ./run-tests.sh"
    echo ""
    exit 1
fi

# Prompt for sudo is disabled - Apple Container rejects root access
echo "NOTE: Apple Container runtime requires non-root user."
echo " Tests will run without sudo."
echo ""
if [ "$FORCE_NO_SUDO" = true ]; then
    echo "Running tests without sudo (requested via --no-sudo)..."
    echo ""
fi

# Run swift tests with parallel execution (optimized for 8GB M2)
# Use 2 workers for container tests to balance memory usage
# Lightweight tests (pgmicro, nginx, redis) can run in parallel
# Heavy tests (wordpress, mysql) use .serialized attribute to prevent parallel execution

export OCI_REGISTRY_URL

# ============================================================================
# RESOURCE TELEMETRY (Industry Best Practice)
# Background monitoring to distinguish logic bugs from OOM/resource exhaustion
# ============================================================================
RESOURCE_LOG="$LOG_DIR/resource_usage_$TIMESTAMP.csv"
echo "=========================================="
echo "Resource Telemetry Enabled"
echo "=========================================="
echo "Monitoring memory and CPU during test run"
echo "Log: $RESOURCE_LOG"
echo ""

# Start resource monitor in background
"$(dirname "$0")/scripts/resource-monitor.sh" "$RESOURCE_LOG" &
MONITOR_PID=$!

# Ensure monitor is stopped when tests complete
cleanup_monitor() {
    if kill -0 $MONITOR_PID 2>/dev/null; then
        kill $MONITOR_PID 2>/dev/null
        wait $MONITOR_PID 2>/dev/null
    fi
}
trap cleanup_monitor EXIT

# Run tests
swift test --parallel --num-workers 2 "${FILTERED_ARGS[@]}" 2>&1 | tee "$LOG_DIR/test_output_$TIMESTAMP.txt"
TEST_EXIT_CODE=${PIPESTATUS[0]}

# Stop resource monitor
cleanup_monitor

# Parse and display test results
parse_test_results "$LOG_DIR/test_output_$TIMESTAMP.txt"

# Resource Analysis Summary
echo ""
echo "=========================================="
echo "Resource Usage Summary"
echo "=========================================="
if [ -f "$RESOURCE_LOG" ] && [ -s "$RESOURCE_LOG" ]; then
    # Calculate stats from log
    MIN_FREE=$(tail -n +2 "$RESOURCE_LOG" | cut -d',' -f2 | sort -n | head -1)
    MAX_CPU=$(tail -n +2 "$RESOURCE_LOG" | cut -d',' -f4 | grep -v "N/A" | sort -n | tail -1)
    AVG_CONTAINERS=$(tail -n +2 "$RESOURCE_LOG" | cut -d',' -f5 | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print 0}')
    
    echo " Minimum Free Memory: ${MIN_FREE:-N/A} MB"
    echo " Peak CPU Usage: ${MAX_CPU:-N/A}%"
    echo " Avg Container Count: $AVG_CONTAINERS"
    echo ""
    
    # OOM Warning Detection
    if [ -n "$MIN_FREE" ] && [ "$MIN_FREE" -lt 500 ]; then
        echo "⚠️  WARNING: Memory pressure detected during tests"
        echo "    Minimum free memory was only ${MIN_FREE}MB"
        echo "    Test failures may be due to memory exhaustion, not logic bugs"
        echo ""
    fi
    
    echo " Full resource log: $RESOURCE_LOG"
else
    echo " Resource monitoring data not available"
fi
echo ""

exit $TEST_EXIT_CODE