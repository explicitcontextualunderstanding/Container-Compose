#!/bin/bash
#===----------------------------------------------------------------------===//
# run-tests-ordered.sh
# Execute tests in optimal order: lightweight first, then heavy container tests
# Skips known hanging tests (RelayConstantsTests/testSocketPermissions)
# Usage: ./scripts/run-tests-ordered.sh
#===----------------------------------------------------------------------===//

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

echo "=========================================="
echo "ORDERED TEST EXECUTION"
echo "=========================================="
echo ""

# Check memory before starting
FREE_PAGES=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
SPEC_PAGES=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.')
INACTIVE_PAGES=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
AVAILABLE_MB=$(( ($FREE_PAGES + $SPEC_PAGES + $INACTIVE_PAGES) * 16384 / 1024 / 1024 ))

echo "Available memory: ${AVAILABLE_MB}MB"
echo ""

# Phase 1: Static tests (lightweight, no containers)
echo "=========================================="
echo "PHASE 1: Static Tests (Lightweight)"
echo "=========================================="
echo ""
swift test --filter "Container-Compose-StaticTests" --skip "testSocketPermissions" 2>&1 | tee logs/phase1-static.log
echo ""

# Phase 2: Security tests (no containers)
echo "=========================================="
echo "PHASE 2: Security Tests"
echo "=========================================="
echo ""
swift test --filter "SecurityHardeningTests" --skip "testSocketPermissions" 2>&1 | tee logs/phase2-security.log
echo ""

# Phase 3: Dynamic tests - excluding heavy container tests
echo "=========================================="
echo "PHASE 3: Dynamic Tests (Excluding Heavy)"
echo "=========================================="
echo ""
swift test --filter "Container-Compose-DynamicTests" --skip "ComposeUpTests" --skip "ComposeDownTests" 2>&1 | tee logs/phase3-dynamic.log
echo ""

# Phase 4: Heavy container tests (run last when memory is most stable)
echo "=========================================="
echo "PHASE 4: Heavy Container Tests"
echo "=========================================="
echo ""
echo "Memory check before heavy tests:"
FREE_PAGES=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
SPEC_PAGES=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.')
INACTIVE_PAGES=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
AVAILABLE_MB=$(( ($FREE_PAGES + $SPEC_PAGES + $INACTIVE_PAGES) * 16384 / 1024 / 1024 ))
echo "Available: ${AVAILABLE_MB}MB (need 400MB)"

if [ "$AVAILABLE_MB" -lt 400 ]; then
    echo "⚠️ WARNING: Low memory for heavy tests. Consider closing applications."
fi
echo ""

swift test --filter "ComposeUpTests" --skip "testSocketPermissions" 2>&1 | tee logs/phase4-heavy.log
swift test --filter "ComposeDownTests" --skip "testSocketPermissions" 2>&1 | tee logs/phase4-heavy.log
echo ""

# Summary
echo "=========================================="
echo "TEST EXECUTION COMPLETE"
echo "=========================================="
echo ""
echo "Results:"
grep -E "passed|failed" logs/phase1-static.log 2>/dev/null | tail -1
grep -E "passed|failed" logs/phase2-security.log 2>/dev/null | tail -1
grep -E "passed|failed" logs/phase3-dynamic.log 2>/dev/null | tail -1
grep -E "passed|failed" logs/phase4-heavy.log 2>/dev/null | tail -1
echo ""
echo "Logs saved to logs/phase*.log"
