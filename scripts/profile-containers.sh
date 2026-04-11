#!/bin/bash
#===----------------------------------------------------------------------===//
# profile-containers.sh
# Profile actual container memory usage during test runs
# Measures allocation delta when containers are created
# Usage: ./scripts/profile-containers.sh [test-filter]
#===----------------------------------------------------------------------===//

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PROFILE_ID="container-profile-$(date +%s)"
PROFILE_DIR="$PROJECT_DIR/logs/profiles/$PROFILE_ID"
mkdir -p "$PROFILE_DIR"

echo "=========================================="
echo "CONTAINER MEMORY PROFILING"
echo "=========================================="
echo "Profile ID: $PROFILE_ID"
echo ""

# Initialize logs
echo "timestamp,event,memory_available_mb,container_count,container_name,image" > "$PROFILE_DIR/events.csv"

# Function to measure available memory
get_available_memory() {
    local free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
    local spec_pages=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.' 2>/dev/null || echo 0)
    local inactive_pages=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
    echo $(( (free_pages + spec_pages + inactive_pages) * 16384 / 1024 / 1024 ))
}

get_container_count() {
    container list --all 2>/dev/null | grep -c "running\|CCT_" 2>/dev/null || echo 0
}

# Monitor for container creation events
monitor_containers() {
    local last_count=0
    local last_memory=$(get_available_memory)
    local start_memory=$last_memory

    echo "$(date +%s),START,$start_memory,0,-,-" >> "$PROFILE_DIR/events.csv"

    while true; do
        sleep 0.5
        local current_count=$(get_container_count)
        local current_memory=$(get_available_memory)

        if [ "$current_count" -ne "$last_count" ]; then
            local event="CREATED"
            if [ "$current_count" -lt "$last_count" ]; then
                event="DESTROYED"
            fi

            local container_info=$(container list --all 2>/dev/null | tail -1)
            local container_name=$(echo "$container_info" | awk '{print $2}' | head -1)
            local image=$(echo "$container_info" | awk '{print $3}' | head -1)

            echo "$(date +%s),$event,$current_memory,$current_count,$container_name,$image" >> "$PROFILE_DIR/events.csv"

            last_count=$current_count
            last_memory=$current_memory
        fi
    done
}

# Start monitoring
monitor_containers &
MONITOR_PID=$!

echo "Monitoring container events..."
echo ""

# Run tests with profiling mode
export MEMORY_GUARD_MODE="LOG_ONLY"
export CCT_PROFILE_RUN="$PROFILE_ID"

run_tests() {
    if [ -n "${1:-}" ]; then
        ./run-tests.sh --filter "$1" 2>&1 | tee "$PROFILE_DIR/test-output.log"
    else
        ./run-tests.sh 2>&1 | tee "$PROFILE_DIR/test-output.log"
    fi
}

trap "kill $MONITOR_PID 2>/dev/null; exit" EXIT INT TERM

run_tests "${1:-}"

# Stop monitoring
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true

# Analyze results
echo ""
echo "=========================================="
echo "CONTAINER PROFILE ANALYSIS"
echo "=========================================="

if [ -f "$PROFILE_DIR/events.csv" ]; then
    local total_events=$(tail -n +2 "$PROFILE_DIR/events.csv" | wc -l)
    local creations=$(grep -c ",CREATED," "$PROFILE_DIR/events.csv" || echo 0)
    local destructions=$(grep -c ",DESTROYED," "$PROFILE_DIR/events.csv" || echo 0)

    echo "Events logged: $total_events"
    echo "Containers created: $creations"
    echo "Containers destroyed: $destructions"
    echo ""

    # Calculate per-container memory impact
    echo "Container memory deltas:"
    echo "(Positive = memory allocated, Negative = memory freed)"
    echo ""

    local prev_mem=""
    while IFS=, read -r timestamp event mem count name image; do
        [ -z "$prev_mem" ] && prev_mem="$mem" && continue

        if [ "$event" = "CREATED" ]; then
            local delta=$(( prev_mem - mem ))
            echo "  $name: $delta MB (available went: $prev_mem -> $mem)"
        fi
        prev_mem="$mem"
    done < <(tail -n +2 "$PROFILE_DIR/events.csv")

    echo ""
    echo "Profile saved to: $PROFILE_DIR"
fi
