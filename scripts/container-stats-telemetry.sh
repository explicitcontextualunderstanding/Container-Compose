#!/bin/bash
# container-stats-telemetry.sh
# ACCURATE container stats telemetry for CCT_* test containers
# Replaces broken shell parsing with proper container stats capture
# Usage: ./container-stats-telemetry.sh [--output <file>] [--interval <seconds>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOG_DIR"

# Configuration
OUTPUT_FILE="${OUTPUT_FILE:-$LOG_DIR/container_telemetry_$(date +%Y%m%d_%H%M%S).csv}"
INTERVAL="${INTERVAL:-1}"  # Sample every second for accuracy
RUN_ID="${CCT_RUN_ID:-$(date +%s)}"

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Accurate container stats telemetry for CCT_* test containers
Replaces fragile awk-based parsing with robust column detection

OPTIONS:
    -o, --output <file>       Output CSV file (default: logs/container_telemetry_TIMESTAMP.csv)
    -i, --interval <seconds>  Sampling interval (default: 1)
    -d, --duration <seconds>  Run for N seconds (0 = until killed)
    -j, --json                Output JSON instead of CSV
    -s, --summary             Show summary at exit
    -h, --help                Show this help

EXAMPLES:
    # Start telemetry collection (run in background)
    ./container-stats-telemetry.sh &
    TELEMETRY_PID=$!
    swift test
    kill $TELEMETRY_PID

    # Run for 60 seconds with summary
    ./container-stats-telemetry.sh --duration 60 --summary

EOF
}

# Parse memory value to MB
parse_memory_to_mb() {
    local value="$1"

    # Handle various formats: 15.5MiB, 1.2GiB, 256KiB, etc.
    if [[ "$value" =~ ^([0-9.]+)([KMGT]i?B)?$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]:-}"

        case "$unit" in
            KiB|K) echo "scale=2; $num / 1024" | bc ;;
            MiB|M) echo "$num" ;;
            GiB|G) echo "scale=2; $num * 1024" | bc ;;
            TiB|T) echo "scale=2; $num * 1024 * 1024" | bc ;;
            *) echo "$num" ;;
        esac
    else
        echo "0"
    fi
}

# Parse CPU percentage
parse_cpu() {
    local value="$1"
    echo "$value" | sed 's/%//'
}

# Get container stats using Python for robust parsing
get_container_stats_python() {
    local container_id="$1"

    python3 << PYTHON 2>/dev/null
import subprocess
import re

try:
    result = subprocess.run(
        ['container', 'stats', '--no-stream', container_id],
        capture_output=True, text=True, timeout=10
    )

    if result.returncode != 0:
        exit(1)

    lines = result.stdout.strip().split('\n')
    if len(lines) < 2:
        exit(1)

    # Header: CONTAINER ID NAME CPU % MEM USAGE / LIMIT MEM % NET I/O BLOCK I/O PIDS
    # Data:   abc123       nginx 0.5%  15MiB / 128MiB 11.7% 1kB / 0B    0B / 0B   2

    header = lines[0]
    data = lines[-1]

    # Find column positions
    headers = header.split()
    data_parts = data.split()

    if len(data_parts) < 7:
        exit(1)

    # Find NAME position (usually column 2)
    name_idx = headers.index('NAME') if 'NAME' in headers else 1
    name = data_parts[name_idx] if name_idx < len(data_parts) else 'unknown'

    # Find CPU %
    cpu_idx = headers.index('CPU') if 'CPU' in headers else 2
    cpu = data_parts[cpu_idx].rstrip('%') if cpu_idx < len(data_parts) else '0'

    # Find MEM USAGE / LIMIT (spans multiple columns due to spaces)
    mem_usage, mem_limit = '0', '0'
    for i, part in enumerate(data_parts):
        if 'MiB' in part or 'GiB' in part or 'KiB' in part:
            if mem_usage == '0':
                mem_usage = part
            elif mem_limit == '0':
                mem_limit = part
            break

    # Find MEM %
    mem_pct = '0'
    for i, part in enumerate(data_parts):
        if '%' in part and i > 3:  # Skip CPU %
            mem_pct = part.rstrip('%')
            break

    # Find PIDS (last column)
    pids = data_parts[-1] if data_parts[-1].isdigit() else '0'

    print(f"{name}|{cpu}|{mem_usage}|{mem_limit}|{mem_pct}|{pids}")

except Exception as e:
    exit(1)
PYTHON
}

# Alternative: Use container inspect for more reliable data
get_container_inspect() {
    local container_id="$1"

    container inspect "$container_id" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    if not data:
        exit(1)

    c = data[0]
    name = c.get("configuration", {}).get("id", "unknown")

    # Get memory limit from config
    memory_limit = c.get("configuration", {}).get("resources", {}).get("memoryInBytes", 0)
    memory_limit_mb = memory_limit / (1024 * 1024) if memory_limit else 0

    # Get current stats if available
    stats = c.get("stats", {})
    memory_usage = stats.get("memory", {}).get("usage", 0)
    memory_usage_mb = memory_usage / (1024 * 1024) if memory_usage else 0

    cpu_usage = stats.get("cpu", {}).get("usage", {}).get("total", 0)

    print(f"{name}|{memory_usage_mb:.2f}|{memory_limit_mb:.2f}|{cpu_usage}")
except:
    exit(1)
' 2>/dev/null
}

# Collect stats for all CCT_ containers
collect_stats() {
    local timestamp=$(date +%s)
    local iso_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Get list of CCT_ containers
    local cct_containers
    cct_containers=$(container list --all --format json 2>/dev/null | python3 -c '
import json, sys
try:
    containers = json.load(sys.stdin)
    for c in containers:
        cid = c.get("configuration", {}).get("id", "")
        if cid.startswith("CCT_"):
            print(c.get("id", ""))
except:
    pass
')

    if [[ -z "$cct_containers" ]]; then
        return
    fi

    for container_id in $cct_containers; do
        # Try stats first
        local stats
        stats=$(get_container_stats_python "$container_id")

        if [[ -n "$stats" ]]; then
            IFS='|' read -r name cpu mem_usage mem_limit mem_pct pids <<< "$stats"

            # Convert memory to MB
            local usage_mb limit_mb
            usage_mb=$(parse_memory_to_mb "$mem_usage")
            limit_mb=$(parse_memory_to_mb "$mem_limit")

            # Calculate waste
            local waste_mb waste_pct
            waste_mb=$(echo "scale=2; $limit_mb - $usage_mb" | bc)
            if (( $(echo "$limit_mb > 0" | bc -l) )); then
                waste_pct=$(echo "scale=2; $waste_mb / $limit_mb * 100" | bc)
            else
                waste_pct="0"
            fi

            echo "$timestamp,$iso_timestamp,$container_id,$name,$cpu,$usage_mb,$limit_mb,$mem_pct,$waste_mb,$waste_pct,$pids"
        fi
    done
}

# Show summary
show_summary() {
    if [[ ! -f "$OUTPUT_FILE" ]]; then
        echo "No telemetry data collected"
        return
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "           CONTAINER TELEMETRY SUMMARY"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Check if file has data beyond header
    local line_count
    line_count=$(wc -l < "$OUTPUT_FILE")

    if [[ "$line_count" -le 1 ]]; then
        echo "No container telemetry data collected"
        echo "(CCT_ containers may not have been running during sampling)"
        return
    fi

    # Calculate per-container stats
    echo "Per-container peak usage:"
    echo ""
    printf "%-40s %10s %10s %10s %8s\n" "CONTAINER" "LIMIT(MB)" "PEAK(MB)" "WASTE(MB)" "WASTE%"
    printf "%s\n" "───────────────────────────────────────────────────────────────────────────────"

    # Use Python for accurate aggregation
    python3 << PYTHON
import csv
from collections import defaultdict

stats = defaultdict(lambda: {'limit': 0, 'peak': 0, 'samples': 0})

with open('$OUTPUT_FILE', 'r') as f:
    reader = csv.DictReader(f)
    for row in reader:
        name = row.get('container_name', 'unknown')
        try:
            limit = float(row.get('memory_limit_mb', 0))
            usage = float(row.get('memory_usage_mb', 0))
        except:
            continue

        stats[name]['limit'] = max(stats[name]['limit'], limit)
        stats[name]['peak'] = max(stats[name]['peak'], usage)
        stats[name]['samples'] += 1

total_limit = 0
total_peak = 0

for name, data in sorted(stats.items(), key=lambda x: x[1]['peak'], reverse=True):
    limit = data['limit']
    peak = data['peak']
    waste = limit - peak
    waste_pct = (waste / limit * 100) if limit > 0 else 0
    indicator = '🚨' if waste_pct > 50 else '⚠️' if waste_pct > 25 else '✅'

    print(f"{name[:40]:<40} {limit:>10.1f} {peak:>10.1f} {waste:>10.1f} {waste_pct:>7.1f}% {indicator}")
    total_limit += limit
    total_peak += peak

print("─" * 79)
total_waste = total_limit - total_peak
waste_pct = (total_waste / total_limit * 100) if total_limit > 0 else 0
print(f"{'TOTAL':<40} {total_limit:>10.1f} {total_peak:>10.1f} {total_waste:>10.1f} {waste_pct:>7.1f}%")
print("")
print(f"Containers tracked: {len(stats)}")
print(f"Output file: $OUTPUT_FILE")
PYTHON

    echo ""
    echo "═══════════════════════════════════════════════════════════"
}

# Main collection loop
main() {
    # Parse arguments
    local duration=0
    local show_summary_at_exit=false
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -i|--interval)
                INTERVAL="$2"
                shift 2
                ;;
            -d|--duration)
                duration="$2"
                shift 2
                ;;
            -j|--json)
                json_mode=true
                shift
                ;;
            -s|--summary)
                show_summary_at_exit=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Setup CSV
    echo "timestamp,iso_timestamp,container_id,container_name,cpu_percent,memory_usage_mb,memory_limit_mb,memory_percent,waste_mb,waste_percent,pids" > "$OUTPUT_FILE"

    echo "[Telemetry] Started collection (output: $OUTPUT_FILE, interval: ${INTERVAL}s)"
    echo "[Telemetry] Press Ctrl+C to stop"

    local start_time=$(date +%s)
    local sample_count=0

    # Cleanup trap
    cleanup() {
        echo ""
        echo "[Telemetry] Stopped after $sample_count samples"
        if [[ "$show_summary_at_exit" == true ]]; then
            show_summary
        fi
        exit 0
    }
    trap cleanup SIGINT SIGTERM EXIT

    # Collection loop
    while true; do
        local stats
        stats=$(collect_stats)

        if [[ -n "$stats" ]]; then
            echo "$stats" >> "$OUTPUT_FILE"
            ((sample_count++))
        fi

        # Check duration
        if [[ "$duration" -gt 0 ]]; then
            local elapsed=$(($(date +%s) - start_time))
            if [[ "$elapsed" -ge "$duration" ]]; then
                break
            fi
        fi

        sleep "$INTERVAL"
    done
}

main "$@"
