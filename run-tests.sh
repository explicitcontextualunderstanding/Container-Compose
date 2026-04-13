#!/bin/bash
# Run Container-Compose tests with proper privilege handling
# Usage: ./run-tests.sh [--auto-clean] [--no-sudo] [test-filter]
#
# CLEANUP STRATEGY:
# 1. PRE-CLEAN: Aggressively remove ALL CCT_* containers and snapshots BEFORE testing
# 2. POST-CLEAN: Remove ALL CCT_* containers and snapshots AFTER testing (via trap)
# 3. This prevents resource exhaustion from accumulated test artifacts

# Note: set -e removed to allow Phase 2 to run even if Phase 1 has failures
# Error handling is done via TEST_EXIT_CODE tracking
# set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ============================================================================
# BUILD MUTEX: Prevent concurrent Swift builds using flock
# Multiple simultaneous swift builds corrupt the .build cache
# ============================================================================
BUILD_LOCK_FILE="/tmp/container-compose-test.lock"

acquire_build_lock() {
    local lock_fd
    # Try to acquire exclusive lock (non-blocking)
    if ! exec 200>"$BUILD_LOCK_FILE" 2>/dev/null; then
        echo "⚠️  Cannot create lock file: $BUILD_LOCK_FILE"
        return 0  # Continue without lock
    fi

    # Try flock (may not be available on all systems)
    if command -v flock &> /dev/null; then
        if flock -n 200 2>/dev/null; then
            echo "✓ Build lock acquired (flock)"
            return 0
        else
            echo "🔒 Waiting for another build to complete..."
            flock 200 2>/dev/null || true
            echo "✓ Build lock acquired after wait"
            return 0
        fi
    fi

    # Fallback: PID-based lock if flock not available
    if [ -f "$BUILD_LOCK_FILE" ]; then
        local old_pid=$(cat "$BUILD_LOCK_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "🔒 Another test run is building (PID: $old_pid)"
            echo "   Waiting..."
            while kill -0 "$old_pid" 2>/dev/null; do
                sleep 1
            done
            echo "✓ Other build completed"
        fi
    fi
    echo $$ > "$BUILD_LOCK_FILE"
    echo "✓ Build lock acquired (PID-based)"
}

release_build_lock() {
    exec 200>&- 2>/dev/null || true
    rm -f "$BUILD_LOCK_FILE" 2>/dev/null || true
}

# Acquire lock at script start
acquire_build_lock

# Ensure lock is released on exit
trap 'release_build_lock' EXIT

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

# SwiftPM Lock Cleanup - prevent "Planning build" hangs
echo "Pre-flight: Checking for stale SwiftPM build locks..."
SWIFT_BUILD_LOCKS=(".build/.lock" ".build/index-build/.lock")
STALE_LOCKS=0
for lock in "${SWIFT_BUILD_LOCKS[@]}"; do
    if [ -f "$SCRIPT_DIR/$lock" ]; then
        echo "  Found: $lock"
        # Check if any swift-build process is running
        if ! pgrep -x "swift-build" > /dev/null 2>&1 && ! pgrep -x "swift-frontend" > /dev/null 2>&1; then
            echo "  No swift processes running - removing stale lock"
            rm -f "$SCRIPT_DIR/$lock" 2>/dev/null || true
            STALE_LOCKS=$((STALE_LOCKS + 1))
        else
            echo "  ⚠️ Swift build appears to be running - leaving lock in place"
        fi
    fi
done
if [ "$STALE_LOCKS" -gt 0 ]; then
    echo "✓ Removed $STALE_LOCKS stale SwiftPM lock(s)"
else
    echo "✓ No stale SwiftPM locks found"
fi
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
USER_FILTER=""  # Track if user provided a specific filter
for arg in "$@"; do
    if [[ "$arg" == "--no-sudo" ]]; then
        FORCE_NO_SUDO=true
    elif [[ "$arg" == "--auto-clean" ]]; then
        AUTO_CLEAN=true
    elif [[ "$arg" == "--filter" ]]; then
        FILTERED_ARGS+=("$arg")  # keep --filter as-is
    elif [[ "$arg" =~ ^[A-Za-z].*Tests?$ || "$arg" =~ ^test[A-Z] ]]; then
        # Argument looks like a test name without --filter, add --filter prefix
        FILTERED_ARGS+=("--filter" "$arg")
        USER_FILTER="$arg"  # Remember user wants specific tests
    else
        FILTERED_ARGS+=("$arg")
    fi
done

# If user provided a filter, run only that filter (skip phase logic)
if [[ -n "$USER_FILTER" ]]; then
    echo "User filter detected: $USER_FILTER"
    echo "Running with user filter only (skipping phase filters)"
fi

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
# Uses memory_pressure for accurate available memory (not misleading 'free')
check_memory_for_tier() {
    local tier_name="$1"
    local required_mb="$2"

    # Get available memory percentage from memory_pressure
    local pressure_output=$(memory_pressure -Q 2>/dev/null)
    local available_mb
    local pressure_level="unknown"

    if echo "$pressure_output" | grep -q "percent free"; then
        # Parse percent free from memory_pressure
        local percent_free=$(echo "$pressure_output" | grep -oE "[0-9]+\.?[0-9]* percent free" | grep -oE "[0-9]+\.?[0-9]*" | head -1)
        local total_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}')
        available_mb=$(echo "scale=0; $total_mb * $percent_free / 100" | bc 2>/dev/null || echo "0")

        # Determine pressure level
        if [ "${percent_free%.*}" -gt 85 ]; then
            pressure_level="GREEN"
        elif [ "${percent_free%.*}" -gt 50 ]; then
            pressure_level="YELLOW"
        else
            pressure_level="RED"
        fi
    else
        # Fallback to vm_stat with all reclaimable pages
        local free_pages spec_pages inactive_pages purgeable_pages compressed_pages
        free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.') || free_pages=0
        spec_pages=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.' 2>/dev/null) || spec_pages=0
        inactive_pages=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.') || inactive_pages=0
        purgeable_pages=$(vm_stat | grep "Pages purgeable" | awk '{print $3}' | tr -d '.' 2>/dev/null) || purgeable_pages=0
        compressed_pages=$(vm_stat | grep "Pages occupied by compressor" | awk '{print $5}' | tr -d '.' 2>/dev/null) || compressed_pages=0
        available_mb=$(( (free_pages + spec_pages + inactive_pages + purgeable_pages + compressed_pages) * 16384 / 1024 / 1024 ))
    fi

    echo ""
    echo "Memory Check for $tier_name:"
    echo " Required: ${required_mb}MB"
    echo " Available: ${available_mb}MB (Pressure: $pressure_level)"

    # Only skip at critical levels (< 500MB available + high pressure)
    if [ "$available_mb" -lt 500 ] && [ "$pressure_level" = "RED" ]; then
        echo " 🛑 CRITICAL MEMORY - Skipping tier (RED pressure + < 500MB)"
        return 1
    fi

    # Warn if tight but still run
    if [ "$available_mb" -lt "$required_mb" ]; then
        echo " 🟡 MEMORY TIGHT - Running anyway (\$available_mb MB < \$required_mb MB estimated)"
        return 0
    fi

    echo " 🟢 Memory OK"
    return 0
}

# Run a test phase with given parallel mode and filter
run_phase() {
    local tier_name="$1"
    local required_mb="$2"
    local parallel_mode="$3"
    local filter="$4"

    if ! check_memory_for_tier "$tier_name" "$required_mb"; then
        echo " (Skipped due to low memory)"
        return 0
    fi

    # If user provided a filter, skip phase filters and use user's filter only
    if [[ -n "$USER_FILTER" ]]; then
        echo "User filter: $USER_FILTER — skipping phase '$tier_name'"
        return 0
    fi

    echo ""
    echo "=========================================="
    echo "PHASE: $tier_name"
    echo "Mode: $parallel_mode | Filter: $filter"
    echo "=========================================="

    stdbuf -oL swift test $parallel_mode --filter "$filter" 2>&1 | tee -a "$TIER_LOG"
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
    "SecurityHardeningTests|Container_Compose_StaticTests" || TEST_EXIT_CODE=1

# Phase 2: Serial-safe targets (XCTest with Network.framework, async, containers)
# Container-Compose-Tests: has NWConnection, async relay tests, mixed XCTest/Swift Testing
# Container-Compose-DynamicTests: container-dependent, async, WordPress/MySQL
#
# CONTAINER STATS TELEMETRY: Uses Python-based telemetry for accurate CCT_* container stats
# Prevents over-provisioning waste (e.g., 1024MB allocated, 565MB used = 459MB waste)
run_phase_with_container_telemetry() {
    local tier_name="Heavy Container Tests (with telemetry)"
    local required_mb="200"

    if ! check_memory_for_tier "$tier_name" "$required_mb"; then
        echo " (Skipped due to low memory)"
        return 0
    fi

    echo ""
    echo "=========================================="
    echo "PHASE: $tier_name"
    echo "Container Stats: Using accurate telemetry collector"
    echo "=========================================="

    # Start the new Python-based telemetry collector
    local telemetry_log="$LOG_DIR/container_telemetry_$(date +%Y%m%d_%H%M%S).csv"
    if [ -f "$SCRIPT_DIR/scripts/container-stats-telemetry.sh" ]; then
        echo "[Telemetry] Starting Python-based collector..."
        "$SCRIPT_DIR/scripts/container-stats-telemetry.sh" --output "$telemetry_log" --interval 1 &
        local stats_pid=$!
        echo "[Telemetry] Collector PID: $stats_pid"
    else
        echo "[Telemetry] Warning: container-stats-telemetry.sh not found, skipping telemetry"
    fi

    # Run the heavy tests
    # If user provided a filter, use it directly. Otherwise run DynamicTests explicitly
    if [[ -n "$USER_FILTER" ]]; then
        echo "[Telemetry] Running with user filter: $USER_FILTER"
        stdbuf -oL swift test --no-parallel --filter "$USER_FILTER" 2>&1 | tee -a "$TIER_LOG"
    else
        # Run Container_Compose_DynamicTests and Container_Compose_Tests explicitly
        # (Phase 1 already ran SecurityHardeningTests|Container_Compose_StaticTests)
        echo "[Telemetry] Running dynamic tests..."
        stdbuf -oL swift test --no-parallel \
            --filter "Container_Compose_DynamicTests|Container_Compose_Tests" 2>&1 | tee -a "$TIER_LOG"
    fi
    local exit_code=${PIPESTATUS[0]}

    # Stop container stats
    if [ -n "${stats_pid:-}" ]; then
        kill $stats_pid 2>/dev/null || true
        wait $stats_pid 2>/dev/null || true
    fi

    # Display container stats summary using Python analysis
    echo ""
    echo "--- Container Stats Summary ---"
    if [ -f "$telemetry_log" ] && [ -s "$telemetry_log" ]; then
        # Check if file has data beyond header
        local line_count=$(wc -l < "$telemetry_log")
        if [ "$line_count" -gt 1 ]; then
            python3 << PYTHON
import csv
from collections import defaultdict

stats = defaultdict(lambda: {'limit': 0, 'peak': 0, 'samples': 0})

try:
    with open('$telemetry_log', 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row.get('container_name', 'unknown')
            try:
                limit = float(row.get('memory_limit_mb', 0))
                usage = float(row.get('memory_usage_mb', 0))
            except:
                continue
            stats[name]['limit'] = max(stats[name]['limit'], limit)
            stats[name]['peak'] = max(stats[name]['peak'], usage)
            stats[name]['samples'] += 1

    print("")
    print(f"{'Container':<35} {'Limit(MB)':>10} {'Peak(MB)':>10} {'Waste(MB)':>10} {'Waste%':>8}")
    print("─" * 75)

    total_limit = 0
    total_peak = 0

    for name, data in sorted(stats.items(), key=lambda x: x[1]['peak'], reverse=True):
        limit = data['limit']
        peak = data['peak']
        waste = limit - peak
        waste_pct = (waste / limit * 100) if limit > 0 else 0
        indicator = '🚨' if waste_pct > 50 else '⚠️' if waste_pct > 25 else '✅'
        print(f"{name[:35]:<35} {limit:>10.1f} {peak:>10.1f} {waste:>10.1f} {waste_pct:>7.1f}% {indicator}")
        total_limit += limit
        total_peak += peak

    print("─" * 75)
    total_waste = total_limit - total_peak
    waste_pct = (total_waste / total_limit * 100) if total_limit > 0 else 0
    print(f"{'TOTAL':<35} {total_limit:>10.1f} {total_peak:>10.1f} {total_waste:>10.1f} {waste_pct:>7.1f}%")
    print("")
    print(f"Containers tracked: {len(stats)}")
    print(f"Telemetry file: $telemetry_log")
except Exception as e:
    print(f"Error analyzing telemetry: {e}")
PYTHON
        else
            echo "[Telemetry] No data collected (CCT_ containers may not have been running)"
        fi
    else
        echo "[Telemetry] No telemetry file generated"
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