#!/bin/bash
# One-shot build, sign, and install script for container-compose
# Handles conda env cleanup, xattr clearing, ad-hoc signing, and installation
#
# Usage: ./build-sign-install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Container-Compose Build, Sign & Install"
echo "=========================================="
echo ""

# Clean up any leftover test containers from previous runs
if command -v container &> /dev/null; then
 echo "Pruning leftover test containers..."
 TEST_CONTAINERS=$(container list --all 2>/dev/null | grep "CCT_" | awk '{print $1}' || true)
 if [ -n "$TEST_CONTAINERS" ]; then
 echo "$TEST_CONTAINERS" | while read -r container_id; do
 container stop "$container_id" 2>/dev/null || true
 container delete "$container_id" 2>/dev/null || true
 done
 echo "✓ Leftover test containers cleaned"
 else
 echo "✓ No leftover test containers"
 fi
fi

# Neutralize conda environment contamination (shared with run-tests.sh)
# This removes conda's codesign shim and restores Xcode's codesign
source "$SCRIPT_DIR/scripts/env-setup.sh"

# Report environment setup
[ -n "$_ENV_SETUP_SUMMARY" ] && echo "  Env: $_ENV_SETUP_SUMMARY"

BINARY_PATH=".build/arm64-apple-macosx/release/Container-Compose"
TARGET="$HOME/bin/container-compose"
SYSTEM_SYMLINK="/usr/local/bin/container-compose"

# Inject git commit hash into Application.swift
APPLICATION_FILE="Sources/Container-Compose/Application.swift"
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "Injecting git commit: $GIT_COMMIT"
perl -pi -e "s/BUILD_GIT_COMMIT/$GIT_COMMIT/" "$APPLICATION_FILE"

# Build
echo "Building container-compose..."
swift build -c release

# Restore placeholder so it's not accidentally committed
perl -pi -e "s/$GIT_COMMIT/BUILD_GIT_COMMIT/" "$APPLICATION_FILE"

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
  echo "  Cleared xattrs from $BINARY_PATH"
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
mkdir -p "$(dirname "$TARGET")"
cp "$BINARY_PATH" "$TARGET"
chmod 755 "$TARGET"

# Apply ad-hoc code signature (requires real Xcode codesign, not conda's shim)
# env-setup.sh above ensures conda's codesign shim is not in PATH
echo ""
echo "Signing binary..."
if command -v codesign &>/dev/null; then
  codesign --force --sign - "$TARGET" 2>/dev/null || {
    echo "Warning: codesign failed - container runtime may reject unsigned binary"
  }
else
  echo "Warning: codesign not found - container runtime may reject unsigned binary"
fi

# Clean up any existing provenance attribute (ad-hoc sig prevents re-application)
if command -v xattr &>/dev/null; then
  xattr -d com.apple.provenance "$TARGET" 2>/dev/null || true
fi

# Verify
echo ""
echo "Verifying installation..."
if [ -f "$TARGET" ]; then
  VERSION=$("$TARGET" version 2>&1 | head -1)
  echo "  Binary:  $TARGET"
  echo "  Version: $VERSION"
  if codesign -d "$TARGET" 2>/dev/null; then
    echo "  Signed:  yes"
  else
    echo "  Signed:  WARNING - unsigned (container runtime may reject)"
  fi
else
  echo "Error: Installation failed - binary not found at $TARGET"
  exit 1
fi

# Update system symlink so container runtime trusts the binary
# macOS security annotates locally-built binaries, but /usr/local/bin is trusted
BINARY_ABSOLUTE="$SCRIPT_DIR/$BINARY_PATH"
if [ -L "$SYSTEM_SYMLINK" ]; then
  echo ""
  echo "Updating system symlink..."
  sudo ln -sf "$BINARY_ABSOLUTE" "$SYSTEM_SYMLINK"
  echo "  $SYSTEM_SYMLINK -> $BINARY_PATH"
elif [ -f "$SYSTEM_SYMLINK" ]; then
  echo ""
  echo "Warning: $SYSTEM_SYMLINK exists but is not a symlink (skip or back it up manually)"
else
  echo ""
  echo "Creating system symlink (requires sudo)..."
  sudo ln -sf "$BINARY_ABSOLUTE" "$SYSTEM_SYMLINK"
  echo "  $SYSTEM_SYMLINK -> $BINARY_PATH"
fi

echo ""
echo "=========================================="
echo "Done!"
echo "=========================================="

# Final cleanup of any test containers created during build
if command -v container &> /dev/null; then
 TEST_CONTAINERS=$(container list --all 2>/dev/null | grep "CCT_" | awk '{print $1}' || true)
 if [ -n "$TEST_CONTAINERS" ]; then
 echo ""
 echo "Final cleanup of test containers..."
 echo "$TEST_CONTAINERS" | while read -r container_id; do
 container stop "$container_id" 2>/dev/null || true
 container delete "$container_id" 2>/dev/null || true
 done
 echo "✓ Test containers cleaned"
 fi
fi
