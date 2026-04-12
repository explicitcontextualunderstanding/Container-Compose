#!/bin/bash
# resource-monitor.sh
# Background resource monitoring for test runs
# EMPIRICALLY TUNED: Tracks ACTIVE memory (more predictive of OOM than free)
# Usage: ./scripts/resource-monitor.sh <log_file> &

LOG_FILE="${1:-/tmp/resource_monitor.log}"
INTERVAL="${2:-1}"

# CSV Header: timestamp, free_memory_mb, active_memory_mb, cpu_percent, container_count, pressure_level
echo "timestamp,free_memory_mb,active_memory_mb,cpu_percent,container_count,pressure_level" > "$LOG_FILE"

get_memory_stats() {
    local free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
    local speculative_pages=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.' 2>/dev/null || echo 0)
    local inactive_pages=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
    local active_pages=$(vm_stat | grep "Pages active" | awk '{print $3}' | tr -d '.')
    local wired_pages=$(vm_stat | grep "Pages wired" | awk '{print $4}' | tr -d '.' 2>/dev/null || echo 0)

    # Apple Silicon uses 16KB pages (16384 bytes), not 4KB
    local page_size=16384
    local free_mb=$(( (free_pages + speculative_pages + inactive_pages) * page_size / 1024 / 1024 ))
    local active_mb=$(( (active_pages + wired_pages) * page_size / 1024 / 1024 ))

    # Calculate pressure level (0=normal, 1=warning, 2=critical)
    local total_mb=$(( (free_mb + active_mb) ))
    local pressure_level=0
    if [ $total_mb -gt 0 ]; then
        local free_percent=$(( free_mb * 100 / total_mb ))
        if [ $free_percent -lt 12 ]; then
            pressure_level=2  # Critical: <12% free
        elif [ $free_percent -lt 37 ]; then
            pressure_level=1  # Warning: <37% free
        fi
    fi

    echo "${free_mb},${active_mb},${pressure_level}"
}

get_cpu_percent() {
    top -l 2 -n 0 -F 2>/dev/null | tail -1 | awk '{print $3}' | tr -d '%' || echo "N/A"
}

get_container_count() {
    if command -v container &> /dev/null; then
        container ls 2>/dev/null | grep -c "running" || echo 0
    else
        echo 0
    fi
}

trap "echo 'Resource monitoring stopped at $(date)' >> '$LOG_FILE'; exit 0" SIGINT SIGTERM

while true; do
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    MEMORY_STATS=$(get_memory_stats)
    CPU_PERCENT=$(get_cpu_percent)
    CONTAINER_COUNT=$(get_container_count)
    # Extract pressure level from memory stats (third value)
    PRESSURE_LEVEL=$(echo "$MEMORY_STATS" | cut -d',' -f3)
    # Remove pressure level from memory stats for CSV
    MEMORY_WITHOUT_PRESSURE=$(echo "$MEMORY_STATS" | cut -d',' -f1,2)

    echo "${TIMESTAMP},${MEMORY_WITHOUT_PRESSURE},${CPU_PERCENT},${CONTAINER_COUNT},${PRESSURE_LEVEL}" >> "$LOG_FILE"
    sleep "$INTERVAL"
done
