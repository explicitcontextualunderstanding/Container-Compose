#!/bin/bash
# analyze-telemetry.sh
# Analyze telemetry CSV to extract tuning insights

TELEMETRY_FILE="${1:-logs/profiling/cct-profiling-1775951100-52740_telemetry.csv}"

if [ ! -f "$TELEMETRY_FILE" ]; then
    echo "ERROR: Telemetry file not found: $TELEMETRY_FILE"
    exit 1
fi

echo "========================================"
echo "  TELEMETRY ANALYSIS"
echo "========================================"
echo ""

# Basic stats
echo "=== BASIC STATISTICS ==="
TOTAL_SAMPLES=$(tail -n +2 "$TELEMETRY_FILE" | wc -l)
echo "Total samples: $TOTAL_SAMPLES"

# Memory analysis
echo ""
echo "=== FREE MEMORY ANALYSIS ==="
MIN_FREE=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '{print $2}' | sort -n | head -1)
MAX_FREE=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '{print $2}' | sort -n | tail -1)
AVG_FREE=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '{sum+=$2; count++} END {if(count>0) printf "%.0f", sum/count}')

echo "Minimum free: ${MIN_FREE}MB"
echo "Maximum free: ${MAX_FREE}MB"
echo "Average free: ${AVG_FREE}MB"

# Pressure events
echo ""
echo "=== PRESSURE EVENTS ==="
CRITICAL_COUNT=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '$2<200 {count++} END {print count+0}')
WARNING_COUNT=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '$2>=200 && $2<500 {count++} END {print count+0}')
NORMAL_COUNT=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '$2>=500 {count++} END {print count+0}')

echo "Critical (<200MB): $CRITICAL_COUNT events"
echo "Warning (200-500MB): $WARNING_COUNT events"
echo "Normal (>500MB): $NORMAL_COUNT events"

# Container analysis
echo ""
echo "=== CONTAINER COUNT ANALYSIS ==="
MIN_CONTAINERS=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '{print $5}' | sort -n | head -1)
MAX_CONTAINERS=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '{print $5}' | sort -n | tail -1)
AVG_CONTAINERS=$(tail -n +2 "$TELEMETRY_FILE" | awk -F',' '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count}')

echo "Min containers: $MIN_CONTAINERS"
echo "Max containers: $MAX_CONTAINERS"
echo "Avg containers: $AVG_CONTAINERS"

# Correlation analysis
echo ""
echo "=== MEMORY VS CONTAINER CORRELATION ==="
tail -n +2 "$TELEMETRY_FILE" | awk -F',' '
    NR > 1 {
        if ($5 > 5) high_container++
        if ($2 < 500) low_memory++
        if ($5 > 5 && $2 < 500) both++
    }
    END {
        print "High container count (>5): " high_container "samples"
        print "Low memory (<500MB): " low_memory "samples"
        print "Both conditions: " both "samples"
    }
'

# Time-based patterns
echo ""
echo "=== TEMPORAL PATTERNS ==="
echo "First 10 samples (startup phase):"
head -11 "$TELEMETRY_FILE"

echo ""
echo "Lowest 10 memory points:"
tail -n +2 "$TELEMETRY_FILE" | sort -t',' -k2 -n | head -10

# Recommendations
echo ""
echo "=== TUNING RECOMMENDATIONS ==="

if [ "$CRITICAL_COUNT" -gt 0 ]; then
    echo "⚠️  $CRITICAL_COUNT critical memory events detected"
    echo "    → Consider reducing concurrent containers"
    echo "    → Add staggered container startup (500ms delays)"
fi

if [ "$WARNING_COUNT" -gt 50 ]; then
    echo "⚠️  $WARNING_COUNT warning events (20%+ of samples)"
    echo "    → Current threshold may be too aggressive"
    echo "    → Consider: container pooling or sequential execution"
fi

if [ "$MAX_CONTAINERS" -eq "$MIN_CONTAINERS" ]; then
    echo "ℹ️   Container count never changed ($MAX_CONTAINERS throughout)"
    echo "    → Cleanup may not be working between tests"
    echo "    → Check: withProjectCleanup() is being called"
fi

if [ "$MAX_CONTAINERS" -gt 5 ]; then
    echo "⚠️   Peak containers: $MAX_CONTAINERS"
    echo "    → Reduce max concurrent: defaultMaxContainerSlots"
    echo "    → Current: 8, Recommended: 5 for 8GB M2"
fi

# Threshold validation
echo ""
echo "=== THRESHOLD VALIDATION ==="
CURRENT_THRESHOLD=450
if [ "$MIN_FREE" -lt "$CURRENT_THRESHOLD" ]; then
    VIOLATIONS=$(tail -n +2 "$TELEMETRY_FILE" | awk -F"," -v thresh="$CURRENT_THRESHOLD" '$2 < thresh {count++} END {print count}')
    PERCENT=$(echo "scale=1; $VIOLATIONS * 100 / $TOTAL_SAMPLES" | bc -l 2>/dev/null || echo "N/A")
    echo "⚠️  Current threshold ($CURRENT_THRESHOLD MB) would block $VIOLATIONS tests ($PERCENT%)"
    echo "    → Consider lowering to ~$MIN_FREE MB if swap pressure acceptable"
else
    echo "✓ Current threshold ($CURRENT_THRESHOLD MB) safe"
    echo "    Min observed ($MIN_FREE MB) is above threshold"
fi

echo ""
echo "========================================"
