#!/bin/bash
# Run Container-Compose tests with proper privilege handling
# Usage: ./run-tests.sh [test-filter]

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

# Parse arguments for flags
FORCE_NO_SUDO=false
FILTERED_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--no-sudo" ]]; then
        FORCE_NO_SUDO=true
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
