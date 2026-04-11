#!/bin/bash
#===----------------------------------------------------------------------===//
# cleanup-orchestrator.sh
# Surgical cleanup script with resource awareness for 8GB M2 stability
# Features: label-based cleanup, emergency memory valve, I/O snapshot lock
# Usage: ./cleanup-orchestrator.sh <RUN_ID> [--emergency|--graceful|--force]
#===----------------------------------------------------------------------===//

set -euo pipefail

# Configuration
RUN_ID="${1:-}"
MODE="${2:---graceful}"
TELEMETRY="${TELEMETRY_FILE:-/tmp/resource_monitor.log}"
LOCKFILE="/tmp/cct-snapshot.lock"
MEMORY_THRESHOLD_MB=300
EMERGENCY_MEMORY_THRESHOLD_MB=300

# Colors for output (match existing script style)
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Container CLI detection - prefer Apple Container, fallback to Docker
CONTAINER_CLI=""
if command -v container &> /dev/null; then
    CONTAINER_CLI="container"
elif command -v docker &> /dev/null; then
    CONTAINER_CLI="docker"
else
    echo -e "${RED}ERROR: No container CLI found (container or docker)${NC}"
    exit 1
fi

# Helper: Print usage
usage() {
    echo "Usage: $0 <RUN_ID> [--emergency|--graceful|--force]"
    echo ""
    echo "Modes:"
    echo "  --emergency  Memory-aware purge; kills heavy containers first if <300MB free"
    echo "  --graceful   Stop containers gracefully before delete (default)"
    echo "  --force      Immediate delete without stopping first"
    exit 1
}

# Validate arguments
if [ -z "$RUN_ID" ]; then
    usage
fi

case "$MODE" in
    --emergency|--graceful|--force)
        ;;
    *)
        usage
        ;;
esac

echo "=========================================="
echo "CLEANUP ORCHESTRATOR"
echo "=========================================="
echo "RUN_ID: $RUN_ID"
echo "MODE: $MODE"
echo "CLI: $CONTAINER_CLI"
echo ""

#===----------------------------------------------------------------------===//
# Phase 1: I/O Snapshot Lock Check
#===----------------------------------------------------------------------===//
check_snapshot_lock() {
    local wait_count=0
    local max_wait=60

    while [ -f "$LOCKFILE" ]; do
        if [ $wait_count -eq 0 ]; then
            echo -e "${YELLOW}Disk I/O Lock active (Snapshotting)... Waiting.${NC}"
        fi

        sleep 1
        wait_count=$((wait_count + 1))

        if [ $wait_count -ge $max_wait ]; then
            echo -e "${YELLOW}Warning: Lock file still present after ${max_wait}s, proceeding anyway${NC}"
            break
        fi
    done

    if [ $wait_count -gt 0 ] && [ $wait_count -lt $max_wait ]; then
        echo -e "${GREEN}Lock released after ${wait_count}s, proceeding with cleanup${NC}"
    fi
}

#===----------------------------------------------------------------------===//
# Phase 2: Get Containers by Label
#===----------------------------------------------------------------------===//
get_labeled_containers() {
    local label="com.container-compose.test-run-id=$RUN_ID"

    if [ "$CONTAINER_CLI" = "docker" ]; then
        # Docker supports label filtering natively
        docker ps -aq --filter "label=$label" 2>/dev/null || true
    else
        # Apple Container - use name-based filtering with CCT_ prefix
        # Containers with our RUN_ID should have CCT_${RUN_ID}_ prefix
        container list --all 2>/dev/null | grep "CCT_${RUN_ID}_" | awk '{print $1}' || true
    fi
}

# Get heavy containers first (for emergency mode)
get_heavy_containers() {
    local label="com.container-compose.test-run-id=$RUN_ID"

    if [ "$CONTAINER_CLI" = "docker" ]; then
        # Docker: filter by label AND ancestor (image name)
        docker ps -q --filter "label=$label" --filter "ancestor=wordpress" 2>/dev/null || true
        docker ps -q --filter "label=$label" --filter "ancestor=mysql" 2>/dev/null || true
        docker ps -q --filter "label=$label" --filter "ancestor=mariadb" 2>/dev/null || true
    else
        # Apple Container: use image name from container list
        container list --all 2>/dev/null | grep "CCT_${RUN_ID}_" | grep -E "wordpress|mysql|mariadb" | awk '{print $1}' || true
    fi
}

#===----------------------------------------------------------------------===//
# Phase 3: Emergency Memory Valve
#===----------------------------------------------------------------------===//
check_emergency_memory() {
    if [[ "$MODE" != "--emergency" ]]; then
        return 0
    fi

    if [ ! -f "$TELEMETRY" ]; then
        echo -e "${YELLOW}Warning: Telemetry file not found at $TELEMETRY${NC}"
        return 0
    fi

    # Get latest free memory from telemetry CSV
    # Format: timestamp,free_memory_mb,active_memory_mb,cpu_percent,container_count
    local free_mem
    free_mem=$(tail -n 1 "$TELEMETRY" 2>/dev/null | cut -d',' -f2 || echo "8192")

    # Validate we got a number
    if ! [[ "$free_mem" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}Warning: Could not parse free memory from telemetry${NC}"
        return 0
    fi

    if [ "$free_mem" -lt "$EMERGENCY_MEMORY_THRESHOLD_MB" ]; then
        echo -e "${RED}CRITICAL: Free RAM ${free_mem}MB. Executing Priority Purge.${NC}"

        # Kill heavy hitters first to reclaim RAM instantly
        local heavy_containers
        heavy_containers=$(get_heavy_containers)

        if [ -n "$heavy_containers" ]; then
            echo "Killing heavy containers first (WordPress/MySQL)..."
            echo "$heavy_containers" | while read -r cid; do
                [ -n "$cid" ] || continue
                echo "  - Emergency kill: $cid"
                if [ "$CONTAINER_CLI" = "docker" ]; then
                    docker kill "$cid" 2>/dev/null || true
                else
                    container stop "$cid" 2>/dev/null || true
                fi
            done
            echo -e "${GREEN}Heavy containers terminated${NC}"
        fi

        return 1  # Signal that we performed emergency action
    fi

    return 0
}

#===----------------------------------------------------------------------===//
# Phase 4: Graceful Container Cleanup
#===----------------------------------------------------------------------===//
cleanup_containers() {
    local containers
    containers=$(get_labeled_containers)

    if [ -z "$containers" ]; then
        echo "No containers found for RUN_ID: $RUN_ID"
        return 0
    fi

    local count
    count=$(echo "$containers" | grep -c '^' || echo "0")
    echo "Found $count container(s) to clean up for RUN_ID: $RUN_ID"

    # Graceful mode: stop first, then delete
    if [[ "$MODE" == "--graceful" ]]; then
        echo "Stopping containers gracefully..."
        echo "$containers" | while read -r cid; do
            [ -n "$cid" ] || continue
            echo "  - Stopping: $cid"
            if [ "$CONTAINER_CLI" = "docker" ]; then
                docker stop "$cid" 2>/dev/null || true
            else
                container stop "$cid" 2>/dev/null || true
            fi
        done
        sleep 1  # Brief pause for graceful shutdown
    fi

    # Delete containers
    echo "Deleting containers..."
    echo "$containers" | while read -r cid; do
        [ -n "$cid" ] || continue
        echo "  - Deleting: $cid"
        if [ "$CONTAINER_CLI" = "docker" ]; then
            docker rm -f "$cid" 2>/dev/null || true
        else
            container delete "$cid" 2>/dev/null || true
        fi
    done

    echo -e "${GREEN}Cleanup complete for $count container(s)${NC}"
}

#===----------------------------------------------------------------------===//
# Phase 5: Cleanup Orphaned Snapshots (Apple Container specific)
#===----------------------------------------------------------------------===//
cleanup_snapshots() {
    if [ "$CONTAINER_CLI" = "docker" ]; then
        return 0  # Docker handles snapshots differently
    fi

    local snapshot_dir="${AC_SNAPSHOTS_DIR:-$HOME/Library/Application Support/com.apple.container/snapshots}"
    if [ ! -d "$snapshot_dir" ]; then
        return 0
    fi

    echo "Checking for orphaned snapshots..."
    local removed_count=0
    local removed_mb=0

    for snap_dir in "$snapshot_dir"/CCT_${RUN_ID}_*/; do
        [ -d "$snap_dir" ] || continue

        local size
        size=$(du -sm "$snap_dir" 2>/dev/null | awk '{print $1}')
        rm -rf "$snap_dir"
        removed_count=$((removed_count + 1))
        removed_mb=$((removed_mb + size))
    done

    if [ "$removed_count" -gt 0 ]; then
        echo -e "${GREEN}Removed $removed_count snapshot(s), reclaimed ${removed_mb}MB${NC}"
    fi
}

#===----------------------------------------------------------------------===//
# Main Execution
#===----------------------------------------------------------------------===//

# Step 1: Wait for I/O Snapshot Lock
check_snapshot_lock

# Step 2: Emergency memory check (if in emergency mode)
check_emergency_memory

# Step 3: Clean up containers
cleanup_containers

# Step 4: Clean up orphaned snapshots (Apple Container only)
cleanup_snapshots

echo ""
echo "=========================================="
echo -e "${GREEN}Cleanup orchestration complete${NC}"
echo "=========================================="
