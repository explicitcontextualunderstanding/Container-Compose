#!/bin/bash
# Install container-compose to /usr/local/bin
# Usage: sudo ./install.sh
#
# This script installs the built binary from .build/release/container-compose

set -e

NEW_BINARY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.build/release/container-compose"
TARGET="/usr/local/bin/container-compose"

# Get version from binary
VERSION="unknown"
if [ -f "$NEW_BINARY" ]; then
  VERSION="$($NEW_BINARY version 2>&1 | head -1)"
fi

echo "Installing container-compose..."

# Check new binary exists
if [ ! -f "$NEW_BINARY" ]; then
  echo "Error: Build the binary first with: ./build-release.sh"
  exit 1
fi

# Check for and clear macOS extended attributes that cause SIGUSR1 traps
if command -v xattr &>/dev/null; then
  if xattr "$NEW_BINARY" 2>/dev/null | grep -q "com.apple.provenance"; then
    echo "Clearing provenance from source binary (causes SIGUSR1 crashes)..."
    xattr -c "$NEW_BINARY"
  fi
fi

# Check sudo needed for symlink creation in /usr/local/bin
if [ ! -w "/usr/local/bin" ] && [ "$EUID" -ne 0 ]; then
  echo "Error: Run with sudo: sudo ./install.sh"
  exit 1
fi

# Install via symlink to avoid macOS provenance monitoring
# Symlinks in /usr/local/bin don't get com.apple.provenance attributes
# The binary stays in .build/release/ where macOS doesn't monitor
TARGET="/usr/local/bin/container-compose"

# Remove old binary/symlink if exists
if [ -e "$TARGET" ]; then
  rm -f "$TARGET"
fi

# Create symlink to built binary
ln -sf "$NEW_BINARY" "$TARGET"

echo "✓ Created symlink: $TARGET -> $NEW_BINARY"

echo "✓ Installed: $TARGET"
echo " Version: $($TARGET version 2>&1 | head -1)"

# Verify SINGLE binary
echo ""
echo "Checking for duplicate binaries..."
FOUND=$(find /usr/local/bin /opt/homebrew/bin ~/bin ~/.local/bin -name "container-compose" -type f 2>/dev/null | wc -l | tr -d ' ')

if [ "$FOUND" -eq 1 ]; then
    echo "✓ Only one binary found: $(which container-compose)"
elif [ "$FOUND" -gt 1 ]; then
    echo "⚠️  Found $FOUND binaries:"
    find /usr/local/bin /opt/homebrew/bin ~/bin ~/.local/bin -name "container-compose" -type f 2>/dev/null
    echo ""
    echo "Remove extras manually:"
    echo '  rm ~/bin/container-compose 2>/dev/null || true'
else
    echo "✗ Binary not found in expected locations"
fi
