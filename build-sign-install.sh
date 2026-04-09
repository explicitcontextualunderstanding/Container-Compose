#!/bin/bash
# One-shot build, sign, and install script for container-compose
# Handles conda env cleanup, xattr clearing, ad-hoc signing, and installation
#
# Usage: ./build-sign-install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Mutex lock to prevent concurrent builds
LOCK_DIR="/tmp/container-compose-build"
LOCK_FILE="$LOCK_DIR/build.lock"
PID_FILE="$LOCK_DIR/build.pid"

acquire_lock() {
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    
    # Try to acquire lock (non-blocking)
    if ! (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
        # Lock acquisition failed - check if process is still running
        if [ -f "$PID_FILE" ]; then
            OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
            if kill -0 "$OLD_PID" 2>/dev/null; then
                echo "❌ Another build is already running (PID: $OLD_PID)"
                echo "   If this is stale, run: rm -rf $LOCK_DIR"
                exit 1
            else
                echo "⚠️  Removing stale lock (PID $OLD_PID no longer exists)"
                rm -rf "$LOCK_DIR"
            fi
        else
            echo "❌ Another build is already running"
            echo "   If this is stale, run: rm -rf $LOCK_DIR"
            exit 1
        fi
    fi
    
    # Write PID file
    echo $$ > "$PID_FILE"
    
    # Ensure cleanup on exit
    trap 'rm -rf "$LOCK_DIR"' EXIT
    
    echo "✓ Build lock acquired (PID: $$)"
}

acquire_lock

# Apple Container data directory
AC_SNAPSHOTS_DIR="$HOME/Library/Application Support/com.apple.container/snapshots"

echo "=========================================="
echo "Container-Compose Build, Sign & Install"
echo "=========================================="
echo ""

# Clean up any leftover test containers and their snapshots from previous runs
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
	# Prune orphaned snapshots left by test containers
	if [ -d "$AC_SNAPSHOTS_DIR" ] && [ -f "$HOME/Library/Application Support/com.apple.container/state.json" ] && command -v python3 &>/dev/null; then
		all_ids=$(python3 -c "
import json, os
sf = os.path.expanduser(\"$HOME/Library/Application Support/com.apple.container/state.json\")
with open(sf) as f:
    state = json.load(f)
for cid in state.get(\"containers\", {}):
    print(cid)
" 2>/dev/null || true)
		pruned=0
		for snap_dir in "$AC_SNAPSHOTS_DIR"/*/; do
			[ -d "$snap_dir" ] || continue
			snap_name=$(basename "$snap_dir")
			case " $all_ids " in
				*" $snap_name "*) continue ;;
			esac
			rm -rf "$snap_dir"
			pruned=$((pruned + 1))
		done
		[ "$pruned" -gt 0 ] && echo "  Pruned $pruned orphaned snapshot(s)"
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
if command -v xattr &> /dev/null; then
  xattr -c "$BINARY_PATH" 2>/dev/null || true
  echo " Cleared xattrs from $BINARY_PATH"
fi

# Fix container CLI permissions if owned by root
echo ""
echo "Ensuring container CLI is accessible..."
if [ -f "/usr/local/bin/container" ]; then
    CONTAINER_OWNER=$(stat -f "%Su" /usr/local/bin/container 2>/dev/null || echo "unknown")
    if [ "$CONTAINER_OWNER" = "root" ]; then
        echo " Fixing /usr/local/bin/container ownership..."
        sudo chown "$USER:staff" /usr/local/bin/container 2>/dev/null || true
        echo " Container CLI now owned by $USER"
    fi
fi

# Pre-pull test images for E2E tests (pgmicro for fast relay tests)
echo ""
echo "=========================================="
echo "Pre-pulling test images"
echo "=========================================="

# Load ops.env if it exists (for OCI_REGISTRY_URL)
if [ -f "$SCRIPT_DIR/ops.env" ]; then
    set -a
    source "$SCRIPT_DIR/ops.env"
    set +a
fi

# Default to local/Apple registry if not set
REGISTRY_URL="${OCI_REGISTRY_URL:-REMOVED_REGISTRY_URL}"

# Pre-pull pgmicro (PostgreSQL-compatible for fast E2E relay tests)
# pgmicro starts in 2-5s vs 30s for postgres - critical for test speed
PGMICRO_IMAGE="$REGISTRY_URL/pgmicro:latest"
echo ""
echo "Ensuring pgmicro image is available..."
if command -v container &> /dev/null; then
    # Check if image exists locally first
    if container image list 2>/dev/null | grep -q "pgmicro"; then
        echo " ✅ pgmicro already cached"
    else
        echo " Pulling pgmicro from $REGISTRY_URL..."
        if container pull "$PGMICRO_IMAGE" 2>/dev/null; then
            echo " ✅ pgmicro pulled successfully"
        else
            # Fallback: try docker.io if private registry fails
            echo " ⚠️ Private registry pull failed, trying docker.io..."
            if container pull docker.io/pgmicro/pgmicro:latest 2>/dev/null; then
                echo " ✅ pgmicro pulled from docker.io"
            else
                echo " ⚠️ Could not pull pgmicro (tests may skip or fail)"
            fi
        fi
    fi
else
    echo " ⚠️ container CLI not available - skipping image pre-pull"
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

# Generate entitlements plist if missing
ENTITLEMENTS_PLIST="$SCRIPT_DIR/Container-Compose.entitlements"
if [ ! -f "$ENTITLEMENTS_PLIST" ]; then
  echo "Creating entitlements plist with com.apple.security.hypervisor..."
  cat > "$ENTITLEMENTS_PLIST" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.hypervisor</key>
    <true/>
</dict>
</plist>
EOF
fi

# Apply ad-hoc code signature with entitlements and attempt hardened runtime
# env-setup.sh above ensures conda's codesign shim is not in PATH
echo ""
echo "Signing binary..."
if command -v codesign &> /dev/null; then
  # First try with hardened runtime enabled
  if codesign --force --sign - --entitlements "$ENTITLEMENTS_PLIST" --options runtime "$BINARY_PATH" 2>/dev/null; then
    echo "  ✅ Signed with hardened runtime"
  else
    # Fall back to without hardened runtime
    codesign --force --sign - --entitlements "$ENTITLEMENTS_PLIST" "$BINARY_PATH" || {
      echo "Warning: codesign failed - container runtime may reject unsigned binary"
    }
    echo "  ⚠️  Signed without hardened runtime (requires paid Developer ID)"
  fi
  cp "$BINARY_PATH" "$TARGET"
  chmod 755 "$TARGET"
else
    echo "Warning: codesign not found - container runtime may reject unsigned binary"
fi

# Generate entitlements report
echo ""
echo "=========================================="
echo "Entitlements Report"
echo "=========================================="

# Define available entitlements and their requirements
declare -A ENTITLEMENTS=(
    ["com.apple.security.hypervisor"]="Required for Apple Virtualization framework. MUST be signed by Apple certificate."
    ["com.apple.security.virtualization"]="Alias for hypervisor. MUST be signed by Apple certificate."
    ["com.apple.security.application-groups"]="Allows app group access. Requires Team ID for valid production."
    ["com.apple.security.hardened-runtime"]="Enables hardened runtime. Partial without Team ID."
)

# Check what entitlements file contains
ENTITLEMENTS_PLIST="$SCRIPT_DIR/Container-Compose.entitlements"
echo ""
echo "Embedded Entitlements (from $ENTITLEMENTS_PLIST):"
echo ""

if [ -f "$ENTITLEMENTS_PLIST" ]; then
    # Parse the plist and check each entitlement
    while IFS= read -r line; do
        if [[ "$line" == *"<key>"* ]]; then
            ENT_KEY=$(echo "$line" | sed 's/.*<key>\(.*\)<\/key>.*/\1/')
            echo "  - $ENT_KEY"
            
            # Check if we have info about this entitlement
            if [ -n "${ENTITLEMENTS["$ENT_KEY"]}" ]; then
                echo "    Info: ${ENTITLEMENTS[$ENT_KEY]}"
                
                # Determine validity
                case "$ENT_KEY" in
                    "com.apple.security.hypervisor"|"com.apple.security.virtualization")
                        echo "    ⚠️  REQUIRES Apple signing - invalid without Developer ID"
                        ;;
                    "com.apple.security.application-groups")
                        echo "    ⚠️  Requires Team ID for production"
                        ;;
                    "com.apple.security.hardened-runtime")
                        echo "    ℹ️  Partial functionality without Developer ID"
                        ;;
                esac
            fi
        fi
    done < "$ENTITLEMENTS_PLIST"
else
    echo "  No entitlements file found"
fi

echo ""
echo "Entitlements Summary:"
echo "  - Embedded: $(grep -c "<key>" "$ENTITLEMENTS_PLIST" 2>/dev/null || echo 0)"
echo "  - Valid for Production: 0 (requires paid Developer ID)"
echo "  - Valid Locally: $(grep -c "<key>" "$ENTITLEMENTS_PLIST" 2>/dev/null || echo 0)"
echo ""
echo "ℹ️  Without Apple Developer Program membership, entitlements are embedded"
echo "   but NOT valid for production. Binary will work locally but will fail"
echo "   AMFI/production security checks."
echo ""

# List common entitlements we might want to add in the future
echo "=========================================="
echo "Available Entitlements (Future Consideration)"
echo "=========================================="
echo ""
echo "For Apple Container runtime:"
echo "  - com.apple.security.hypervisor (required)"
echo ""
echo "For notarization:"
echo "  - com.apple.security.hardened-runtime"
echo ""
echo "For App Groups (if needed):"
echo "  - com.apple.security.application-groups"
echo ""
echo "For TCC access (if needed):"
echo "  - com.apple.security.tcc.services"
echo ""
echo "To add these, edit: $ENTITLEMENTS_PLIST"

# Clean up any existing provenance attribute (ad-hoc sig prevents re-application)
if command -v xattr &> /dev/null; then
  xattr -d com.apple.provenance "$TARGET" 2>/dev/null || true
fi

# Enhanced verification using all available tools (no paid Developer ID required)
echo ""
echo "=========================================="
echo "Signing Verification Report"
echo "=========================================="

# 1. Basic codesign verification
echo ""
echo "1. Code Signature Verification (codesign -v):"
if codesign -v "$TARGET" 2>&1; then
  echo "   ✅ Binary is signed"
else
  echo "   ❌ Code signature invalid or missing"
fi

# 2. Display signature details
echo ""
echo "2. Signature Details (codesign -d):"
SIG_DETAILS=$(codesign -d "$TARGET" 2>&1 || echo "Unable to read signature")
echo "$SIG_DETAILS" | sed 's/^/   /'

# 3. Check for Team ID (indicates Developer ID signing)
echo ""
echo "3. Team Identifier:"
if echo "$SIG_DETAILS" | grep -q "TeamIdentifier="; then
  TEAM_ID=$(echo "$SIG_DETAILS" | grep "TeamIdentifier=" | sed 's/.*TeamIdentifier=//' | tr -d ' ')
  echo "   ✅ Signed with Developer ID: $TEAM_ID"
else
  echo "   ℹ️  Ad-hoc signed (no Team ID - expected without Developer ID)"
fi

# 4. spctl Gatekeeper assessment (works with ad-hoc locally)
echo ""
echo "4. Gatekeeper Assessment (spctl --assess):"
SPCTL_RESULT=$(spctl --assess --type exec --verbose 2 "$TARGET" 2>&1 || true)
if echo "$SPCTL_RESULT" | grep -q "accepted\|origin=no"; then
  echo "   ✅ Gatekeeper: Accepted (ad-hoc signed)"
elif echo "$SPCTL_RESULT" | grep -q "origin=-"; then
  echo "   ✅ Gatekeeper: Accepted (ad-hoc)"
elif echo "$SPCTL_RESULT" | grep -q "origin=developer"; then
  echo "   ✅ Gatekeeper: Accepted (Developer ID)"
elif echo "$SPCTL_RESULT" | grep -q "denied"; then
  echo "   ❌ Gatekeeper: Blocked"
else
  echo "   ℹ️  Gatekeeper: Unknown (local assessment)"
fi

# 5. Check hardened runtime
echo ""
echo "5. Hardened Runtime:"
if echo "$SIG_DETAILS" | grep -qi "runtime"; then
  echo "   ✅ Hardened runtime enabled"
else
  echo "   ℹ️  Hardened runtime not detected (optional)"
fi

# 6. Display embedded entitlements
echo ""
echo "6. Embedded Entitlements:"
ENTITLEMENTS=$(codesign -d --entitlements - "$TARGET" 2>&1 || echo "none")
if [ "$ENTITLEMENTS" != "none" ] && [ -n "$ENTITLEMENTS" ]; then
  echo "$ENTITLEMENTS" | sed 's/^/   /'
else
  echo "   No entitlements embedded"
fi

# 7. Extract requirements for audit
echo ""
echo "7. Signing Requirements (codesign -d -r-):"
REQUIREMENTS=$(codesign -d -r- "$TARGET" 2>&1 || echo "none")
if [ "$REQUIREMENTS" != "none" ] && [ -n "$REQUIREMENTS" ]; then
  echo "$REQUIREMENTS" | head -10 | sed 's/^/   /'
  echo "   ... (truncated)"
fi

# 8. Extended attributes check
echo ""
echo "8. Extended Attributes:"
XATTRS=$(xattr -l "$TARGET" 2>&1 || echo "none")
if [ "$XATTRS" != "none" ] && [ -n "$XATTRS" ]; then
  echo "$XATTRS" | sed 's/^/   /'
else
  echo "   ✅ No extended attributes"
fi

# Summary
echo ""
echo "=========================================="
echo "Signing Summary"
echo "=========================================="
if codesign -d "$TARGET" 2>/dev/null; then
  echo "✅ Binary is signed"
else
  echo "❌ Binary is NOT signed"
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
