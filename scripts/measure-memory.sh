#!/bin/bash
# measure-memory.sh
# Empirically measure memory usage per test suite
# Captures: peak RSS, peak system memory, container count
# Usage: ./scripts/measure-memory.sh <test_filter>

set -e

TEST_FILTER="${1:-all}"
LOG_DIR="logs/memory-measurements"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== Memory Measurement Test ==="
echo "Filter: $TEST_FILTER"
echo "Timestamp: $TIMESTAMP"
echo ""

# Ensure log directory exists
mkdir -p "$LOG_DIR"

OUTPUT_FILE="$LOG_DIR/${TEST_FILTER}_${TIMESTAMP}.log"
TELEMETRY_FILE="$LOG_DIR/${TEST_FILTER}_${TIMESTAMP}_telemetry.csv"

# Start resource monitor in background
./scripts/resource-monitor.sh "$TELEMETRY_FILE" 0.5 &
MONITOR_PID=$!

# Function to get current memory
get_memory_stats() {
    local free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
    local speculative=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.' 2>/dev/null || echo 0)
    local inactive=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
    local total_free=$(( (free_pages + speculative + inactive) * 4096 / 1024 / 1024 ))
    echo "$total_free"
}

# Get baseline before tests
BASELINE_FREE=$(get_memory_stats)
echo "Baseline free memory: ${BASELINE_FREE}MB" | tee "$OUTPUT_FILE"
echo ""

# Run the test and capture output
echo "Running tests..." | tee -a "$OUTPUT_FILE"
TEST_START_TIME=$(date +%s)

if [ "$TEST_FILTER" == "all" ]; then
    swift test --parallel --num-workers 2 2>&1 | tee -a "$OUTPUT_FILE" || true
else
    swift test --filter "$TEST_FILTER" 2>&1 | tee -a "$OUTPUT_FILE" || true
fi

TEST_END_TIME=$(date +%s)
DURATION=$((TEST_END_TIME - TEST_START_TIME))

# Stop resource monitor
kill $MONITOR_PID 2>/dev/null || true

# Get post-test memory
POST_FREE=$(get_memory_stats)

# Analyze telemetry
if [ -f "$TELEMETRY_FILE" ]; then
    # Find minimum free memory during test
    MIN_FREE=$(tail -n +2 "$TELEMETRY_FILE" | cut -d',' -f2 | sort -n | head -1)
    MAX_ACTIVE=$(tail -n +2 "$TELEMETRY_FILE" | cut -d',' -f3 | sort -n | tail -1)
    AVG_CPU=$(tail -n +2 "$TELEMETRY_FILE" | cut -d',' -f4 | grep -v '^$' | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print "N/A"}')
    
    echo "" | tee -a "$OUTPUT_FILE"
    echo "=== Memory Usage Analysis ===" | tee -a "$OUTPUT_FILE"
    echo "Baseline free:    ${BASELINE_FREE}MB" | tee -a "$OUTPUT_FILE"
    echo "Minimum free:     ${MIN_FREE}MB" | tee -a "$OUTPUT_FILE"
    echo "Memory consumed:  $((BASELINE_FREE - MIN_FREE))MB" | tee -a "$OUTPUT_FILE"
    echo "Peak active:      ${MAX_ACTIVE}MB" | tee -a "$OUTPUT_FILE"
    echo "Post-test free:   ${POST_FREE}MB" | tee -a "$OUTPUT_FILE"
    echo "Test duration:    ${DURATION}s" | tee -a "$OUTPUT_FILE"
    echo "Avg CPU:          ${AVG_CPU}%" | tee -a "$OUTPUT_FILE"
    echo "" | tee -a "$OUTPUT_FILE"
    
    # Calculate recommended threshold (observed + 20% safety margin)
    OBSERVED=$((BASELINE_FREE - MIN_FREE))
    MARGIN=$((OBSERVED / 5))
    RECOMMENDED=$((OBSERVED + MARGIN))
    
    echo "=== Threshold Recommendation ===" | tee -a "$OUTPUT_FILE"
    echo "Observed usage:   ${OBSERVED}MB" | tee -a "$OUTPUT_FILE"
    echo "Safety margin:    ${MARGIN}MB (20%)" | tee -a "$OUTPUT_FILE"
    echo "RECOMMENDED:      ${RECOMMENDED}MB" | tee -a "$OUTPUT_FILE"
    echo "" | tee -a "$OUTPUT_FILE"
    
    # Show sample of telemetry
    echo "=== Telemetry Sample (first 10 lines) ===" | tee -a "$OUTPUT_FILE"
    head -11 "$TELEMETRY_FILE" | tee -a "$OUTPUT_FILE"
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Full telemetry: $TELEMETRY_FILE" | tee -a "$OUTPUT_FILE"
else
    echo "ERROR: Telemetry file not created" | tee -a "$OUTPUT_FILE"
fi

echo ""
echo "Results saved to: $OUTPUT_FILE"
