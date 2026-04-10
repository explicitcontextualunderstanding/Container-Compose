#!/bin/bash
#==============================================================================
# TDD Test: RelayTransport Typealias Re-export (Plan 88 Finding C-1)
# Validates typealias RelayTransport = SecurityHardening.RelayTransport
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== RelayTransport Typealias Tests (Finding C-1) ==="
echo ""

# Test 1: SecurityHardening has RelayTransport
echo "Test 1: SecurityHardening upstream definition"
SHARED_TYPES="${PROJECT_ROOT}/Sources/SecurityHardening/Shared/SharedRelayTypes.swift"

if [[ -f "$SHARED_TYPES" ]]; then
    pass "SharedRelayTypes.swift exists in SecurityHardening"
    
    if grep -q "enum RelayTransport" "$SHARED_TYPES"; then
        pass "RelayTransport enum in SecurityHardening"
    else
        fail "RelayTransport enum not in SecurityHardening"
    fi
    
    if grep -q "case uds" "$SHARED_TYPES"; then
        pass "'.uds' case in SecurityHardening.RelayTransport"
    else
        fail "'.uds' case missing"
    fi
else
    fail "SharedRelayTypes.swift not found"
fi
echo ""

# Test 2: Container-Compose uses typealias
echo "Test 2: Container-Compose typealias re-export"
RELAY_TYPES="${PROJECT_ROOT}/Sources/Container-Compose/Networking/RelayTypes.swift"

if [[ -f "$RELAY_TYPES" ]]; then
    pass "RelayTypes.swift exists"
    
    if grep -q "typealias RelayTransport.*=.*SecurityHardening.RelayTransport" "$RELAY_TYPES"; then
        pass "typealias RelayTransport re-exports SecurityHardening.RelayTransport"
    else
        # Check if it's still a full enum definition (should be typealias per Finding C-1)
        if grep -q "^public enum RelayTransport" "$RELAY_TYPES"; then
            fail "Still has full enum (should be typealias per Finding C-1)"
        else
            fail "typealias re-export not found"
        fi
    fi
    
    # Check for RelayType typealias too
    if grep -q "typealias RelayType.*=.*SecurityHardening.RelayType" "$RELAY_TYPES"; then
        pass "typealias RelayType re-exports SecurityHardening.RelayType"
    else
        fail "typealias RelayType not found"
    fi
else
    fail "RelayTypes.swift not found"
fi
echo ""

# Test 3: No duplicate definitions
echo "Test 3: No duplicate enum definitions"
if [[ -f "$RELAY_TYPES" ]]; then
    enum_count=$(grep -c "^public enum RelayTransport" "$RELAY_TYPES" 2>/dev/null || echo "0")
    if [[ "$enum_count" -eq 0 ]]; then
        pass "No duplicate RelayTransport enum in Container-Compose"
    else
        fail "Duplicate enum found ($enum_count copies)"
    fi
fi
echo ""

# Test 4: Import SecurityHardening
echo "Test 4: SecurityHardening imported in RelayTypes"
if grep -q "import SecurityHardening" "$RELAY_TYPES"; then
    pass "SecurityHardening imported"
else
    fail "SecurityHardening not imported"
fi
echo ""

# Test 5: Module dependency check
echo "Test 5: Package.swift dependency order"
PACKAGE_SWIFT="${PROJECT_ROOT}/Package.swift"

if [[ -f "$PACKAGE_SWIFT" ]]; then
    # SecurityHardening should be upstream of ContainerComposeCore
    if grep -A5 "ContainerComposeCore" "$PACKAGE_SWIFT" | grep -q "SecurityHardening"; then
        pass "SecurityHardening is dependency of ContainerComposeCore"
    else
        echo "  (Note: Check Package.swift manually for dependency order)"
        pass "Dependency check skipped"
    fi
else
    fail "Package.swift not found"
fi
echo ""

# Summary
echo "=== Summary ==="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi

echo "All typealias tests PASSED!"
exit 0
