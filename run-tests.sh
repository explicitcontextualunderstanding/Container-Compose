#!/bin/bash
# Run Container-Compose tests with proper privilege handling
# Usage: ./run-tests.sh [--auto-clean] [--no-sudo] [test-filter]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Cleanup function - removes only test containers created by this run
cleanup_test_containers() {
    local exit_code=$?
    echo ""
    echo "=========================================="
    echo "Cleaning up test containers..."
    echo "=========================================="
    
    # Find and remove only containers created by our tests (Container-Compose_Tests_*)
    if command -v container &> /dev/null; then
        local test_containers
        test_containers=$(container list 2>/dev/null | grep "Container-Compose_Tests_" | awk '{print $1}' || true)
        
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

    local test_containers
    test_containers=$(container list 2>/dev/null | grep "Container-Compose_Tests_" | awk '{print $1}' || true)

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

# Clear ALL conda-injected compiler flags and variables
unset CPPFLAGS CFLAGS CXXFLAGS LDFLAGS DEBUG_CFLAGS DEBUG_CXXFLAGS CMAKE_ARGS 2>/dev/null || true
unset CONDA_TOOLCHAIN_BUILD CONDA_TOOLCHAIN_HOST CONDA_DEFAULT_ENV 2>/dev/null || true
unset CC CXX CC_FOR_BUILD CXX_FOR_BUILD OBJC_FOR_BUILD 2>/dev/null || true
unset _CE_CONDA _CE_M CONDA_PREFIX CONDA_PROMPT_MODIFIER 2>/dev/null || true

# Remove miniconda from PATH
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'miniconda' | tr '\n' ':')"
export PATH="${PATH%:}"

# Check for root-owned files in .build if not running as root
if [ -d ".build" ] && [ "$EUID" -ne 0 ]; then
    root_files=$(find .build -user root -print -quit 2>/dev/null || true)
    if [ -n "$root_files" ]; then
        echo "⚠️  Detected root-owned files in .build directory."
        echo "   This will cause 'Permission denied' errors during compilation."
        echo ""
        read -p "   Would you like to fix permissions using sudo? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo chown -R "$USER" .build
            echo "✓ Permissions fixed."
            echo ""
        else
            echo "⚠️  Continuing without fixing permissions. Build may fail."
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

# Check if container runtime is available
if ! command -v container &> /dev/null; then
    echo "⚠️  'container' CLI not found in PATH"
    echo "   Tests requiring container runtime will fail"
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
    echo "✓ Already running with sudo"
    echo ""
    swift test "${FILTERED_ARGS[@]}"
    exit $?
fi

# Not root - check if we should skip sudo
if [ "$FORCE_NO_SUDO" = true ]; then
    echo "Running tests without sudo (requested via --no-sudo)..."
    echo ""
    swift test "${FILTERED_ARGS[@]}"
    exit $?
fi

# Prompt for sudo if not forced no-sudo
echo "These tests requiring container runtime (privileged) typically require sudo to:"
echo "  - Install kernel extensions (--enable-kernel-install)"
echo "  - Create container volumes"
echo "  - Start container runtime"
echo ""

read -p "Run with sudo? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Attempting to run tests without sudo..."
    echo ""
    swift test "${FILTERED_ARGS[@]}"
    exit $?
fi

# Re-run with sudo
echo "Requesting sudo privileges..."
echo ""
exec sudo -E env "PATH=$PATH" "HOME=$HOME" "$0" "${FILTERED_ARGS[@]}"
