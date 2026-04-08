#!/bin/bash
# Cleanup script for CCT_* test containers
# Removes all containers, networks, and snapshots created during testing

echo "=========================================="
echo "TEST CONTAINER CLEANUP"
echo "=========================================="
echo ""

# Find all CCT_* containers
CONTAINERS=$(container ls --all 2>/dev/null | grep "CCT_" | awk '{print $1}' || true)

if [ -z "$CONTAINERS" ]; then
    echo "No CCT_* test containers found."
else
    CONTAINER_COUNT=$(echo "$CONTAINERS" | wc -l | tr -d ' ')
    echo "Found $CONTAINER_COUNT CCT_* test container(s):"
    echo "$CONTAINERS" | while read -r cid; do
        echo "  - $cid"
    done
    echo ""

    # Stop running containers
    RUNNING=$(container ls 2>/dev/null | grep "CCT_" | awk '{print $1}' || true)
    if [ -n "$RUNNING" ]; then
        echo "Stopping running containers..."
        echo "$RUNNING" | while read -r cid; do
            echo "  Stopping: $cid"
            container stop "$cid" 2>/dev/null || true
        done
        echo ""
    fi

    # Delete all containers
    echo "Deleting containers..."
    echo "$CONTAINERS" | while read -r cid; do
        echo "  Deleting: $cid"
        container delete "$cid" 2>/dev/null || true
    done
    echo ""
fi

# Prune orphaned snapshots
echo "Pruning orphaned snapshots..."
SNAPSHOT_COUNT=$(container prune --dry-run 2>/dev/null | grep -c "snapshot" || echo "0")
if [ "$SNAPSHOT_COUNT" -gt 0 ]; then
    container prune -y 2>/dev/null | tail -5
else
    echo "No orphaned snapshots found."
fi

echo ""
echo "✓ Cleanup complete"
echo "=========================================="
