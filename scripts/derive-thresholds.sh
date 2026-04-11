#!/bin/bash
# derive-thresholds.sh
# Derive empirical MemoryGuardTrait thresholds from telemetry
# Uses Victoria Protocol formula: Threshold = MinObservedFree + SafetyMargin

set -e

TELEMETRY_FILE="${1:-}"

if [ -z "$TELEMETRY_FILE" ]; then
    echo "Usage: $0 <telemetry_csv>"
    echo ""
    echo "Derives empirical thresholds from telemetry data"
    echo "Example: $0 logs/resource_usage_cct-xxx_20260411_xxxxxx.csv"
    exit 1
fi

if [ ! -f "$TELEMETRY_FILE" ]; then
    echo "ERROR: Telemetry file not found: $TELEMETRY_FILE"
    exit 1
fi

echo "=========================================="
echo "EMPIRICAL THRESHOLD DERIVATION"
echo "=========================================="
echo ""
echo "Telemetry: $TELEMETRY_FILE"
echo ""

# Extract statistics from telemetry
# Format: timestamp,free_memory_mb,active_memory_mb,cpu_percent,container_count

# Get min/max free memory observed (filter to numeric values only)
MIN_FREE=$(tail -n +2 "$TELEMETRY_FILE" | cut -d',' -f2 | grep -E '^[0-9]+$' | sort -n | head -1)
MAX_FREE=$(tail -n +2 "$TELEMETRY_FILE" | cut -d',' -f2 | grep -E '^[0-9]+$' | sort -n | tail -1)
AVG_FREE=$(tail -n +2 "$TELEMETRY_FILE" | cut -d',' -f2 | grep -E '^[0-9]+$' | awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print 0}')

# Get peak active memory (filter to numeric values only)
MAX_ACTIVE=$(tail -n +2 "$TELEMETRY_FILE" | cut -d',' -f3 | grep -E '^[0-9]+$' | sort -n | tail -1)

# Count samples (lines with numeric free_memory_mb)
SAMPLES=$(tail -n +2 "$TELEMETRY_FILE" | cut -d',' -f2 | grep -E '^[0-9]+$' | wc -l | tr -d ' ')

# Count pressure events (free < 500MB)
PRESSURE_EVENTS=$(tail -n +2 "$TELEMETRY_FILE" | cut -d',' -f2 | grep -E '^[0-9]+$' | awk '$1 < 500' | wc -l | tr -d ' ')

# Count critical events (free < 200MB)
CRITICAL_EVENTS=$(tail -n +2 "$TELEMETRY_FILE" | cut -d',' -f2 | grep -E '^[0-9]+$' | awk '$1 < 200' | wc -l | tr -d ' ')

echo "TELEMETRY SUMMARY:"
echo "  Samples:              $SAMPLES"
echo "  Min Free Memory:      ${MIN_FREE:-N/A} MB"
echo "  Max Free Memory:      ${MAX_FREE:-N/A} MB"
echo "  Avg Free Memory:      ${AVG_FREE:-N/A} MB"
echo "  Peak Active Memory:   ${MAX_ACTIVE:-N/A} MB"
echo "  Pressure Events:      $PRESSURE_EVENTS (< 500MB)"
echo "  Critical Events:      $CRITICAL_EVENTS (< 200MB)"
echo ""

# Validate we have data
if [ -z "$MIN_FREE" ] || [ "$MIN_FREE" = "0" ]; then
    echo "ERROR: No valid telemetry data found"
    exit 1
fi

# VICTORIA PROTOCOL THRESHOLD DERIVATION
# Formula: Threshold = MinObservedFree + SafetyMargin
#
# Rationale: MemoryGuardTrait checks "if (free >= minRequiredMB)"
# So threshold should be set ABOVE the minimum observed to prevent
# the test from running when memory would be too low
#
# Safety margin accounts for:
# - Memory spikes during test execution
# - macOS memory compression variability
# - Other processes allocating memory

SAFETY_MARGIN=100  # MB buffer to prevent critical pressure
OS_BUFFER=150      # MB macOS needs for UI responsiveness

# Base threshold: minimum observed + safety margin
BASE_THRESHOLD=$(( MIN_FREE + SAFETY_MARGIN ))

# Add OS buffer to ensure we don't starve the system
HEAVY_THRESHOLD=$(( BASE_THRESHOLD + OS_BUFFER ))

# Medium: ~60% of heavy (empirically derived from test patterns)
MEDIUM_THRESHOLD=$(( HEAVY_THRESHOLD * 60 / 100 ))

# Lightweight: ~30% of heavy
LIGHT_THRESHOLD=$(( HEAVY_THRESHOLD * 30 / 100 ))

# Round to nice numbers for readability
round_threshold() {
    local t=$1
    if [ $t -gt 1000 ]; then
        echo $(( (t + 50) / 100 * 100 ))  # Round to nearest 100
    elif [ $t -gt 100 ]; then
        echo $(( (t + 5) / 10 * 10 ))      # Round to nearest 10
    else
        echo $t
    fi
}

HEAVY_ROUNDED=$(round_threshold $HEAVY_THRESHOLD)
MEDIUM_ROUNDED=$(round_threshold $MEDIUM_THRESHOLD)
LIGHT_ROUNDED=$(round_threshold $LIGHT_THRESHOLD)

echo "=========================================="
echo "VICTORIA PROTOCOL THRESHOLD DERIVATION"
echo "=========================================="
echo ""
echo "Formula: Threshold = MinObservedFree + SafetyMargin + OS_Buffer"
echo ""
echo "Parameters:"
echo "  MinObservedFree:      ${MIN_FREE} MB"
echo "  SafetyMargin:         ${SAFETY_MARGIN} MB (prevents pressure)"
echo "  OS_Buffer:            ${OS_BUFFER} MB (macOS UI)"
echo ""
echo "Calculated Thresholds:"
echo "  Raw Heavy:            ${HEAVY_THRESHOLD} MB"
echo "  Raw Medium:           ${MEDIUM_THRESHOLD} MB"
echo "  Raw Light:            ${LIGHT_THRESHOLD} MB"
echo ""
echo "ROUNDED THRESHOLDS (Human-Readable):"
echo "  ┌────────────────────────────────────────────────────────┐"
echo "  │ Heavy Container:   ${HEAVY_ROUNDED} MB                           │"
echo "  │   Basis: ${MIN_FREE}MB + ${SAFETY_MARGIN}MB + ${OS_BUFFER}MB = ${HEAVY_THRESHOLD}MB → ${HEAVY_ROUNDED}MB        │"
echo "  │   Use:  WordPress + MySQL tests                       │"
echo "  │                                                        │"
echo "  │ Medium Container:  ${MEDIUM_ROUNDED} MB                           │"
echo "  │   Basis: ~60% of heavy threshold                      │"
echo "  │   Use:  pgmicro + nginx tests                         │"
echo "  │                                                        │"
echo "  │ Lightweight:       ${LIGHT_ROUNDED} MB                            │"
echo "  │   Basis: ~30% of heavy threshold                      │"
echo "  │   Use:  busybox, alpine tests                         │"
echo "  └────────────────────────────────────────────────────────┘"
echo ""

# Validation warnings
if [ $CRITICAL_EVENTS -gt 0 ]; then
    echo "⚠️  WARNING: $CRITICAL_EVENTS critical memory events detected!"
    echo "    System went below 200MB free during test run."
    echo "    Consider closing other applications before running tests."
    echo ""
fi

if [ $PRESSURE_EVENTS -gt 5 ]; then
    echo "⚠️  WARNING: $PRESSURE_EVENTS pressure events detected!"
    echo "    System frequently below 500MB free."
    echo "    Current thresholds may be too aggressive."
    echo ""
fi

echo "=========================================="
echo "UPDATE ResourceGuard.swift:"
echo "=========================================="
echo ""
echo "extension Trait where Self == MemoryGuardTrait {"
echo "    /// Empirically derived from $SAMPLES telemetry samples"
echo "    /// Min observed: ${MIN_FREE}MB, SafetyMargin: ${SAFETY_MARGIN}MB, OS_Buffer: ${OS_BUFFER}MB"
echo "    /// Profile: $(basename $TELEMETRY_FILE)"
echo "    public static var heavyContainer: MemoryGuardTrait {"
echo "        minMemory($HEAVY_ROUNDED)"
echo "    }"
echo ""
echo "    /// ~60% of heavy threshold (${MEDIUM_ROUNDED}MB)"
echo "    public static var mediumContainer: MemoryGuardTrait {"
echo "        minMemory($MEDIUM_ROUNDED)"
echo "    }"
echo ""
echo "    /// ~30% of heavy threshold (${LIGHT_ROUNDED}MB)"
echo "    public static var lightweight: MemoryGuardTrait {"
echo "        minMemory($LIGHT_ROUNDED)"
echo "    }"
echo "}"
echo ""

# Save to file
OUTPUT_FILE="$(dirname $TELEMETRY_FILE)/thresholds-$(basename $TELEMETRY_FILE .csv).sh"
cat > "$OUTPUT_FILE" << EOF
#!/bin/bash
# Empirically derived thresholds from telemetry
# Source: $TELEMETRY_FILE
# Date: $(date)
# Samples: $SAMPLES
# Min Free: ${MIN_FREE}MB

HEAVY_THRESHOLD=$HEAVY_ROUNDED
MEDIUM_THRESHOLD=$MEDIUM_ROUNDED
LIGHT_THRESHOLD=$LIGHT_ROUNDED
SAFETY_MARGIN=$SAFETY_MARGIN
OS_BUFFER=$OS_BUFFER
EOF

echo "Thresholds saved to: $OUTPUT_FILE"
