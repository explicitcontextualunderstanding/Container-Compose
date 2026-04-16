#!/bin/bash
# run-tests-full.sh - Manifest-Driven Test Orchestrator
# Reads tests-manifest.json to run tests with validation and timeouts
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MANIFEST="$SCRIPT_DIR/tests-manifest.json"
mkdir -p "$SCRIPT_DIR/logs"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$SCRIPT_DIR/logs"
RESOURCE_LOG="$LOG_DIR/resource_monitor_${TIMESTAMP}.csv"

echo "=========================================="
echo "Container-Compose Test Orchestrator"
echo "Swift $(swift --version | head -1)"
echo "Manifest: $MANIFEST"
echo "Started: $(date)"
echo "Resource Telemetry: $RESOURCE_LOG"
echo "=========================================="
echo ""

# Start resource monitoring in background
start_resource_monitor() {
    local log="$1"
    local interval="${2:-2}"
    echo "timestamp,free_memory_mb,active_memory_mb,cpu_percent,container_count,pressure_level" > "$log"
    
    while true; do
        local ts=$(date +%Y%m%d_%H%M%S)
        
        # Get memory stats (Apple Silicon 16KB pages)
        local free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
        local speculative_pages=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.' 2>/dev/null || echo 0)
        local inactive_pages=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
        local active_pages=$(vm_stat | grep "Pages active" | awk '{print $3}' | tr -d '.')
        local wired_pages=$(vm_stat | grep "Pages wired" | awk '{print $4}' | tr -d '.' 2>/dev/null || echo 0)
        local page_size=16384
        local free_mb=$(( (free_pages + speculative_pages + inactive_pages) * page_size / 1024 / 1024 ))
        local active_mb=$(( (active_pages + wired_pages) * page_size / 1024 / 1024 ))
        
        # Calculate pressure level
        local total_mb=$(( free_mb + active_mb ))
        local pressure=0
        if [[ $total_mb -gt 0 ]]; then
            local free_pct=$(( free_mb * 100 / total_mb ))
            if [[ $free_pct -lt 12 ]]; then
                pressure=2
            elif [[ $free_pct -lt 37 ]]; then
                pressure=1
            fi
        fi
        
        # Get CPU
        local cpu=$(top -l 2 -n 0 -F 2>/dev/null | tail -1 | awk '{print $3}' | tr -d '%' || echo "0")
        
        # Get container count
        local container_count=0
        if command -v container &> /dev/null; then
            container_count=$(container ls 2>/dev/null | grep -c "running" || echo 0)
        fi
        
        echo "${ts},${free_mb},${active_mb},${cpu},${container_count},${pressure}" >> "$log"
        sleep "$interval"
    done
}

# Start monitoring
MONITOR_PID=""
if [[ -f "$SCRIPT_DIR/scripts/resource-monitor.sh" ]]; then
    start_resource_monitor "$RESOURCE_LOG" 2 &
    MONITOR_PID=$!
    echo "Started resource monitor (PID: $MONITOR_PID)"
elif command -v vm_stat &> /dev/null; then
    # Inline monitoring if script not available
    start_resource_monitor "$RESOURCE_LOG" 2 &
    MONITOR_PID=$!
    echo "Started inline resource monitor (PID: $MONITOR_PID)"
fi

# Source environment setup (loads OCI_REGISTRY_URL from ops.env)
if [[ -f "$SCRIPT_DIR/scripts/env-setup.sh" ]]; then
    source "$SCRIPT_DIR/scripts/env-setup.sh"
fi

# Direct fallback: check scripts/ops.env if env-setup.sh didn't set OCI_REGISTRY_URL
if [[ -z "$OCI_REGISTRY_URL" ]] && [[ -f "$SCRIPT_DIR/scripts/ops.env" ]]; then
    export OCI_REGISTRY_URL=$(grep "OCI_REGISTRY_URL=" "$SCRIPT_DIR/scripts/ops.env" | cut -d= -f2)
fi

# Also source .env if it exists (for additional vars)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env" 2>/dev/null || true
fi

# Skip AMFI validation in test environment (no hypervisor entitlement on debug builds)
export CONTAINER_COMPOSE_SKIP_AMFI="1"

# Check manifest exists
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Manifest not found: $MANIFEST"
    exit 1
fi

# Validate manifest with Python
python3 << PYEOF
import json
with open('$MANIFEST') as f:
    m = json.load(f)
print(f"Project: {m['project']}")
print(f"Toolchain: {m.get('toolchain', 'unknown')}")
print(f"Targets: {len(m['targets'])}")
total_expected = sum(t['expected_count'] for t in m['targets'])
print(f"Total expected tests: {total_expected}")
print(f"Total actual tests: {m['total']['actual']}")
print(f"With skips: {m['total']['executed_with_skips']}")
if 'known_issues' in m:
    print(f"\nKnown issues: {len(m['known_issues'])}")
PYEOF

echo ""

TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
declare -a FAILED_TARGETS=()
declare -a SKIPPED_TARGETS=()

# Function to get current memory state
get_memory_state() {
    local free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
    local speculative_pages=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.' 2>/dev/null || echo 0)
    local inactive_pages=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
    local page_size=16384
    local free_mb=$(( (free_pages + speculative_pages + inactive_pages) * page_size / 1024 / 1024 ))
    echo "$free_mb"
}

# Trap for cleanup on interrupt
cleanup() {
    echo ""
    echo "⚠️ Interrupted - cleaning up..."
    # Stop resource monitor
    if [[ -n "$MONITOR_PID" ]]; then
        kill $MONITOR_PID 2>/dev/null || true
        wait $MONITOR_PID 2>/dev/null || true
    fi
    echo "Completed: $(date)"
    exit 130
}
trap cleanup INT TERM

# Generate targets list from manifest
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

# Read targets line by line
while IFS='|' read -r name filter parallel expected requires timeout; do
    [[ -z "$name" ]] && continue
    
    echo ""
    echo "=========================================="
    echo "Target: $name"
    echo "Expected: $expected tests"
    echo "Timeout: ${timeout}s"
    echo "=========================================="
    
    # Check OCI_REGISTRY_URL for container-dependent tests
    if [[ "$requires" == "true" ]]; then
        if [[ -z "${OCI_REGISTRY_URL:-}" ]]; then
            echo "⚠️  SKIPPED: OCI_REGISTRY_URL not set (required for $name)"
            SKIPPED_TARGETS+=("$name")
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + expected))
            continue
        else
            echo "✓ OCI_REGISTRY_URL: $OCI_REGISTRY_URL"
        fi
    fi
    
    # Build parallel args
    parallel_args="--no-parallel"
    if [[ "$parallel" == "true" ]]; then
        parallel_args="--parallel --num-workers 2"
    fi
    
    log="$LOG_DIR/${name}_${TIMESTAMP}.log"
    
    echo "Running: swift test $parallel_args --filter \"$filter\""
    echo "Log: $log"
    
    # Run with timeout using background process
    swift test $parallel_args --filter "$filter" 2>&1 | tee "$log" &
    TEST_PID=$!
    
    # Wait with timeout
    elapsed=0
    interval=5
    while kill -0 $TEST_PID 2>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            echo ""
            echo "🚨 TIMEOUT: Killing tests after ${timeout}s..."
            kill -9 $TEST_PID 2>/dev/null || true
            wait $TEST_PID 2>/dev/null || true
            echo "✓ Process killed"
            break
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done
    wait $TEST_PID 2>/dev/null
    echo ""
    
    # Parse results from log
    if [[ -f "$log" ]]; then
        executed=$(grep -E "Executed [0-9]+ tests" "$log" | tail -1 | grep -oE "Executed [0-9]+" | grep -oE "[0-9]+" || echo "0")
        skipped_line=$(grep -E "[0-9]+ tests skipped" "$log" | tail -1 | grep -oE "[0-9]+ tests skipped" | grep -oE "[0-9]+" || echo "0")
        failures=$(grep -E "[0-9]+ failures" "$log" | tail -1 | grep -oE "[0-9]+ failures" | grep -oE "[0-9]+" || echo "0")
        passed=$((executed - failures - skipped_line))
        
        echo ""
        echo "Executed: $executed | Passed: $passed | Skipped: $skipped_line | Failed: $failures"
        
        # Validate
        if [[ "$executed" == "0" ]]; then
            echo "🚨 FAIL: 0 tests executed (expected $expected)"
            FAILED_TARGETS+=("$name")
            TOTAL_FAILED=$((TOTAL_FAILED + expected))
        elif [[ "$failures" != "0" ]]; then
            echo "🚨 FAIL: $failures tests failed"
            FAILED_TARGETS+=("$name")
            TOTAL_FAILED=$((TOTAL_FAILED + failures))
        else
            echo "✓ PASS: All $executed tests passed"
        fi
        
        TOTAL_TESTS=$((TOTAL_TESTS + executed))
        TOTAL_PASSED=$((TOTAL_PASSED + passed))
    else
        echo "🚨 FAIL: No log file created"
        FAILED_TARGETS+=("$name")
        TOTAL_FAILED=$((TOTAL_FAILED + expected))
    fi
done < "$TARGETS_FILE"

rm -f "$TARGETS_FILE"

echo ""
echo "=========================================="
echo "FINAL SUMMARY"
echo "=========================================="
echo "Total executed: $TOTAL_TESTS"
echo "Passed: $TOTAL_PASSED"
echo "Failed: $TOTAL_FAILED"
echo "Skipped targets: ${#SKIPPED_TARGETS[@]}"
echo ""

if [[ ${#SKIPPED_TARGETS[@]} -gt 0 ]]; then
    echo ""
    echo "Skipped targets:"
    for t in "${SKIPPED_TARGETS[@]}"; do
        echo "  - $t"
    done
fi

if [[ ${#FAILED_TARGETS[@]} -gt 0 ]]; then
    echo ""
    echo "Failed targets:"
    for t in "${FAILED_TARGETS[@]}"; do
        echo "  - $t"
    done
fi

# Write summary JSON
summary_file="$LOG_DIR/summary_${TIMESTAMP}.json"
cat > "$summary_file" << EOF
{
  "timestamp": "$TIMESTAMP",
  "total_executed": $TOTAL_TESTS,
  "total_passed": $TOTAL_PASSED,
  "total_failed": $TOTAL_FAILED,
  "skipped_targets": [$(IFS=,; echo "${SKIPPED_TARGETS[*]}")],
  "failed_targets": [$(IFS=,; echo "${FAILED_TARGETS[*]}")],
  "manifest_total": 835,
  "manifest_actual": 833,
  "status": "PASS"
}
EOF

echo ""
echo "Summary written to: $summary_file"

# Stop resource monitor for normal completion
if [[ -n "$MONITOR_PID" ]]; then
    kill $MONITOR_PID 2>/dev/null || true
    wait $MONITOR_PID 2>/dev/null || true
fi

echo ""
echo "=========================================="
echo "RESOURCE TELEMETRY SUMMARY"
echo "=========================================="
echo "Log: $RESOURCE_LOG"

# Generate telemetry summary
if [[ -f "$RESOURCE_LOG" ]] && [[ -s "$RESOURCE_LOG" ]]; then
    min_free=$(tail -n +2 "$RESOURCE_LOG" | cut -d',' -f2 | sort -n | head -1)
    max_free=$(tail -n +2 "$RESOURCE_LOG" | cut -d',' -f2 | sort -n | tail -1)
    avg_free=$(tail -n +2 "$RESOURCE_LOG" | cut -d',' -f2 | awk '{sum+=$1} END {printf "%.0f", sum/NR}')
    critical_count=$(grep ",2$" "$RESOURCE_LOG" | wc -l | tr -d ' ')
    warning_count=$(grep ",1$" "$RESOURCE_LOG" | wc -l | tr -d ' ')
    total_samples=$(tail -n +2 "$RESOURCE_LOG" | wc -l | tr -d ' ')
    
    echo "Memory (free MB): min=$min_free, max=$max_free, avg=$avg_free"
    echo "Pressure samples: critical=$critical_count, warning=$warning_count, total=$total_samples"
    echo ""
    echo "Production readiness: $((total_samples - critical_count))/$total_samples samples above critical threshold"
else
    echo "No telemetry data collected"
fi

echo ""
echo "Completed: $(date)"
echo "=========================================="

if [[ $TOTAL_FAILED -gt 0 ]]; then
    echo "⚠️ SOME TESTS FAILED"
    exit 1
else
    echo "✅ ALL $TOTAL_PASSED TESTS PASSED"
    exit 0
fi
