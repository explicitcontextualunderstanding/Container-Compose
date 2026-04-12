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

# ============================================================================
# VICTORIA PROTOCOL: Initialize RUN_ID for surgical container tracking
# This enables label-based cleanup that only targets this test session's containers
# ============================================================================
export RUN_ID="cct-$(date +%s)-$$"
echo "=========================================="
echo "Container-Compose Test Runner"
echo "=========================================="
echo "RUN_ID: $RUN_ID"
echo ""

# Agent overhead check (critical for 8GB M2)
if [ -f "$SCRIPT_DIR/scripts/check-agent-overhead.sh" ]; then
    echo "=== AGENT OVERHEAD CHECK ==="
    bash "$SCRIPT_DIR/scripts/check-agent-overhead.sh"
    AGENT_STATUS=$?
    echo ""
    
    case $AGENT_STATUS in
        1)
            echo "⚠️  CRITICAL: Cannot run any tests (insufficient memory)"
            echo "    Close applications or agents to free memory"
            ;;
        2)
            echo "⚠️  LIMITED: Lightweight tests only (<270MB free)"
            ;;
        3)
            echo "ℹ️  MEDIUM: Medium tests available (<450MB free)"
            ;;
        0)
            echo "✅ OK: Heavy tests can run (≥450MB free)"
            ;;
    esac
    echo ""
fi

# Load library modules
source "$SCRIPT_DIR/scripts/lib/container-cleanup.sh"
source "$SCRIPT_DIR/scripts/lib/test-runner.sh"
source "$SCRIPT_DIR/scripts/env-setup.sh"

# Setup logging (pass SCRIPT_DIR to use project root, not library directory)
setup_test_logging "$SCRIPT_DIR"

# ============================================================================
# VICTORIA PROTOCOL: Surgical cleanup function
# Replaces legacy broad cleanup with label-based surgical removal
# ============================================================================
victoria_cleanup() {
    local exit_code=$?
    echo ""
    echo "=========================================="
    echo "VICTORIA PROTOCOL: Surgical Cleanup"
    echo "=========================================="

    if [ -f "$SCRIPT_DIR/scripts/cleanup-orchestrator.sh" ]; then
        echo "Executing surgical cleanup for RUN_ID: $RUN_ID"
        bash "$SCRIPT_DIR/scripts/cleanup-orchestrator.sh" "$RUN_ID" --graceful
    else
        echo "Cleanup orchestrator not found, falling back to legacy cleanup"
        cleanup_test_containers
    fi

    echo "=========================================="
    exit $exit_code
}

# Register Victoria Protocol cleanup function to run on exit
trap victoria_cleanup EXIT

# Also ensure SIGINT triggers graceful cleanup
trap 'echo ""; echo "[Victoria Protocol] SIGINT received, triggering graceful cleanup..."; victoria_cleanup' INT

# Aggressive PRE-TEST cleanup - purge any orphaned containers from previous crashed sessions
# This uses legacy cleanup for cross-session orphans, then Victoria Protocol for this session
echo "Pre-flight: Purging orphaned containers from previous sessions..."
aggressive_cleanup_before_tests
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
echo " WordPress: $TEST_PORT_WORDPRESS"
echo " Web/Nginx: $TEST_PORT_WEB"
echo " API Gateway: $TEST_PORT_GATEWAY"
echo " API Service: $TEST_PORT_API"
echo " App/Node.js: $TEST_PORT_APP"
echo " Web Service 2: $TEST_PORT_WEB2"
echo ""

# ============================================================================
# VICTORIA PROTOCOL: Export RUN_ID for Swift ResourceArbiter
# This enables signal-handled graceful cleanup and label-based container tracking
# ============================================================================
export CCT_RUN_ID="$RUN_ID"
export TELEMETRY_RUN_ID="$RUN_ID"
echo "Victoria Protocol: RUN_ID exported to Swift environment"
echo "  CCT_RUN_ID=$CCT_RUN_ID"
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
# Log file includes RUN_ID for Victoria Protocol traceability
# ============================================================================
RESOURCE_LOG="$LOG_DIR/resource_usage_${RUN_ID}_$TIMESTAMP.csv"
echo "=========================================="
echo "Resource Telemetry Enabled"
echo "=========================================="
echo "Monitoring memory and CPU during test run"
echo "Log: $RESOURCE_LOG"
echo "RUN_ID: $RUN_ID"
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

# ============================================================================
# TIERED TEST EXECUTION (Memory-Weighted)
# Runs lightweight tests first, heavy container tests last
# Ensures WordPress/MySQL (heaviest) run when memory is most stable
# ============================================================================

TEST_EXIT_CODE=0
TIER_LOG="$LOG_DIR/tiered_output_$TIMESTAMP.txt"

# Function to run a test tier
run_test_tier() {
    local tier_name="$1"
    local filter="$2"
    shift 2
    local extra_args=("$@")
    
    echo ""
    echo "=========================================="
    echo "TIER: $tier_name"
    echo "=========================================="
    
    swift test --parallel --num-workers 2 --filter "$filter" "${extra_args[@]}" "${FILTERED_ARGS[@]}" 2>&1 | tee -a "$TIER_LOG"
    local exit_code=${PIPESTATUS[0]}
    
    if [ $exit_code -ne 0 ]; then
        echo "⚠️ Tier '$tier_name' had failures (exit: $exit_code)"
    fi
    
    return $exit_code
}

# Tier 1: Ultra-lightweight (static tests) - ~50MB
run_test_tier "1-Static" "Container-Compose-StaticTests" || TEST_EXIT_CODE=1

# Tier 2: Security tests (no containers) - ~100MB  
run_test_tier "2-Security" "SecurityHardeningTests" || TEST_EXIT_CODE=1

# Tier 3: Dynamic tests excluding heavy containers - ~200MB
run_test_tier "3-Dynamic-Medium" "Container-Compose-DynamicTests" "--skip" "ComposeUpTests" "--skip" "ComposeDownTests" || TEST_EXIT_CODE=1

# Tier 4: Heavy container tests (run last when memory is freest) - ~400MB
run_test_tier "4-Heavy" "ComposeDownTests" || TEST_EXIT_CODE=1

# Tier 5: Critical (WordPress + MySQL) - ~800MB, run absolute last
run_test_tier "5-Critical-WordPress" "ComposeUpTests" || TEST_EXIT_CODE=1

cp "$TIER_LOG" "$LOG_DIR/test_output_$TIMESTAMP.txt"

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

# ============================================================================
# PERFORMANCE DASHBOARD (Sustainability Scorecard)
# Generates human-readable analysis of test performance and resource usage
# ============================================================================
if command -v python3 &> /dev/null; then
  echo "=========================================="
  echo "Generating Performance Dashboard..."
  echo "=========================================="
  echo ""
  
  # Run performance analyzer
  TEST_LOG="$LOG_DIR/test_output_$TIMESTAMP.txt"
  BASELINE="$SCRIPT_DIR/scripts/baseline.json"
  
    if [ -f "$TEST_LOG" ]; then
        # VICTORIA PROTOCOL: Pass RUN_ID for traceability
        python3 "$SCRIPT_DIR/scripts/analyze-performance.py" \
            "$TEST_LOG" \
            "$RESOURCE_LOG" \
            --baseline "$BASELINE" \
            --run-id "$RUN_ID" 2>/dev/null || \
            python3 "$SCRIPT_DIR/scripts/analyze-performance.py" \
            "$TEST_LOG" \
            "$RESOURCE_LOG" \
            --run-id "$RUN_ID" 2>/dev/null || \
            echo "Performance analysis unavailable (Python script error)"
    else
        echo "Performance analysis unavailable (test log not found)"
    fi
  echo ""
fi

exit $TEST_EXIT_CODE