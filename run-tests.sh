#!/bin/bash
# Run Container-Compose tests with proper privilege handling
# Usage: ./run-tests.sh [test-filter]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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

# Check if already running as root/sudo
if [ "$EUID" -eq 0 ]; then
    echo "✓ Already running with sudo"
    echo ""
    swift test "$@"
    exit $?
fi

# Prompt for sudo
echo "These tests require sudo privileges to:"
echo "  - Install kernel extensions (--enable-kernel-install)"
echo "  - Create container volumes"
echo "  - Start container runtime"
echo ""
echo "Options:"
echo ""
echo "1. Run with sudo (privileged tests):"
echo "   ./run-tests.sh"
echo ""
echo "2. Run unit tests only (no sudo needed):"
echo "   swift test --filter StaticTests"
echo ""
echo "3. Run specific test:"
echo "   swift test --filter 'Parse compose'"
echo ""

read -p "Run with sudo? [y/N] " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Running unit tests only (no sudo)..."
    echo ""
    swift test --filter StaticTests "$@"
    exit $?
fi

# Re-run with sudo
echo "Requesting sudo privileges..."
echo ""

# Preserve environment for Swift
exec sudo -E env "PATH=$PATH" "HOME=$HOME" "$0" "$@"
