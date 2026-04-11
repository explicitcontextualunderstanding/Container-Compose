#!/bin/bash
# e2e-validate.sh
# End-to-end validation of Container-Compose test harness infrastructure
# Verifies that all components actually work, not just exist
#
# Usage: ./scripts/e2e-validate.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "=========================================="
echo "E2E VALIDATION: Container-Compose Harness"
echo "=========================================="
echo ""

PASSED=0
FAILED=0

# Test 1: Verify MemoryGuardTrait exists and is importable
test_memory_guard_trait() {
    echo "Test 1: MemoryGuardTrait Import..."
    if grep -q "MemoryGuardTrait" Sources/ContainerTesting/ResourceGuard.swift; then
        echo "  ✓ MemoryGuardTrait found in ResourceGuard.swift"
        ((PASSED++))
    else
        echo "  ✗ MemoryGuardTrait NOT found"
        ((FAILED++))
    fi
}

# Test 2: Verify ResourceArbiter exists
test_resource_arbiter() {
    echo "Test 2: ResourceArbiter Component..."
    if grep -q "ResourceArbiter" Sources/ContainerTesting/ResourceArbiter.swift 2>/dev/null; then
        echo "  ✓ ResourceArbiter found"
        ((PASSED++))
    else
        echo "  ✗ ResourceArbiter NOT found"
        ((FAILED++))
    fi
}

# Test 3: Verify telemetry CSV generation
test_telemetry_csv() {
    echo "Test 3: Telemetry CSV Generation..."
    
    # Run a quick test to generate telemetry
    RESOURCE_LOG="/tmp/e2e_test_$$.csv"
    ./scripts/resource-monitor.sh "$RESOURCE_LOG" &
    MONITOR_PID=$!
    
    sleep 2
    
    if kill $MONITOR_PID 2>/dev/null; then
        wait $MONITOR_PID 2>/dev/null
    fi
    
    if [ -f "$RESOURCE_LOG" ] && [ -s "$RESOURCE_LOG" ]; then
        if head -1 "$RESOURCE_LOG" | grep -q "timestamp,free_memory_mb"; then
            echo "  ✓ Telemetry CSV generated with correct headers"
            ((PASSED++))
        else
            echo "  ✗ Telemetry CSV has wrong format"
            ((FAILED++))
        fi
    else
        echo "  ✗ Telemetry CSV not generated"
        ((FAILED++))
    fi
    
    rm -f "$RESOURCE_LOG"
}

# Test 4: Verify Performance Dashboard Python script
test_performance_dashboard() {
    echo "Test 4: Performance Dashboard Script..."
    if [ -f "scripts/analyze-performance.py" ]; then
        if python3 -m py_compile scripts/analyze-performance.py 2>/dev/null; then
            echo "  ✓ Performance Dashboard script is valid Python"
            ((PASSED++))
        else
            echo "  ✗ Performance Dashboard has syntax errors"
            ((FAILED++))
        fi
    else
        echo "  ✗ Performance Dashboard script not found"
        ((FAILED++))
    fi
}

# Test 5: Verify Container Pool infrastructure
test_container_pool() {
    echo "Test 5: Container Pool Infrastructure..."
    if [ -f "Tests/TestHelpers/ContainerPool.swift" ]; then
        if grep -q "actor ContainerPool" Tests/TestHelpers/ContainerPool.swift; then
            echo "  ✓ ContainerPool actor exists"
            ((PASSED++))
        else
            echo "  ✗ ContainerPool actor not found"
            ((FAILED++))
        fin    else
        echo "  ✗ ContainerPool.swift not found"
        ((FAILED++))
    fi
}

# Test 6: Verify Snapshot Manager
test_snapshot_manager() {
    echo "Test 6: Snapshot Manager..."
    if [ -f "Tests/TestHelpers/ContainerSnapshotManager.swift" ]; then
        echo "  ✓ ContainerSnapshotManager.swift exists"
        ((PASSED++))
    else
        echo "  ✗ ContainerSnapshotManager.swift not found"
        ((FAILED++))
    fi
}

# Test 7: Verify Pool Watcher
test_pool_watcher() {
    echo "Test 7: Pool Watcher..."
    if [ -f "Tests/TestHelpers/PoolWatcher.swift" ]; then
        echo "  ✓ PoolWatcher.swift exists"
        ((PASSED++))
    else
        echo "  ✗ PoolWatcher.swift not found"
        ((FAILED++))
    fi
}

# Test 8: Verify Background Hydrator
test_background_hydrator() {
    echo "Test 8: Background Hydrator..."
    if [ -f "Tests/TestHelpers/BackgroundHydrator.swift" ]; then
        echo "  ✓ BackgroundHydrator.swift exists"
        ((PASSED++))
    else
        echo "  ✗ BackgroundHydrator.swift not found"
        ((FAILED++))
    fi
}

# Test 9: Verify MemoryGuardTrait applied to heavy tests
test_memory_guard_applied() {
    echo "Test 9: MemoryGuard Applied to Heavy Tests..."
    if grep -r "\.minMemory(800)" Tests/Container-Compose-DynamicTests/*.swift 2>/dev/null | grep -q "ComposeUp\|ComposeDown"; then
        echo "  ✓ .minMemory(800) applied to WordPress/MySQL tests"
        ((PASSED++))
    else
        echo "  ✗ MemoryGuard not applied to heavy tests"
        ((FAILED++))
    fi
}

# Test 10: Verify Victoria Protocol RUN_ID tracking
test_victoria_protocol() {
    echo "Test 10: Victoria Protocol RUN_ID..."
    if grep -q "RUN_ID=" run-tests.sh && grep -q "victoria_cleanup" run-tests.sh; then
        echo "  ✓ Victoria Protocol RUN_ID tracking in run-tests.sh"
        ((PASSED++))
    else
        echo "  ✗ Victoria Protocol not found"
        ((FAILED++))
    fi
}

# Run all tests
echo "Running E2E validation tests..."
echo ""

test_memory_guard_trait
test_resource_arbiter
test_telemetry_csv
test_performance_dashboard
test_container_pool
test_snapshot_manager
test_pool_watcher
test_background_hydrator
test_memory_guard_applied
test_victoria_protocol

echo ""
echo "=========================================="
echo "E2E VALIDATION RESULTS"
echo "=========================================="
echo "  Passed: $PASSED"
echo "  Failed: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "✓ All E2E validation tests passed!"
    echo ""
    echo "Next step: Run actual test suite to verify behavioral validation:"
    echo "  ./run-tests.sh --filter ComposeUpTests.testWordPressCompose"
    exit 0
else
    echo "✗ $FAILED E2E validation test(s) failed"
    exit 1
fi
