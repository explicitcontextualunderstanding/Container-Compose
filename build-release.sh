#!/bin/bash
# Build script for container-compose that ensures clean environment
# This script clears conda-injected compiler flags that conflict with Xcode SDK
#
# Usage: ./build-release.sh [swift-build-args]
# Example: ./build-release.sh
#          ./build-release.sh -c release
#          ./build-release.sh -c debug --target ContainerCompose

set -e

echo "=========================================="
echo "Container-Compose Release Build"
echo "=========================================="
echo ""

# Detect if conda flags are present
if [[ -n "$CPPFLAGS" ]] || [[ -n "$CXXFLAGS" ]] || [[ -n "$CMAKE_ARGS" ]]; then
    echo "⚠️  Detected conda-injected compiler flags"
    echo "   Clearing them to ensure compatibility with Xcode SDK..."
    echo ""
fi

# Clear ALL conda-injected compiler flags and variables
unset CPPFLAGS CFLAGS CXXFLAGS LDFLAGS DEBUG_CFLAGS DEBUG_CXXFLAGS CMAKE_ARGS 2>/dev/null || true
unset CONDA_TOOLCHAIN_BUILD CONDA_TOOLCHAIN_HOST CONDA_DEFAULT_ENV 2>/dev/null || true
unset CC CXX CC_FOR_BUILD CXX_FOR_BUILD OBJC_FOR_BUILD 2>/dev/null || true
unset _CE_CONDA _CE_M CONDA_PREFIX CONDA_PROMPT_MODIFIER 2>/dev/null || true

# Remove miniconda from PATH to prevent using its clang
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'miniconda' | tr '\n' ':')"
export PATH="${PATH%:}"  # Remove trailing colon if any

echo "Environment after cleanup:"
echo "  CPPFLAGS: ${CPPFLAGS:-<not set>}"
echo "  CXXFLAGS: ${CXXFLAGS:-<not set>}"
echo "  CFLAGS: ${CFLAGS:-<not set>}"
echo "  LDFLAGS: ${LDFLAGS:-<not set>}"
echo "  CC: ${CC:-<not set>}"
echo "  CXX: ${CXX:-<not set>}"
echo "  PATH: $(echo "$PATH" | tr ':' '\n' | head -5 | tr '\n' ':')..."
echo ""

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Default to release build if no configuration specified
if [[ "$*" == *"-c"* ]] || [[ "$*" == *"--configuration"* ]]; then
    BUILD_ARGS="$@"
else
    BUILD_ARGS="-c release $@"
fi

echo "Building with: swift build $BUILD_ARGS"
echo ""

# Build
swift build $BUILD_ARGS

BUILD_STATUS=$?

if [ $BUILD_STATUS -eq 0 ]; then
  echo ""
  echo "=========================================="
  echo "✅ Build successful!"
  echo "=========================================="
  echo ""
  echo "Binary location:"
  BINARY_PATH=".build/release/container-compose"
  if [ ! -f "$BINARY_PATH" ]; then
    BINARY_PATH=".build/debug/container-compose"
  fi
  ls -lh "$BINARY_PATH" 2>/dev/null

  # Remove macOS provenance attributes that can cause runtime traps
  if command -v xattr &>/dev/null; then
    if xattr "$BINARY_PATH" 2>/dev/null | grep -q "com.apple.provenance"; then
      echo ""
      echo "Removing macOS provenance attributes..."
      xattr -d com.apple.provenance "$BINARY_PATH" 2>/dev/null || true
    fi
  fi

  echo ""
  echo "To install system-wide:"
  echo " sudo cp .build/release/container-compose /usr/local/bin/"
else
    echo ""
    echo "=========================================="
    echo "❌ Build failed with exit code $BUILD_STATUS"
    echo "=========================================="
    exit $BUILD_STATUS
fi
