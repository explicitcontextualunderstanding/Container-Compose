#!/bin/bash
# run-tests.sh - Unified Test Runner for Container-Compose
# Manifest-driven orchestrator with build lock, cleanup, telemetry, and validation.
#
# Usage: ./run-tests.sh [--auto-clean] [test-filter]
#
# Reads tests-manifest.json for target definitions, timeouts, and expected counts.
# Replaces the old split between run-tests.sh and run-tests-full.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MANIFEST="$SCRIPT_DIR/tests-manifest.json"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TIER_LOG="$LOG_DIR/tiered_output_${TIMESTAMP}.txt"

# ============================================================================
# BUILD MUTEX: Prevent concurrent Swift builds using flock
# ============================================================================
BUILD_LOCK_FILE="/tmp/container-compose-test.lock"

acquire_build_lock() {
    if command -v flock &> /dev/null; then
        exec 200>"$BUILD_LOCK_FILE"
        if flock -n 200 2>/dev/null; then
            echo "✓ Build lock acquired"
        else
            echo "🔒 Waiting for another build..."
            flock 200 2>/dev/null || true
            echo "✓ Build lock acquired after wait"
        fi
    elif [ -f "$BUILD_LOCK_FILE" ]; then
        local old_pid=$(cat "$BUILD_LOCK_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "🔒 Another build running (PID: $old_pid) — waiting..."
            while kill -0 "$old_pid" 2>/dev/null; do sleep 1; done
        fi
        echo $$ > "$BUILD_LOCK_FILE"
    else
        echo $$ > "$BUILD_LOCK_FILE"
    fi
}

release_build_lock() {
    exec 200>&- 2>/dev/null || true
    rm -f "$BUILD_LOCK_FILE" 2>/dev/null || true
}

acquire_build_lock
trap release_build_lock EXIT

# ============================================================================
# VICTORIA PROTOCOL: RUN_ID for surgical container tracking
# ============================================================================
RUN_ID="t$$"
export RUN_ID
export CCT_RUN_ID="$RUN_ID"
export TELEMETRY_RUN_ID="$RUN_ID"
export CONTAINER_COMPOSE_SKIP_AMFI="1"

echo "=========================================="
echo "Container-Compose Test Runner"
echo "=========================================="
echo "RUN_ID: $RUN_ID"
echo "Started: $(date)"
echo ""
echo "Log files:"
echo "  Output:   $TIER_LOG"
echo "  Telemetry: $LOG_DIR/resource_usage_${RUN_ID}_${TIMESTAMP}.csv"
echo ""
echo "  tail -f $TIER_LOG"
echo ""

# ============================================================================
# PARSE FLAGS
# ============================================================================
AUTO_CLEAN=false
USER_FILTER=""
for arg in "$@"; do
    case "$arg" in
        --auto-clean) AUTO_CLEAN=true; export AUTO_CLEAN ;;
        --filter=*) USER_FILTER="${arg#--filter=}" ;;
        -*) ;; # ignore unknown flags
        *) USER_FILTER="$arg" ;;
    esac
done

# ============================================================================
# LOAD LIBRARIES & ENVIRONMENT
# ============================================================================
source "$SCRIPT_DIR/scripts/lib/container-cleanup.sh"
source "$SCRIPT_DIR/scripts/lib/test-runner.sh"
source "$SCRIPT_DIR/scripts/env-setup.sh"
setup_test_logging "$SCRIPT_DIR"

# Stale SwiftPM lock cleanup
for lock in ".build/.lock" ".build/index-build/.lock"; do
    if [ -f "$SCRIPT_DIR/$lock" ]; then
        if ! pgrep -x "swift-build" > /dev/null 2>&1 && ! pgrep -x "swift-frontend" > /dev/null 2>&1; then
            rm -f "$SCRIPT_DIR/$lock" 2>/dev/null || true
            echo "✓ Removed stale lock: $lock"
        fi
    fi
done

# Export OCI_REGISTRY_URL
export OCI_REGISTRY_URL

# ============================================================================
# CLEANUP (Victoria Protocol)
# ============================================================================
victoria_cleanup() {
    local exit_code=$?
    echo ""
    echo "=========================================="
    echo "Victoria Protocol: Surgical Cleanup"
    echo "=========================================="
    if [ -f "$SCRIPT_DIR/scripts/cleanup-orchestrator.sh" ]; then
        bash "$SCRIPT_DIR/scripts/cleanup-orchestrator.sh" "$RUN_ID" --graceful
    else
        cleanup_test_containers
    fi
    exit $exit_code
}
trap victoria_cleanup EXIT INT TERM

echo "Pre-flight: Purging orphaned containers..."
aggressive_cleanup_before_tests
echo ""

# ============================================================================
# MANIFEST VALIDATION
# ============================================================================
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Manifest not found: $MANIFEST"
    exit 1
fi

# Print manifest summary
python3 << PYEOF
import json
with open('$MANIFEST') as f:
    m = json.load(f)
print(f"Project: {m['project']}")
print(f"Toolchain: {m.get('toolchain', 'unknown')}")
print(f"Targets: {len(m['targets'])}")
total_expected = sum(t['expected_count'] for t in m['targets'])
print(f"Total expected tests: {total_expected}")
if 'known_issues' in m:
    for ki in m['known_issues']:
        print(f"  Known issue: {ki['id']} — {ki['description']}")
PYEOF
echo ""

# ============================================================================
# TEST PORTS
# ============================================================================
export TEST_PORT_WORDPRESS="${TEST_PORT_WORDPRESS:-18080}"
export TEST_PORT_WEB="${TEST_PORT_WEB:-18081}"
export TEST_PORT_GATEWAY="${TEST_PORT_GATEWAY:-18082}"
export TEST_PORT_API="${TEST_PORT_API:-18083}"
export TEST_PORT_APP="${TEST_PORT_APP:-13000}"
export TEST_PORT_WEB2="${TEST_PORT_WEB2:-18084}"

# ============================================================================
# RESOURCE TELEMETRY
# ============================================================================
RESOURCE_LOG="$LOG_DIR/resource_usage_${RUN_ID}_${TIMESTAMP}.csv"
echo "Resource Telemetry: $RESOURCE_LOG"
echo ""

"$SCRIPT_DIR/scripts/resource-monitor.sh" "$RESOURCE_LOG" &
MONITOR_PID=$!

cleanup_monitor() {
    kill $MONITOR_PID 2>/dev/null || true
    wait $MONITOR_PID 2>/dev/null || true
}

# ============================================================================
# XPC HEALTH CHECK
# ============================================================================
check_xpc_health() {
    echo "=========================================="
    echo "XPC HEALTH CHECK: Apple Container Daemon"
    echo "=========================================="
    if [ -f "$SCRIPT_DIR/.build/debug/Container-Compose" ]; then
        "$SCRIPT_DIR/.build/debug/Container-Compose" xpc-health 2>&1 || true
    else
        echo "⚠️  Built binary not found — skipping XPC health check"
    fi
    echo ""
}
check_xpc_health

# ============================================================================
# GENERATE TARGET LIST FROM MANIFEST
# ============================================================================
TARGETS_FILE=$(mktemp)
python3 << PYEOF > "$TARGETS_FILE"
import json
with open('$MANIFEST') as f:
    m = json.load(f)
for t in m['targets']:
    name = t['name']
    filter_pat = t['filter']
    parallel = str(t.get('parallel', False)).lower()
    expected = t['expected_count']
    requires = str(t.get('requires_containers', False)).lower()
    timeout = t.get('timeout_seconds', 300)
    print(f"{name}|{filter_pat}|{parallel}|{expected}|{requires}|{timeout}")
PYEOF

# ============================================================================
# MANIFEST-DRIVEN TEST EXECUTION
# ============================================================================
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
declare -a FAILED_TARGETS=()
declare -a SKIPPED_TARGETS=()
TEST_EXIT_CODE=0

if [[ -n "$USER_FILTER" ]]; then
    # User filter mode — run single target
    echo "=========================================="
    echo "Running with user filter: $USER_FILTER"
    echo "=========================================="
    stdbuf -oL swift test --no-parallel --filter "$USER_FILTER" 2>&1 | tee -a "$TIER_LOG"
    TEST_EXIT_CODE=${PIPESTATUS[0]}
else
    # Manifest-driven: run each target in priority order
    while IFS='|' read -r name filter parallel expected requires timeout; do
        [[ -z "$name" ]] && continue

        echo ""
        echo "=========================================="
        echo "Target: $name"
        echo "Expected: $expected tests | Timeout: ${timeout}s"
        echo "=========================================="

        # Skip container-dependent targets if OCI_REGISTRY_URL not set
        if [[ "$requires" == "true" ]] && [[ -z "${OCI_REGISTRY_URL:-}" ]]; then
            echo "⚠️  SKIPPED: OCI_REGISTRY_URL not set"
            SKIPPED_TARGETS+=("$name")
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + expected))
            continue
        fi

        # Parallel mode from manifest
        local_parallel_args="--no-parallel"
        if [[ "$parallel" == "true" ]]; then
            local_parallel_args="--parallel --num-workers 2"
        fi

        target_log="$LOG_DIR/${name}_${TIMESTAMP}.log"
        echo "Command: swift test $local_parallel_args --filter \"$filter\""

        # Run with timeout
        swift test $local_parallel_args --filter "$filter" 2>&1 | tee "$target_log" &
        TEST_PID=$!

        elapsed=0
        interval=5
        while kill -0 $TEST_PID 2>/dev/null; do
            if [[ $elapsed -ge $timeout ]]; then
                echo ""
                echo "🚨 TIMEOUT after ${timeout}s — killing process"
                kill -9 $TEST_PID 2>/dev/null || true
                wait $TEST_PID 2>/dev/null || true
                break
            fi
            sleep $interval
            elapsed=$((elapsed + interval))
        done
        wait $TEST_PID 2>/dev/null || true

        # Parse results from log
        if [[ -f "$target_log" ]]; then
            executed=$(grep -E "Executed [0-9]+ tests" "$target_log" | tail -1 | grep -oE "Executed [0-9]+" | grep -oE "[0-9]+" || echo "0")
            failures=$(grep -E "[0-9]+ failures" "$target_log" | tail -1 | grep -oE "[0-9]+ failures" | grep -oE "[0-9]+" || echo "0")
            skipped_line=$(grep -E "[0-9]+ tests skipped" "$target_log" | tail -1 | grep -oE "[0-9]+" | head -1 || echo "0")
            passed=$((executed - failures - skipped_line))

            echo ""
            echo "Executed: $executed | Passed: $passed | Skipped: $skipped_line | Failed: $failures"

            if [[ "$executed" == "0" ]]; then
                echo "🚨 FAIL: 0 tests executed (expected $expected)"
                FAILED_TARGETS+=("$name")
                TOTAL_FAILED=$((TOTAL_FAILED + expected))
                TEST_EXIT_CODE=1
            elif [[ "$failures" != "0" ]]; then
                echo "🚨 FAIL: $failures tests failed"
                FAILED_TARGETS+=("$name")
                TOTAL_FAILED=$((TOTAL_FAILED + failures))
                TEST_EXIT_CODE=1
            else
                echo "✓ PASS: All $executed tests passed"
            fi

            TOTAL_TESTS=$((TOTAL_TESTS + executed))
            TOTAL_PASSED=$((TOTAL_PASSED + passed))
        else
            echo "🚨 FAIL: No log file created"
            FAILED_TARGETS+=("$name")
            TOTAL_FAILED=$((TOTAL_FAILED + expected))
            TEST_EXIT_CODE=1
        fi
    done < "$TARGETS_FILE"
fi

rm -f "$TARGETS_FILE"

# ============================================================================
# COPY LOG & STOP MONITOR
# ============================================================================
cp "$TIER_LOG" "$LOG_DIR/test_output_${TIMESTAMP}.txt"
cleanup_monitor

# ============================================================================
# FINAL SUMMARY
# ============================================================================
echo ""
echo "=========================================="
echo "FINAL SUMMARY"
echo "=========================================="
echo "Total executed: $TOTAL_TESTS"
echo "Passed: $TOTAL_PASSED"
echo "Failed: $TOTAL_FAILED"
echo "Skipped targets: ${#SKIPPED_TARGETS[@]}"

if [[ ${#SKIPPED_TARGETS[@]} -gt 0 ]]; then
    echo ""
    echo "Skipped targets:"
    for t in "${SKIPPED_TARGETS[@]}"; do echo "  - $t"; done
fi

if [[ ${#FAILED_TARGETS[@]} -gt 0 ]]; then
    echo ""
    echo "Failed targets:"
    for t in "${FAILED_TARGETS[@]}"; do echo "  - $t"; done
fi

# Write JSON summary
summary_file="$LOG_DIR/summary_${TIMESTAMP}.json"
cat > "$summary_file" << EOF
{
  "timestamp": "$TIMESTAMP",
  "run_id": "$RUN_ID",
  "total_executed": $TOTAL_TESTS,
  "total_passed": $TOTAL_PASSED,
  "total_failed": $TOTAL_FAILED,
  "skipped_targets": [$(IFS=,; printf '"%s"' "${SKIPPED_TARGETS[*]}")],
  "failed_targets": [$(IFS=,; printf '"%s"' "${FAILED_TARGETS[*]}")],
  "status": "$([ $TOTAL_FAILED -eq 0 ] && echo PASS || echo FAIL)"
}
EOF
echo ""
echo "Summary: $summary_file"

# ============================================================================
# RESOURCE TELEMETRY SUMMARY
# ============================================================================
echo ""
echo "=========================================="
echo "Resource Usage"
echo "=========================================="
if [[ -f "$RESOURCE_LOG" ]] && [[ -s "$RESOURCE_LOG" ]]; then
    min_free=$(tail -n +2 "$RESOURCE_LOG" | cut -d',' -f2 | sort -n | head -1)
    max_free=$(tail -n +2 "$RESOURCE_LOG" | cut -d',' -f2 | sort -n | tail -1)
    avg_free=$(tail -n +2 "$RESOURCE_LOG" | cut -d',' -f2 | awk '{sum+=$1} END {printf "%.0f", sum/NR}')
    critical=$(grep ",2$" "$RESOURCE_LOG" | wc -l | tr -d ' ')
    total=$(tail -n +2 "$RESOURCE_LOG" | wc -l | tr -d ' ')

    echo "Memory (free MB): min=$min_free, max=$max_free, avg=$avg_free"
    echo "Critical pressure samples: $critical / $total"

    if [[ -n "$min_free" ]] && [[ "$min_free" -lt 500 ]]; then
        echo "⚠️  WARNING: Low memory detected — failures may be OOM, not logic bugs"
    fi
    echo "Log: $RESOURCE_LOG"
else
    echo "No telemetry data collected"
fi

# ============================================================================
# PERFORMANCE DASHBOARD
# ============================================================================
if command -v python3 &> /dev/null && [[ -f "$LOG_DIR/test_output_${TIMESTAMP}.txt" ]]; then
    echo ""
    echo "=========================================="
    echo "Performance Dashboard"
    echo "=========================================="
    python3 "$SCRIPT_DIR/scripts/analyze-performance.py" \
        "$LOG_DIR/test_output_${TIMESTAMP}.txt" \
        "$RESOURCE_LOG" \
        --run-id "$RUN_ID" 2>/dev/null || echo "Performance analysis unavailable"
fi

echo ""
echo "Completed: $(date)"
echo "=========================================="

if [[ $TOTAL_FAILED -gt 0 ]]; then
    echo "⚠️  SOME TESTS FAILED ($TOTAL_FAILED)"
    exit 1
else
    echo "✅ ALL $TOTAL_PASSED TESTS PASSED"
    exit 0
fi
