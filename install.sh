#!/bin/bash
# Install container-compose v0.10.1 to /usr/local/bin
# Usage: sudo ./install.sh

set -e

NEW_BINARY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.build/release/container-compose"
TARGET="/usr/local/bin/container-compose"

echo "Installing container-compose v0.10.1..."

# Check new binary exists
if [ ! -f "$NEW_BINARY" ]; then
    echo "Error: Build the binary first with: ./build-release.sh"
    exit 1
fi

# Check sudo needed
if [ ! -w "/usr/local/bin" ] && [ "$EUID" -ne 0 ]; then
    echo "Error: Run with sudo: sudo ./install.sh"
    exit 1
fi

# Install
cp "$NEW_BINARY" "$TARGET"
chmod 755 "$TARGET"

echo "✓ Installed: $TARGET"
echo "  Version: $($TARGET version 2>&1 | head -1)"

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
