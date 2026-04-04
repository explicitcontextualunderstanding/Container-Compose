#!/bin/bash
# Run Container-Compose tests with proper privilege handling
# Usage: ./run-tests.sh [--auto-clean] [--no-sudo] [test-filter]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Apple Container data directory
AC_DATA_DIR="$HOME/Library/Application Support/com.apple.container"
AC_SNAPSHOTS_DIR="$AC_DATA_DIR/snapshots"

# Prune orphaned snapshots from test containers (CCT_ prefix).
# Apple Container leaves behind snapshot directories even after container delete.
# These accumulate and consume GBs of disk space.
prune_test_snapshots() {
    local snapshot_dir="$AC_SNAPSHOTS_DIR"
    if [ ! -d "$snapshot_dir" ]; then
        return
    fi

    # Get IDs of CCT_ containers and all containers from state.json
    local cct_ids=""
    local all_ids=""
    if [ -f "$AC_DATA_DIR/state.json" ] && command -v python3 &> /dev/null; then
        eval "$(python3 -c "
import json, os
state_file = os.path.expanduser(\"$AC_DATA_DIR/state.json\")
with open(state_file) as f:
    state = json.load(f)
containers = state.get(\"containers\", {})
cct = []
all_cids = []
for cid in containers:
    all_cids.append(cid)
    cdata = containers[cid].get(\"configuration\", {}) if isinstance(containers[cid], dict) else {}
    name = cdata.get(\"id\", \"\")
    if name.startswith(\"CCT_\"):
        cct.append(cid)
print(\"CCT_IDS=\" + \" \".join(cct))
print(\"ALL_IDS=\" + \" \".join(all_cids))
" 2>/dev/null || true)"
    fi

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

# Cleanup function - removes test containers AND their orphaned snapshots
cleanup_test_containers() {
    local exit_code=$?
    echo ""
    echo "=========================================="
    echo "Cleaning up test containers and snapshots..."
    echo "=========================================="

    # Find and remove only containers created by our tests (CCT_*)
    if command -v container &> /dev/null; then
        local test_containers
	test_containers=$(container list --all 2>/dev/null | grep "CCT_" | awk '{print $1}' || true)

        if [ -n "$test_containers" ]; then
            echo "Found test containers to clean up:"
            echo "$test_containers" | while read -r container_id; do
                echo "  - Stopping: $container_id"
                container stop "$container_id" 2>/dev/null || true
                echo "  - Deleting: $container_id"
                container delete "$container_id" 2>/dev/null || true
            done
            echo "✓ Test containers cleaned up"
        else
            echo "✓ No test containers to clean up"
        fi
    else
        echo "⚠️ 'container' CLI not available, skipping container cleanup"
    fi

    # Prune orphaned test snapshots
    prune_test_snapshots

    echo "=========================================="

    # Exit with the original exit code
    exit $exit_code
}

# Register cleanup function to run on exit
trap cleanup_test_containers EXIT

# Prune leftover test containers from previous runs
prune_leftover_test_containers() {
    if ! command -v container &> /dev/null; then
        return
    fi

    # First prune snapshots from previous runs
    prune_test_snapshots

    local test_containers
    test_containers=$(container list --all 2>/dev/null | grep "CCT_" | awk '{print $1}' || true)

    if [ -z "$test_containers" ]; then
        return
    fi

    local count
    count=$(echo "$test_containers" | wc -l | tr -d ' ')

    echo "Found $count leftover test container(s) from previous runs:"
    echo "$test_containers" | while read -r container_id; do
        echo "  - $container_id"
    done

    local should_clean=false
    if [ "$AUTO_CLEAN" = true ] || [ -n "$CI" ] || [ -n "$GITHUB_ACTIONS" ]; then
        should_clean=true
    else
        read -p "Remove them? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            should_clean=true
        fi
    fi

    if [ "$should_clean" = true ]; then
        local stopped=0 deleted=0
        echo "$test_containers" | while read -r container_id; do
            container stop "$container_id" 2>/dev/null && ((stopped++)) || true
            container delete "$container_id" 2>/dev/null && ((deleted++)) || true
        done
        echo "✓ Cleaned up leftover test containers"
        echo ""
    else
        echo "Skipping cleanup."
        echo ""
    fi
}

echo "=========================================="
echo "Container-Compose Test Runner"
echo "=========================================="
echo ""

# Neutralize conda environment contamination (shared with build-sign-install.sh)
source "$SCRIPT_DIR/scripts/env-setup.sh"
[ -n "$_ENV_SETUP_SUMMARY" ] && echo " Env: $_ENV_SETUP_SUMMARY"

# Check for stale lock files in temp directory
LOCK_PATTERN="_Users_kieranlal_workspace_Container-Compose_.build"
TEMP_DIR="/var/folders/1s/1zg1gfbn3j79qw5g2fqsf9q00000gn/T"

if [ -d "$TEMP_DIR" ]; then
    stale_locks=$(find "$TEMP_DIR" -name "*$LOCK_PATTERN*" -type f 2>/dev/null || true)
    if [ -n "$stale_locks" ]; then
        lock_count=$(echo "$stale_locks" | wc -l | tr -d ' ')
        echo "⚠️ Detected $lock_count stale lock file(s) in temp directory:"
        echo "$stale_locks" | head -5 | while read -r lock; do
            echo " - $(basename "$lock")"
        done
        if [ "$lock_count" -gt 5 ]; then
            echo " ... and $((lock_count - 5)) more"
        fi
        echo ""
        echo " These can cause 'invalid access' errors during build."
        echo ""

        if [ "$AUTO_CLEAN" = true ]; then
            should_clean=true
        else
            read -p "Remove stale lock files? [Y/n] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                should_clean=true
            fi
        fi

        if [ "$should_clean" = true ]; then
            echo "$stale_locks" | while read -r lock; do
                rm -f "$lock" 2>/dev/null || true
            done
            echo "✓ Stale lock files removed"
            echo ""
        else
            echo "⚠️ Continuing without removing locks. Build may fail."
            echo ""
        fi
    fi
fi

# Check for root-owned files in .build if not running as root
if [ -d ".build" ] && [ "$EUID" -ne 0 ]; then
    root_files=$(find .build -user root -print -quit 2>/dev/null || true)
    if [ -n "$root_files" ]; then
        echo "⚠️ Detected root-owned files in .build directory."
        echo " This will cause 'Permission denied' errors during compilation."
        echo ""
        read -p " Would you like to fix permissions using sudo? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo chown -R "$USER" .build
            echo "✓ Permissions fixed."
            echo ""
        else
            echo "⚠️ Continuing without fixing permissions. Build may fail."
            echo ""
        fi
    fi
fi

# Set configurable test ports to avoid conflicts with existing services
# Override these via environment variables if needed
export TEST_PORT_WORDPRESS="${TEST_PORT_WORDPRESS:-18080}"
export TEST_PORT_WEB="${TEST_PORT_WEB:-18081}"
export TEST_PORT_GATEWAY="${TEST_PORT_GATEWAY:-18082}"
export TEST_PORT_API="${TEST_PORT_API:-18083}"
export TEST_PORT_APP="${TEST_PORT_APP:-13000}"
export TEST_PORT_WEB2="${TEST_PORT_WEB2:-18084}"

echo "Test ports configured:"
echo "  WordPress: $TEST_PORT_WORDPRESS"
echo "  Web/Nginx: $TEST_PORT_WEB"
echo "  API Gateway: $TEST_PORT_GATEWAY"
echo "  API Service: $TEST_PORT_API"
echo "  App/Node.js: $TEST_PORT_APP"
echo "  Web Service 2: $TEST_PORT_WEB2"
echo ""

# Parse --auto-clean flag early (needed before prune step)
AUTO_CLEAN=false
EARLY_FILTERED_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--auto-clean" ]]; then
        AUTO_CLEAN=true
    else
        EARLY_FILTERED_ARGS+=("$arg")
    fi
done

# Prune leftover test containers from previous runs
prune_leftover_test_containers

# Check if we're in CI
if [ -n "$CI" ] || [ -n "$GITHUB_ACTIONS" ]; then
    echo "✓ Running in CI environment"
    echo "  Tests will run with existing privileges"
    echo ""
    swift test "$@"
    exit $?
fi

# Local development - check container runtime
echo "Local development environment detected"
echo ""

# Check for OCI_REGISTRY_URL (required for database tests)
if [ -z "$OCI_REGISTRY_URL" ]; then
    echo "⚠️ OCI_REGISTRY_URL environment variable is not set."
    echo ""
    echo "Database tests require an OCI container registry accessible via HTTPS."
    echo "Apple Container does not support HTTP for RFC1918 private IPs."
    echo ""
    echo "Examples:"
    echo " - OCI_REGISTRY_URL=registry.rossollc.com"
    echo " - OCI_REGISTRY_URL=ghcr.io"
    echo " - OCI_REGISTRY_URL=docker.io"
    echo ""

    # Prompt user for registry URL
    read -p "Enter OCI registry URL (or press Enter to skip database tests): " -r REGISTRY_INPUT

    if [ -n "$REGISTRY_INPUT" ]; then
        export OCI_REGISTRY_URL="$REGISTRY_INPUT"
        echo "✓ OCI_REGISTRY_URL set to: $OCI_REGISTRY_URL"
        echo ""
    else
        echo "⚠️ Skipping database tests (OCI_REGISTRY_URL not set)"
        echo ""
    fi
fi

# Check if container runtime is available
if ! command -v container &> /dev/null; then
    echo "⚠️ 'container' CLI not found in PATH"
    echo " Tests requiring container runtime will fail"
    echo ""
fi

# Check if we can run privileged tests
PRIVILEGED_TESTS=(
    "Test WordPress"
    "Test compose with complex dependency chain"
    "What goes up must come down"
    "Test stopped container"
    "Test container created with non-default"
)

echo "Tests requiring container runtime (privileged):"
for test in "${PRIVILEGED_TESTS[@]}"; do
    echo "  - $test"
done
echo ""

# Parse arguments for flags (filters out --auto-clean and --no-sudo)
FORCE_NO_SUDO=false
FILTERED_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--no-sudo" ]]; then
        FORCE_NO_SUDO=true
    elif [[ "$arg" == "--auto-clean" ]]; then
        true  # already handled above
    else
        FILTERED_ARGS+=("$arg")
    fi
done

# Check if already running as root/sudo
if [ "$EUID" -eq 0 ]; then
    echo "⚠️ ERROR: Running as root (EUID=0) is NOT supported."
    echo " Apple Container runtime rejects sudo/root access with 'unauthorized request'."
    echo ""
    echo "Please run WITHOUT sudo:"
    echo " ./run-tests.sh"
    echo ""
    exit 1
fi

# Prompt for sudo is disabled - Apple Container rejects root access
echo "NOTE: Apple Container runtime requires non-root user."
echo " Tests will run without sudo."
echo ""
if [ "$FORCE_NO_SUDO" = true ]; then
    echo "Running tests without sudo (requested via --no-sudo)..."
    echo ""
fi

swift test "${FILTERED_ARGS[@]}"
exit $?
