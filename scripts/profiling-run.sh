#!/bin/bash
# profiling-run.sh
# Empirical memory profiling for Container-Compose test suite
# Captures actual memory usage to derive proper thresholds
# Usage: ./scripts/profiling-run.sh [test_filter]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

TEST_FILTER="${1:-all}"
RUN_ID="cct-profiling-$(date +%s)-$$"
LOG_DIR="logs/profiling"
TELEMETRY_FILE="$LOG_DIR/${RUN_ID}_telemetry.csv"
ANALYSIS_FILE="$LOG_DIR/${RUN_ID}_analysis.json"

mkdir -p "$LOG_DIR"

echo "========================================"
echo "  CONTAINER-COMPOSE MEMORY PROFILING"
echo "========================================"
echo "RUN_ID: $RUN_ID"
echo "TEST_FILTER: $TEST_FILTER"
echo "TELEMETRY: $TELEMETRY_FILE"
echo ""

# Start resource monitor
echo "[1/5] Starting resource monitor..."
./scripts/resource-monitor.sh "$TELEMETRY_FILE" 0.5 &
MONITOR_PID=$!
sleep 2

# Run tests in profiling mode (MEMORY_GUARD_MODE=LOG_ONLY)
echo "[2/5] Running tests in profiling mode..."
echo "      (MemoryGuard will log but NOT skip tests)"
echo ""

if [ "$TEST_FILTER" == "all" ]; then
    TEST_CMD="swift test"
else
    TEST_CMD="swift test --filter '$TEST_FILTER'"
fi

export RUN_ID="$RUN_ID"
export RESOURCE_LOG_PATH="$TELEMETRY_FILE"
export MEMORY_GUARD_MODE="LOG_ONLY"

# Capture test output
TEST_OUTPUT="$LOG_DIR/${RUN_ID}_test_output.log"
$TEST_CMD 2>&1 | tee "$TEST_OUTPUT" || true

# Stop monitor
echo ""
echo "[3/5] Stopping resource monitor..."
kill $MONITOR_PID 2>/dev/null || true
sleep 1

# Analyze telemetry
echo "[4/5] Analyzing telemetry data..."

if [ -f "$TELEMETRY_FILE" ] && [ -s "$TELEMETRY_FILE" ]; then
    # Calculate statistics
    TOTAL_LINES=$(wc -l < "$TELEMETRY_FILE")
    DATA_LINES=$((TOTAL_LINES - 1))
    
    if [ $DATA_LINES -gt 0 ]; then
        # Extract metrics using awk
        MIN_FREE=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '{print $2}' | sort -n | head -1)
        MAX_ACTIVE=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '{print $3}' | sort -n | tail -1)
        AVG_CPU=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' 'NR>1 && $4!="" {sum+=$4; count++} END {if(count>0) printf "%.1f", sum/count; else print "N/A"}')
        MAX_CONTAINERS=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '{print $5}' | sort -n | tail -1)
        
        # Calculate peak memory consumption
        TOTAL_MEM=$(/usr/sbin/sysctl -n hw.memsize | awk '{print int($1/1024/1024)}')
        PEAK_USED=$((TOTAL_MEM - MIN_FREE))
        
        # Calculate Victoria Safety Margin
        MARGIN=$((PEAK_USED / 4))  # 25%
        OS_BUFFER=150  # macOS UI responsiveness buffer
        RECOMMENDED=$((PEAK_USED + MARGIN + OS_BUFFER))
        
        # Create analysis JSON
        cat > "$ANALYSIS_FILE" << EOF
{
  "run_id": "$RUN_ID",
  "test_filter": "$TEST_FILTER",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "system": {
    "total_memory_mb": $TOTAL_MEM,
    "os_buffer_mb": $OS_BUFFER
  },
  "telemetry": {
    "samples": $DATA_LINES,
    "file": "$TELEMETRY_FILE"
  },
  "peak_observed": {
    "memory_used_mb": $PEAK_USED,
    "min_free_mb": $MIN_FREE,
    "max_active_mb": $MAX_ACTIVE,
    "max_containers": $MAX_CONTAINERS
  },
  "calculated_thresholds": {
    "safety_margin_percent": 25,
    "safety_margin_mb": $MARGIN,
    "os_buffer_mb": $OS_BUFFER,
    "recommended_mb": $RECOMMENDED,
    "rounded_mb": $(( (RECOMMENDED / 100 + 1) * 100 ))
  },
  "classification": {
    "lightweight": $((RECOMMENDED / 4)),
    "medium": $((RECOMMENDED / 2)),
    "heavy": $RECOMMENDED
  }
}
EOF
        
        echo ""
        echo "========================================"
        echo "  EMPIRICAL THRESHOLD CALCULATION"
        echo "========================================"
        echo ""
        echo "PEAK OBSERVED:"
        echo "  Memory used:      ${PEAK_USED}MB"
        echo "  Minimum free:     ${MIN_FREE}MB"
        echo "  Max active:       ${MAX_ACTIVE}MB"
        echo "  Max containers:   ${MAX_CONTAINERS}"
        echo "  Avg CPU:          ${AVG_CPU}%"
        echo ""
        echo "VICTORIA SAFETY MARGIN:"
        echo "  Peak observed:    ${PEAK_USED}MB"
        echo "  Safety margin:    25% (${MARGIN}MB)"
        echo "  OS buffer:        ${OS_BUFFER}MB"
        echo "  RECOMMENDED:      ${RECOMMENDED}MB"
        echo "  Rounded:          $(( (RECOMMENDED / 100 + 1) * 100 ))MB"
        echo ""
        echo "CLASSIFICATION:"
        echo "  Lightweight:      $((RECOMMENDED / 4))MB"
        echo "  Medium:           $((RECOMMENDED / 2))MB"
        echo "  Heavy:            ${RECOMMENDED}MB"
        echo ""
        echo "FILES:"
        echo "  Telemetry: $TELEMETRY_FILE"
        echo "  Analysis:  $ANALYSIS_FILE"
        echo "  Test log:  $TEST_OUTPUT"
        echo ""
        
        # Generate Swift code snippet
        echo "========================================"
        echo "  RESOURCEGUARD.SWIFT UPDATE"
        echo "========================================"
        echo ""
        cat << SWIFT
/// Empirically derived thresholds from profiling run: $RUN_ID
/// Date: $(date)
/// System: $(sysctl -n hw.model) with $(/usr/sbin/sysctl -n hw.memsize | awk '{print int($1/1024/1024/1024)}')GB RAM
/// Test filter: $TEST_FILTER
///
/// Peak observed: ${PEAK_USED}MB (from ${DATA_LINES} samples)
/// Safety margin: 25% (${MARGIN}MB)
/// OS buffer: ${OS_BUFFER}MB
/// Calculated: ${RECOMMENDED}MB → Rounded to $(( (RECOMMENDED / 100 + 1) * 100 ))MB

extension Trait where Self == MemoryGuardTrait {
    /// Heavy container tests (empirically: ${PEAK_USED}MB peak + 25% margin)
    /// Verified with: $RUN_ID
    public static var heavyContainer: MemoryGuardTrait {
        minMemory($(( (RECOMMENDED / 100 + 1) * 100 )))
    }
    
    /// Medium tests (~50% of heavy)
    public static var mediumContainer: MemoryGuardTrait {
        minMemory($(( (RECOMMENDED / 200 + 1) * 100 )))
    }
    
    /// Lightweight tests (~25% of heavy)
    public static var lightweight: MemoryGuardTrait {
        minMemory($(( (RECOMMENDED / 400 + 1) * 100 )))
    }
}
SWIFT
        echo ""
    else
        echo "ERROR: No telemetry data captured"
        exit 1
    fi
else
    echo "ERROR: Telemetry file not found or empty"
    exit 1
fi

echo "[5/5] Profiling complete!"
echo ""
echo "Next steps:"
echo "  1. Review:  cat $ANALYSIS_FILE"
echo "  2. Update: Sources/ContainerTesting/ResourceGuard.swift"
echo "  3. Verify: ./scripts/profiling-run.sh ComposeUpTests"
