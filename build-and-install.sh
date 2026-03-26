#!/bin/bash
# One-shot build and install script for container-compose
# Handles conda environment cleanup, xattr clearing, and installation
#
# Usage: ./build-and-install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Container-Compose Build & Install"
echo "=========================================="
echo ""

# Clear conda-injected compiler flags
unset CPPFLAGS CFLAGS CXXFLAGS LDFLAGS DEBUG_CFLAGS DEBUG_CXXFLAGS CMAKE_ARGS 2>/dev/null || true
unset CONDA_TOOLCHAIN_BUILD CONDA_TOOLCHAIN_HOST CONDA_DEFAULT_ENV 2>/dev/null || true
unset CC CXX CC_FOR_BUILD CXX_FOR_BUILD OBJC_FOR_BUILD 2>/dev/null || true
unset _CE_CONDA _CE_M CONDA_PREFIX CONDA_PROMPT_MODIFIER 2>/dev/null || true

# Remove miniconda from PATH
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'miniconda' | tr '\n' ':')"
export PATH="${PATH%:}"

BINARY_PATH=".build/arm64-apple-macosx/release/Container-Compose"
TARGET="$HOME/bin/container-compose"

# Build
echo "Building container-compose..."
swift build -c release

echo ""
echo "Build complete!"

# Verify binary exists
if [ ! -f "$BINARY_PATH" ]; then
  echo "Error: Binary not found at $BINARY_PATH"
  exit 1
fi

# Clear xattrs from built binary
echo ""
echo "Clearing extended attributes from built binary..."
if command -v xattr &>/dev/null; then
  xattr -c "$BINARY_PATH" 2>/dev/null || true
  echo "✓ Cleared xattrs from $BINARY_PATH"
fi

# Check if already installed - compare checksums
if [ -f "$TARGET" ]; then
  OLD_SUM=$(shasum -a 256 "$TARGET" 2>/dev/null | awk '{print $1}')
  NEW_SUM=$(shasum -a 256 "$BINARY_PATH" 2>/dev/null | awk '{print $1}')
  if [ "$OLD_SUM" = "$NEW_SUM" ]; then
    echo ""
    echo "Binary unchanged - no update needed"
    echo "Version: $($TARGET version 2>&1 | head -1)"
    exit 0
  fi
fi

# Install
echo ""
echo "Installing to $TARGET..."

# No sudo needed for home directory
SUDO=""

# Copy and set permissions
$SUDO cp "$BINARY_PATH" "$TARGET"
$SUDO chmod 755 "$TARGET"

# Apply ad-hoc code signature to prevent macOS from re-applying provenance
# macOS monitors /usr/local/bin and re-applies com.apple.provenance to unsigned binaries
echo "Applying ad-hoc code signature..."
if command -v codesign &>/dev/null; then
  $SUDO codesign --force --sign - "$TARGET" 2>/dev/null || true
fi

# Clean up any existing provenance attribute (ad-hoc sig prevents re-application)
if command -v xattr &>/dev/null; then
  $SUDO xattr -d com.apple.provenance "$TARGET" 2>/dev/null || true
fi

echo ""
echo "=========================================="
echo "✅ Installation complete!"
echo "=========================================="
echo ""
echo "Binary: $TARGET"
echo "Version: $($TARGET version 2>&1 | head -1)"
echo ""
echo "Test with:"
echo "  container-compose --help"
