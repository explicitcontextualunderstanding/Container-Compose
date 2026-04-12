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
RUN_ID="cct-$(date +%s)-$$"
export RUN_ID
echo "=========================================="
echo "Container-Compose Test Runner"
echo "=========================================="
echo "RUN_ID: $RUN_ID"
echo ""

# Agent overhead check (critical for 8GB M2) - run in background to not block
if [ -f "$SCRIPT_DIR/scripts/check-agent-overhead.sh" ]; then
    echo "=== AGENT OVERHEAD CHECK ==="
    # Run in subshell to avoid blocking main execution
    (
        bash "$SCRIPT_DIR/scripts/check-agent-overhead.sh" &
        CHECK_PID=$!
        sleep 2
        if ps -p $CHECK_PID > /dev/null 2>&1; then
            kill $CHECK_PID 2>/dev/null
            wait $CHECK_PID 2>/dev/null
        fi
    ) 2>/dev/null || true
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
        export AUTO_CLEAN
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
# SPLIT EXECUTION (Parallel-Safe / Serial-Safe)
# Phase 1: Swift Testing + lightweight XCTest → --parallel (fast)
# Phase 2: Network/framework XCTest targets → --no-parallel (no GCD deadlocks)
# ============================================================================

TEST_EXIT_CODE=0
TIER_LOG="$LOG_DIR/tiered_output_$TIMESTAMP.txt"

# Memory gating function - checks if enough memory available
check_memory_for_tier() {
    local tier_name="$1"
    local required_mb="$2"

    # Calculate available memory
    local free_pages spec_pages inactive_pages available_mb
    free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.') || free_pages=0
    spec_pages=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.' 2>/dev/null) || spec_pages=0
    inactive_pages=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.') || inactive_pages=0
    available_mb=$(( (free_pages + spec_pages + inactive_pages) * 16384 / 1024 / 1024 ))

    echo ""
    echo "Memory Check for $tier_name:"
    echo "  Required: ${required_mb}MB"
    echo "  Available: ${available_mb}MB"

    if [ "$available_mb" -lt "$required_mb" ]; then
        echo "  ⚠️  INSUFFICIENT MEMORY - Skipping tier"
        return 1
    fi

    echo "  ✓ Memory OK"
    return 0
}

# Run a test phase with given parallel mode and filter
run_phase() {
    local tier_name="$1"
    local required_mb="$2"
    local parallel_mode="$3"
    local filter="$4"

    if ! check_memory_for_tier "$tier_name" "$required_mb"; then
        echo "  (Skipped due to low memory)"
        return 0
    fi

    echo ""
    echo "=========================================="
    echo "PHASE: $tier_name"
    echo "Mode: $parallel_mode | Filter: $filter"
    echo "=========================================="

    stdbuf -oL swift test $parallel_mode --filter "$filter" "${FILTERED_ARGS[@]}" 2>&1 | tee -a "$TIER_LOG"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -ne 0 ]; then
        echo "⚠️ Phase '$tier_name' had failures (exit: $exit_code)"
    fi

    return $exit_code
}

# Phase 1: Parallel-safe targets (Swift Testing + lightweight XCTest, no GCD state)
# SecurityHardeningTests: all Swift Testing, respects .minMemory/.heavyContainer traits
# Container-Compose-StaticTests: pure XCTest, no network/async
run_phase "Parallel-Safe Targets" 50 \
    "--parallel --num-workers 2" \
    "SecurityHardeningTests|Container-Compose-StaticTests" || TEST_EXIT_CODE=1

# Phase 2: Serial-safe targets (XCTest with Network.framework, async, containers)
# Container-Compose-Tests: has NWConnection, async relay tests, mixed XCTest/Swift Testing
# Container-Compose-DynamicTests: container-dependent, async, WordPress/MySQL
# 
# CONTAINER STATS TELEMETRY: Heavy container tests monitored for actual vs allocated memory
# Prevents over-provisioning waste (e.g., 1024MB allocated, 565MB used = 459MB waste)
run_phase_with_container_telemetry() {
    local tier_name="Heavy Container Tests (with telemetry)"
    local required_mb="200"
    
    if ! check_memory_for_tier "$tier_name" "$required_mb"; then
        echo "  (Skipped due to low memory)"
        return 0
    fi
    
    echo ""
    echo "=========================================="
    echo "PHASE: $tier_name"
    echo "Container Stats: Tracking allocated vs actual usage"
    echo "=========================================="
    
    # Start container stats monitoring for TEST CONTAINERS only (CCT_*)
    local container_stats_log="$LOG_DIR/container_stats_$(date +%Y%m%d_%H%M%S).log"
    echo "timestamp,container_name,allocated_mb,actual_mb,waste_mb,test_phase" > "$container_stats_log"
    
    (
        while true; do
            sleep 2
            # Get container stats for TEST CONTAINERS only (CCT_* prefix)
            if command -v container &> /dev/null; then
                # Only track CCT_ containers created by this test run
                container list --all 2>/dev/null | grep "CCT_" | while read -r container_line; do
                    container_id=$(echo "$container_line" | awk '{print $1}')
                    container_name=$(echo "$container_line" | awk '{print $2}')
                    
                    # Get detailed stats for this test container
                    container stats --no-stream "$container_id" 2>/dev/null | tail -1 | while read -r stats_line; do
                        # Parse memory stats from container stats output
                        # Format: CONTAINER ID  NAME  CPU %  MEM USAGE / LIMIT  MEM %  NET I/O  BLOCK I/O  PIDS
                        mem_usage=$(echo "$stats_line" | awk '{print $7}')
                        mem_limit=$(echo "$stats_line" | awk '{print $9}')
                        
                        # Convert to MB (handles MiB/GiB suffixes)
                        actual_mb=$(echo "$mem_usage" | sed 's/MiB//' | sed 's/GiB/*1024/' | bc -l 2>/dev/null | cut -d. -f1)
                        allocated_mb=$(echo "$mem_limit" | sed 's/MiB//' | sed 's/GiB/*1024/' | bc -l 2>/dev/null | cut -d. -f1)
                        
                        if [ -n "$actual_mb" ] && [ -n "$allocated_mb" ] && [ "$allocated_mb" -gt 0 ]; then
                            waste_mb=$((allocated_mb - actual_mb))
                            echo "$(date +%s),$container_name,$allocated_mb,$actual_mb,$waste_mb,phase2" >> "$container_stats_log"
                        fi
                    done
                done
            fi
        done
    ) &
    local stats_pid=$!
    
    # Run the heavy tests
    stdbuf -oL swift test --no-parallel --filter "Container-Compose-Tests|Container-Compose-DynamicTests" "${FILTERED_ARGS[@]}" 2>&1 | tee -a "$TIER_LOG"
    local exit_code=${PIPESTATUS[0]}
    
    # Stop container stats
    kill $stats_pid 2>/dev/null || true
    
    # Display container stats summary
    echo ""
    echo "--- Container Stats Summary ---"
    if [ -f "$container_stats_log" ] && [ -s "$container_stats_log" ]; then
        echo "Container | Allocated | Actual | Waste"
        echo "----------|-----------|--------|------"
        tail -n +2 "$container_stats_log" | sort -t',' -k2,2 -k1,1n | awk -F',' '
            {
                if (NR==1 || $2!=last) {
                    if (NR>1) printf "%-10s| %7sMB | %6sMB | %6sMB\n", last, max_alloc, max_actual, max_alloc-max_actual
                    last=$2; max_alloc=$3; max_actual=$4
                }
                if ($3>max_alloc) max_alloc=$3
                if ($4>max_actual) max_actual=$4
            }
            END { if (NR>0) printf "%-10s| %7sMB | %6sMB | %6sMB\n", last, max_alloc, max_actual, max_alloc-max_actual }
        '
        echo ""
        echo "Stats log: $container_stats_log"
    fi
    
    return $exit_code
}

run_phase_with_container_telemetry || TEST_EXIT_CODE=1

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