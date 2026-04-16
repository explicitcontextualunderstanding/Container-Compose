#!/bin/bash
# Container cleanup library for Apple Container runtime
# Handles container/snapshot lifecycle management and orphaned resource cleanup
#
# Usage: source scripts/lib/container-cleanup.sh
#
# Functions provided:
#   - get_apple_container_state()     Parse Apple Container state.json
#   - prune_test_snapshots()          Remove orphaned test snapshots
#   - aggressive_cleanup_before_tests() Clean all CCT_* artifacts pre-test
#   - cleanup_test_containers()       Clean all CCT_* artifacts post-test

# Apple Container data directory
AC_DATA_DIR="${AC_DATA_DIR:-$HOME/Library/Application Support/com.apple.container}"
AC_SNAPSHOTS_DIR="${AC_SNAPSHOTS_DIR:-$AC_DATA_DIR/snapshots}"

# Get container IDs from Apple Container state.json
# Returns: CCT_IDS (test containers) and ALL_IDS (all containers)
# Also handles CCT_orphan_ prefix that Apple Container adds to orphaned containers
# Usage: eval "$(get_apple_container_state)"
get_apple_container_state() {
    if [ ! -f "$AC_DATA_DIR/state.json" ]; then
        echo "CCT_IDS=''"
        echo "CCT_ORPHAN_IDS=''"
        echo "ALL_IDS=''"
        return 1
    fi
    
    if ! command -v python3 &> /dev/null; then
        echo "CCT_IDS=''"
        echo "CCT_ORPHAN_IDS=''"
        echo "ALL_IDS=''"
        return 1
    fi
    
    python3 -c "
import json, os
state_file = os.path.expanduser(\"$AC_DATA_DIR/state.json\")
with open(state_file) as f:
    state = json.load(f)
containers = state.get(\"containers\", {})
cct = []
cct_orphan = []
all_cids = []
for cid in containers:
    all_cids.append(cid)
    cdata = containers[cid].get(\"configuration\", {}) if isinstance(containers[cid], dict) else {}
    name = cdata.get(\"id\", \"\")
    if name.startswith(\"CCT_orphan_\"):
        cct_orphan.append(cid)
    elif name.startswith(\"CCT_\"):
        cct.append(cid)
print(\"CCT_IDS=\" + \" \".join(cct))
print(\"CCT_ORPHAN_IDS=\" + \" \".join(cct_orphan))
print(\"ALL_IDS=\" + \" \".join(all_cids))
" 2>/dev/null || true
}

# Prune orphaned snapshots from test containers (CCT_ and CCT_orphan_ prefixes)
# Apple Container leaves behind snapshot directories even after container delete
# These accumulate and consume GBs of disk space
# Returns: Number of snapshots removed and MB reclaimed
prune_test_snapshots() {
    local snapshot_dir="$AC_SNAPSHOTS_DIR"
    if [ ! -d "$snapshot_dir" ]; then
        return 0
    fi

    # Get IDs of CCT_ containers, CCT_orphan_ containers, and all containers from state.json
    local cct_ids=""
    local cct_orphan_ids=""
    local all_ids=""
    eval "$(get_apple_container_state)"

    local removed_count=0
    local removed_mb=0

    # Remove snapshots for CCT_ containers
    for cid in $CCT_IDS; do
        if [ -d "$snapshot_dir/$cid" ]; then
            local size
            size=$(du -sm "$snapshot_dir/$cid" 2>/dev/null | awk '{print $1}')
            rm -rf "$snapshot_dir/$cid"
            removed_count=$((removed_count + 1))
            removed_mb=$((removed_mb + size))
        fi
    done

    # Remove snapshots for CCT_orphan_ containers (Apple Container's orphaned container prefix)
    for cid in $CCT_ORPHAN_IDS; do
        if [ -d "$snapshot_dir/$cid" ]; then
            local size
            size=$(du -sm "$snapshot_dir/$cid" 2>/dev/null | awk '{print $1}')
            rm -rf "$snapshot_dir/$cid"
            removed_count=$((removed_count + 1))
            removed_mb=$((removed_mb + size))
        fi
    done

    # Remove snapshots not referenced by ANY container (orphaned from previous runs)
    for snap_dir in "$snapshot_dir"/*/; do
        [ -d "$snap_dir" ] || continue
        local snap_name
        snap_name=$(basename "$snap_dir")
        # Skip if this snapshot belongs to a known container
        case " $ALL_IDS " in
            *" $snap_name "*) continue ;;
        esac
        local size
        size=$(du -sm "$snap_dir" 2>/dev/null | awk '{print $1}')
        rm -rf "$snap_dir"
        removed_count=$((removed_count + 1))
        removed_mb=$((removed_mb + size))
    done

    if [ "$removed_count" -gt 0 ]; then
        echo "  Pruned $removed_count snapshot(s), reclaimed ${removed_mb}MB"
    fi

    # Also run container prune to clean up any runtime-level orphans
    if command -v container &> /dev/null; then
        container prune 2>/dev/null || true
    fi
}

# Aggressive cleanup function - removes ALL test containers AND their snapshots
# This is called BEFORE tests start to ensure clean state
# Handles both CCT_* and CCT_orphan_* prefixes (Apple Container adds CCT_orphan_ to orphaned containers)
aggressive_cleanup_before_tests() {
    echo "=========================================="
    echo "PRE-TEST CLEANUP: Removing ALL CCT_* artifacts"
    echo "=========================================="

    if ! command -v container &> /dev/null; then
        echo "⚠️  'container' CLI not available"
        return 1
    fi

    # Find all test containers (CCT_* and CCT_orphan_* patterns)
    local test_containers
    test_containers=$(container list --all 2>/dev/null | grep -E "^CCT_|^CCT_orphan_" | awk '{print $1}' || true)

    if [ -n "$test_containers" ]; then
        local count
        count=$(echo "$test_containers" | wc -l | tr -d ' ')
        echo "Found $count CCT_* container(s) to remove:"

        # Use process substitution to avoid subshell
        while read -r container_id; do
            [ -z "$container_id" ] && continue
            echo " - Stopping: $container_id"
            container stop "$container_id" 2>/dev/null || true
            echo " - Deleting: $container_id"
            container delete "$container_id" 2>/dev/null || true
        done < <(echo "$test_containers")
        echo "✓ Stopped and deleted $count containers"
    fi

    # Remove ALL CCT_* and CCT_orphan_* snapshots
    local snapshot_dir="$AC_SNAPSHOTS_DIR"
    if [ -d "$snapshot_dir" ]; then
        echo "Removing orphaned snapshots..."
        local removed_count=0
        local removed_mb=0

        for snap_dir in "$snapshot_dir"/*/; do
            [ -d "$snap_dir" ] || continue
            local snap_name
            snap_name=$(basename "$snap_dir")

            # Check if this snapshot is orphaned:
            # Snapshot ID (uuid) doesn't map to any active container name
            # All known containers from container list (by name or partial ID match)
            known_containers=$(container list --all 2>/dev/null | awk '{print $1}' || true)
            is_orphaned=true
            for c in $known_containers; do
                # Match either exact name or partial ID (snap_name is uuid prefix)
                if [[ "$c" == *"$snap_name"* ]]; then
                    is_orphaned=false
                    break
                fi
            done
            if $is_orphaned; then
                local size
                size=$(du -sm "$snap_dir" 2>/dev/null | awk '{print $1}')
                rm -rf "$snap_dir"
                removed_count=$((removed_count + 1))
                removed_mb=$((removed_mb + size))
            fi
        done

        if [ "$removed_count" -gt 0 ]; then
            echo "✓ Removed $removed_count snapshot(s), reclaimed ${removed_mb}MB"
        fi
    fi

    # Final prune
    container prune 2>/dev/null || true

    echo "✓ Pre-test cleanup complete"
    echo "=========================================="
    echo ""
}

# Cleanup function - removes test containers AND their orphaned snapshots (POST-TEST)
# This is called via trap on script exit
# Handles both CCT_* and CCT_orphan_* prefixes (Apple Container adds CCT_orphan_ to orphaned containers)
cleanup_test_containers() {
    local exit_code=$?
    echo ""
    echo "=========================================="
    echo "POST-TEST CLEANUP: Removing ALL CCT_* artifacts"
    echo "=========================================="

    # Find and remove containers created by our tests (CCT_* and CCT_orphan_* patterns)
    # NOTE: Tests MUST use unique project names (test-* prefix) to avoid collision
    # with production infrastructure (apple-honcho, hermes, etc.)
    if command -v container &> /dev/null; then
        local test_containers
        test_containers=$(container list --all 2>/dev/null | grep -E "^CCT_" | awk '{print $1}' || true)

        if [ -n "$test_containers" ]; then
            echo "Found test containers to clean up:"
            echo "$test_containers" | while read -r container_id; do
                [ -z "$container_id" ] && continue
                echo " - Stopping: $container_id"
                container stop "$container_id" 2>/dev/null || true
                echo " - Deleting: $container_id"
                container delete "$container_id" 2>/dev/null || true
            done
            echo "✓ Test containers cleaned up"
        else
            echo "✓ No test containers to clean up"
        fi
    else
        echo "⚠️  'container' CLI not available, skipping container cleanup"
    fi

    # Prune orphaned test snapshots
    prune_test_snapshots

    echo "=========================================="

    # Exit with the original exit code
    exit $exit_code
}