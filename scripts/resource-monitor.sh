#!/bin/bash
# resource-monitor.sh
# Background resource monitoring for test runs
# Captures memory, CPU, and container stats to diagnose OOM vs logic failures
# Usage: ./scripts/resource-monitor.sh <log_file> &

LOG_FILE="${1:-/tmp/resource_monitor.log}"
INTERVAL="${2:-1}"

echo "timestamp,free_memory_mb,active_memory_mb,cpu_percent,container_count" > "$LOG_FILE"

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

    echo "${free_mb},${active_mb}"
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
    
    echo "${TIMESTAMP},${MEMORY_STATS},${CPU_PERCENT},${CONTAINER_COUNT}" >> "$LOG_FILE"
    sleep "$INTERVAL"
done
