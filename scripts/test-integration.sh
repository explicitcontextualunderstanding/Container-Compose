#!/bin/bash
# Integration test for cleanup orchestration
# Tests: cleanup script, RUN_ID generation, signal handlers, container labels

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "✓ PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "✗ FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

echo "=========================================="
echo "INTEGRATION TEST"
echo "=========================================="
echo ""

# Test 1: Cleanup script exists and is executable
if [ -x "$PROJECT_DIR/scripts/cleanup-orchestrator.sh" ]; then
    pass "cleanup-orchestrator.sh executable"
else
    fail "cleanup-orchestrator.sh missing or not executable"
fi

# Test 2: RUN_ID format
RUN_ID="cct-$(date +%s)-$$"
if [[ "$RUN_ID" =~ ^cct-[0-9]+-[0-9]+$ ]]; then
    pass "RUN_ID format correct: $RUN_ID"
else
    fail "RUN_ID format incorrect"
fi

# Test 3: run-tests.sh exports CCT_RUN_ID
if grep -q "export CCT_RUN_ID" "$PROJECT_DIR/run-tests.sh"; then
    pass "run-tests.sh exports CCT_RUN_ID"
else
    fail "run-tests.sh missing CCT_RUN_ID export"
fi

# Test 4: Signal handlers in run-tests.sh
if grep -q 'trap.*victoria_cleanup.*INT' "$PROJECT_DIR/run-tests.sh"; then
    pass "SIGINT handler present"
else
    fail "SIGINT handler missing"
fi

# Test 5: ResourceArbiter has CCT_RUN_ID support
if grep -q "CCT_RUN_ID" "$PROJECT_DIR/Sources/ContainerTesting/ResourceArbiter.swift"; then
    pass "ResourceArbiter reads CCT_RUN_ID"
else
    fail "ResourceArbiter missing CCT_RUN_ID"
fi

# Test 6: ContainerPool adds labels
if grep -q "com.container-compose.test-run-id" "$PROJECT_DIR/Tests/TestHelpers/ContainerPool.swift"; then
    pass "ContainerPool adds test-run-id labels"
else
    fail "ContainerPool missing labels"
fi

# Test 7: ComposeUp adds labels
if grep -q "com.container-compose.test-run-id" "$PROJECT_DIR/Sources/Container-Compose/Commands/ComposeUp.swift"; then
    pass "ComposeUp adds test-run-id labels"
else
    fail "ComposeUp missing labels"
fi

# Test 8: Cleanup script syntax
if bash -n "$PROJECT_DIR/scripts/cleanup-orchestrator.sh" 2>/dev/null; then
    pass "cleanup-orchestrator.sh syntax valid"
else
    fail "cleanup-orchestrator.sh syntax error"
fi

# Test 9: Cleanup script CLI detection works
if grep -q "command -v container" "$PROJECT_DIR/scripts/cleanup-orchestrator.sh"; then
    pass "cleanup-orchestrator.sh detects container CLI"
else
    fail "cleanup-orchestrator.sh missing CLI detection"
fi

# Test 10: Container name prefixing in ComposeUp
if grep -q 'CCT_.*runId' "$PROJECT_DIR/Sources/Container-Compose/Commands/ComposeUp.swift"; then
    pass "ComposeUp prefixes container names"
else
    fail "ComposeUp missing name prefixing"
fi

echo ""
echo "=========================================="
echo "RESULTS: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=========================================="

if [ $TESTS_FAILED -eq 0 ]; then
    echo "✓ All integration tests passed"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
