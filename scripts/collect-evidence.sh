#!/bin/bash
#===----------------------------------------------------------------------===//
# collect-evidence.sh
# Comprehensive evidence collection for test failure analysis
# Captures: memory thresholds, skip reasons, timing per suite, failure points
# Usage: ./scripts/collect-evidence.sh [test-filter]
#===----------------------------------------------------------------------===//

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# Evidence collection directory
EVIDENCE_DIR="$PROJECT_DIR/logs/evidence-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$EVIDENCE_DIR"

echo "=========================================="
echo "EVIDENCE COLLECTION"
echo "=========================================="
echo "Directory: $EVIDENCE_DIR"
echo ""

# Export for sub-processes
export EVIDENCE_DIR
export EVIDENCE_MEMORY_LOG="$EVIDENCE_DIR/memory-pressure.log"
export EVIDENCE_SKIP_LOG="$EVIDENCE_DIR/skipped-tests.log"
export EVIDENCE_TIMING_LOG="$EVIDENCE_DIR/timing.log"
export EVIDENCE_FAILURE_LOG="$EVIDENCE_DIR/failures.log"

# Initialize logs
echo "timestamp,free_memory_mb,active_memory_mb,cpu_percent,container_count,test_suite" > "$EVIDENCE_DIR/telemetry.csv"
echo "timestamp,test_name,skip_reason,memory_at_skip" > "$EVIDENCE_DIR/skips.csv"
echo "timestamp,suite_name,test_count,duration_seconds" > "$EVIDENCE_DIR/timing.csv"
echo "timestamp,test_name,error_message,memory_at_failure" > "$EVIDENCE_DIR/failures.csv"

# Background memory monitoring
collect_telemetry() {
    local test_suite="${1:-unknown}"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local free_mem active_mem cpu containers
    
    # Get memory stats
    if command -v vm_stat &>/dev/null; then
        local free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
        local speculative=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.' 2>/dev/null || echo 0)
        local inactive=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
        local active=$(vm_stat | grep "Pages active" | awk '{print $3}' | tr -d '.')
        local wired=$(vm_stat | grep "Pages wired" | awk '{print $4}' | tr -d '.' 2>/dev/null || echo 0)
        
        free_mem=$(((free_pages + speculative + inactive) * 4096 / 1024 / 1024))
        active_mem=$(((active + wired) * 4096 / 1024 / 1024))
    else
        free_mem="N/A"
        active_mem="N/A"
    fi
    
    # Get CPU
    cpu=$(top -l 1 -n 0 2>/dev/null | tail -1 | awk '{print $3}' | tr -d '%' || echo "N/A")
    
    # Get container count
    containers=$(container list --all 2>/dev/null | grep -c "CCT_" || echo 0)
    
    echo "$timestamp,$free_mem,$active_mem,$cpu,$containers,$test_suite" >> "$EVIDENCE_DIR/telemetry.csv"
    
    # Check thresholds
    if [[ "$free_mem" != "N/A" && "$free_mem" -lt 300 ]]; then
        echo "$timestamp: CRITICAL - Free memory ${free_mem}MB (threshold: 300MB)" >> "$EVIDENCE_MEMORY_LOG"
    elif [[ "$free_mem" != "N/A" && "$free_mem" -lt 800 ]]; then
        echo "$timestamp: WARNING - Free memory ${free_mem}MB (threshold: 800MB for heavy tests)" >> "$EVIDENCE_MEMORY_LOG"
    fi
}

# Parse test output for evidence
parse_test_output() {
    local log_file="$1"
    
    # Extract Memory Guard skips
    grep -E "MEMORY GUARD: Skipping" "$log_file" 2>/dev/null | while read -r line; do
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local test_name=$(echo "$line" | grep -o "'[^']*'" | head -1 | tr -d "'")
        local reason="Memory below threshold"
        local memory=$(grep "Available:" <<< "$line" | grep -o "[0-9]*MB" | head -1)
        echo "$timestamp,$test_name,$reason,$memory" >> "$EVIDENCE_DIR/skips.csv"
    done
    
    # Extract blocked tests from ResourceArbiter
    grep -E "blocked.*reason" "$log_file" 2>/dev/null | while read -r line; do
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local reason=$(echo "$line" | grep -o "reason:.*" | cut -d')' -f1)
        echo "$timestamp,ResourceArbiter,$reason,N/A" >> "$EVIDENCE_DIR/skips.csv"
    done
    
    # Extract failures
    grep -E "(failed|FAIL|✗)" "$log_file" 2>/dev/null | while read -r line; do
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local test_name=$(echo "$line" | grep -o "test[^:]*" | head -1)
        local error=$(echo "$line" | cut -d':' -f2-)
        local memory=$(tail -1 "$EVIDENCE_DIR/telemetry.csv" | cut -d',' -f2)
        echo "$timestamp,$test_name,$error,$memory" >> "$EVIDENCE_DIR/failures.csv"
    done
}

# Suite-by-suite timing
measure_suite() {
    local suite_name="$1"
    local start_time=$(date +%s)
    
    collect_telemetry "$suite_name"
    
    # Return start time for duration calculation
    echo "$start_time"
}

end_suite() {
    local suite_name="$1"
    local start_time="$2"
    local test_count="${3:-0}"
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    echo "$timestamp,$suite_name,$test_count,$duration" >> "$EVIDENCE_DIR/timing.csv"
    collect_telemetry "$suite_name-complete"
}

# Export functions for use by run-tests.sh
export -f collect_telemetry parse_test_output measure_suite end_suite

# Run tests with evidence collection
echo "Starting evidence collection run..."
echo ""

TEST_LOG="$EVIDENCE_DIR/full-test-run.log"

# Run tests with all output captured
./run-tests.sh --auto-clean "$@" 2>&1 | tee "$TEST_LOG" &
TEST_PID=$!

# Collect telemetry every 5 seconds
while kill -0 $TEST_PID 2>/dev/null; do
    collect_telemetry "in-progress"
    sleep 5
done

wait $TEST_PID
TEST_EXIT=$?

# Parse results
echo ""
echo "Parsing test output..."
parse_test_output "$TEST_LOG"

# Generate evidence report
echo ""
echo "=========================================="
echo "EVIDENCE COLLECTION COMPLETE"
echo "=========================================="
echo ""
echo "Files collected:"
echo "  - telemetry.csv: Memory/CPU/container data every 5s"
echo "  - skips.csv: Tests skipped by MemoryGuardTrait"
echo "  - timing.csv: Per-suite execution times"
echo "  - failures.csv: Test failures with context"
echo "  - memory-pressure.log: Threshold violations"
echo "  - full-test-run.log: Complete test output"
echo ""

# Quick analysis
echo "=========================================="
echo "QUICK ANALYSIS"
echo "=========================================="

# Count skips
SKIP_COUNT=$(wc -l < "$EVIDENCE_DIR/skips.csv" 2>/dev/null | tr -d ' ')
SKIP_COUNT=$((SKIP_COUNT - 1))  # Exclude header
if [ "$SKIP_COUNT" -gt 0 ]; then
    echo "Tests skipped: $SKIP_COUNT"
    echo "Skip reasons:"
    cut -d',' -f3 "$EVIDENCE_DIR/skips.csv" | tail -n +2 | sort | uniq -c | sort -rn
else
    echo "Tests skipped: 0"
fi

echo ""

# Find minimum free memory
if [ -f "$EVIDENCE_DIR/telemetry.csv" ]; then
    MIN_MEMORY=$(tail -n +2 "$EVIDENCE_DIR/telemetry.csv" | cut -d',' -f2 | sort -n | head -1)
    echo "Minimum free memory: ${MIN_MEMORY:-N/A} MB"
    
    if [[ "$MIN_MEMORY" != "N/A" && "$MIN_MEMORY" -lt 300 ]]; then
        echo "⚠️ CRITICAL: Memory dropped below 300MB - emergency valve triggered"
    elif [[ "$MIN_MEMORY" != "N/A" && "$MIN_MEMORY" -lt 800 ]]; then
        echo "⚠️ Heavy tests (WordPress/MySQL) skipped - below 800MB threshold"
    fi
fi

echo ""
echo "Threshold recommendations:"
echo "  - Current heavy test threshold: 800MB"
echo "  - Current emergency threshold: 300MB"
echo "  - For full suite: Ensure >800MB free before running"
echo ""
echo "Evidence directory: $EVIDENCE_DIR"

exit $TEST_EXIT
