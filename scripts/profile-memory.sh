#!/bin/bash
#===----------------------------------------------------------------------===//
# profile-memory.sh
# Empirical memory profiling for dynamic threshold derivation
# Runs tests with logging-only mode to capture actual peak usage
# Usage: ./scripts/profile-memory.sh [test-filter]
#===----------------------------------------------------------------------===//

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PROFILE_RUN_ID="profile-$(date +%s)"
PROFILE_DIR="$PROJECT_DIR/logs/profiles/$PROFILE_RUN_ID"
mkdir -p "$PROFILE_DIR"

echo "=========================================="
echo "MEMORY PROFILING RUN"
echo "=========================================="
echo "Profile ID: $PROFILE_RUN_ID"
echo "Output: $PROFILE_DIR"
echo ""

# Export for Swift to pick up
export CCT_PROFILE_RUN="$PROFILE_RUN_ID"
export MEMORY_GUARD_MODE="LOG_ONLY"  # Don't skip, just log

# Function to sample memory during test run
sample_memory() {
    local test_name="${1:-unknown}"
    local timestamp=$(date +%s)

    # Get detailed memory breakdown
    local vm_stats=$(vm_stat)
    local free_pages=$(echo "$vm_stats" | grep "Pages free" | awk '{print $3}' | tr -d '.')
    local spec_pages=$(echo "$vm_stats" | grep "Pages speculative" | awk '{print $3}' | tr -d '.' 2>/dev/null || echo 0)
    local inactive_pages=$(echo "$vm_stats" | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
    local active_pages=$(echo "$vm_stats" | grep "Pages active" | awk '{print $3}' | tr -d '.')
    local wired_pages=$(echo "$vm_stats" | grep "Pages wired" | awk '{print $4}' | tr -d '.' 2>/dev/null || echo 0)

    # Apple Silicon: 16KB pages
    local page_size=16384
    local free_mb=$(( (free_pages + spec_pages + inactive_pages) * page_size / 1024 / 1024 ))
    local active_mb=$(( (active_pages + wired_pages) * page_size / 1024 / 1024 ))
    local total_used=$((active_mb))

    # Log sample - track available memory (what matters for guards)
    # Available = free + speculative + inactive (can be reclaimed)
    # Test allocation delta will show when containers are created
    echo "$timestamp,$test_name,$free_mb,$total_used,$active_mb" >> "$PROFILE_DIR/memory-samples.csv"
}

# Initialize sample log
echo "timestamp,test_name,free_mb,total_used_mb" > "$PROFILE_DIR/memory-samples.csv"

# Start background sampler
(
    while true; do
        sample_memory "background"
        sleep 0.5
done
) &
SAMPLER_PID=$!

# Run tests with filter (or all tests)
FILTER="${1:-}"

echo "Running tests with memory profiling..."
echo "Press Ctrl+C to stop and analyze"
echo ""

# Run the test suite
cleanup() {
    echo ""
    echo "Profiling stopped. Analyzing..."
    kill $SAMPLER_PID 2>/dev/null || true

    # Calculate thresholds from samples
    echo ""
    echo "=========================================="
    echo "EMPIRICAL THRESHOLD DERIVATION"
    echo "=========================================="

    if [ -f "$PROFILE_DIR/memory-samples.csv" ]; then
        # Skip header, get max total_used
        local peak_usage=$(tail -n +2 "$PROFILE_DIR/memory-samples.csv" | cut -d',' -f4 | sort -n | tail -1)
        local min_free=$(tail -n +2 "$PROFILE_DIR/memory-samples.csv" | cut -d',' -f3 | sort -n | head -1)

        echo "Peak memory observed: ${peak_usage:-0} MB"
        echo "Minimum free memory: ${min_free:-0} MB"

        if [ -n "$peak_usage" ] && [ "$peak_usage" -gt 0 ]; then
            # Calculate thresholds with safety margins
            local heavy_threshold=$(( peak_usage * 125 / 100 + 150 ))  # 25% margin + 150MB buffer
            local medium_threshold=$(( heavy_threshold * 60 / 100 ))    # 60% of heavy
            local light_threshold=$(( heavy_threshold * 30 / 100 ))     # 30% of heavy

            echo ""
            echo "RECOMMENDED THRESHOLDS:"
            echo "  Heavy tests:  $heavy_threshold MB (peak: $peak_usage + 25% + 150MB)"
            echo "  Medium tests: $medium_threshold MB (~60% of heavy)"
            echo "  Light tests:  $light_threshold MB (~30% of heavy)"
            echo ""
            echo "Update ResourceGuard.swift with:"
            echo "  public static var heavyContainer: MemoryGuardTrait { minMemory($heavy_threshold) }"
            echo "  public static var mediumContainer: MemoryGuardTrait { minMemory($medium_threshold) }"
            echo "  public static var lightweight: MemoryGuardTrait { minMemory($light_threshold) }"

            # Save to file
            cat > "$PROFILE_DIR/thresholds.sh" << EOF
# Empirically derived thresholds from profile run: $PROFILE_RUN_ID
# Peak observed: ${peak_usage}MB
# Date: $(date)

HEAVY_THRESHOLD=$heavy_threshold
MEDIUM_THRESHOLD=$medium_threshold
LIGHT_THRESHOLD=$light_threshold
EOF

            echo ""
            echo "Thresholds saved to: $PROFILE_DIR/thresholds.sh"
        fi
    fi
}

trap cleanup EXIT INT TERM

if [ -n "$FILTER" ]; then
    ./run-tests.sh --filter "$FILTER" 2>&1 | tee "$PROFILE_DIR/test-output.log"
else
    ./run-tests.sh 2>&1 | tee "$PROFILE_DIR/test-output.log"
fi

# Kill sampler
kill $SAMPLER_PID 2>/dev/null || true
wait $SAMPLER_PID 2>/dev/null || true

echo ""
echo "Profile complete: $PROFILE_DIR"
