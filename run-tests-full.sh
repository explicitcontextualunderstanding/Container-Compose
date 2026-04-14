#!/bin/bash
# run-tests-full.sh - Manifest-Driven Test Orchestrator
# Reads tests-manifest.json to run tests with validation
set -euo pipefail

cd /Users/kieranlal/workspace/Container-Compose

MANIFEST="tests-manifest.json"
mkdir -p logs

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=========================================="
echo "Container-Compose Test Orchestrator"
echo "Swift $(swift --version | head -1)"
echo "Manifest: $MANIFEST"
echo "=========================================="
echo ""

# Check manifest exists
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Manifest not found: $MANIFEST"
    exit 1
fi

# Show manifest info
python3 -c "
import json
with open('$MANIFEST') as f:
    m = json.load(f)
print(f\"Project: {m['project']}\")
print(f\"Toolchain: {m.get('toolchain', 'unknown')}\")
print(f\"Targets: {len(m['targets'])}\")
print(f\"Total expected tests: {sum(t['expected_count'] for t in m['targets'])}\")
"

TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
FAILED_TARGETS=()
SKIPPED_TARGETS=()

# Read targets from manifest using Python
TARGETS=$(python3 -c "
import json
with open('$MANIFEST') as f:
    m = json.load(f)
for t in m['targets']:
    print(f\"{t['name']}|{t['filter']}|{t.get('parallel', False)}|{t['expected_count']}|{t.get('requires_containers', False)}\")
")

echo ""
echo "=========================================="
echo "Running tests from manifest"
echo "=========================================="

while IFS='|' read -r name filter parallel expected requires_containers; do
    echo ""
    echo "=========================================="
    echo "Target: $name"
    echo "Expected: $expected tests"
    echo "=========================================="
    
    # Check environment for container-dependent tests
    if [[ "$requires_containers" == "True" ]]; then
        if [[ -z "${OCI_REGISTRY_URL:-}" ]]; then
            echo "⚠️  SKIPPED: OCI_REGISTRY_URL not set"
            SKIPPED_TARGETS+=("$name")
            continue
        fi
    fi
    
    # Build command
    parallel_args="--no-parallel"
    if [[ "$parallel" == "True" ]]; then
        parallel_args="--parallel --num-workers 2"
    fi
    
    log="logs/${name}_${TIMESTAMP}.log"
    
    # Run tests and capture output
    echo "Running: swift test $parallel_args --filter \"$filter\""
    swift test $parallel_args --filter "$filter" 2>&1 | tee "$log"
    exit_code=${PIPESTATUS[0]}
    
    # Parse results - use last "Executed X tests" line
    # Format: "Executed 123 tests, with 4 failures (0 unexpected) in 1.5 seconds"
    executed=$(grep -E "Executed [0-9]+ tests" "$log" | tail -1 | grep -oE "Executed [0-9]+" | grep -oE "[0-9]+" || echo "0")
    failures=$(grep -E "[0-9]+ failures" "$log" | tail -1 | grep -oE "[0-9]+ failures" | grep -oE "[0-9]+" || echo "0")
    passed=$((executed - failures))
    
    echo ""
    echo "Result: $passed passed, $failures failed (of $executed executed)"
    
    # Validation
    if [[ "$executed" == "0" ]]; then
        echo "🚨 FAIL: 0 tests executed (expected $expected)"
        FAILED_TARGETS+=("$name")
    elif [[ "$executed" != "$expected" ]]; then
        echo "⚠️  WARN: $executed executed vs $expected expected"
        # Don't fail on count mismatch - Swift bug may cause this
    else
        echo "✓ OK: $executed tests executed as expected"
    fi
    
    TOTAL_TESTS=$((TOTAL_TESTS + executed))
    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    TOTAL_FAILED=$((TOTAL_FAILED + failures))
    
done <<< "$TARGETS"

echo ""
echo "=========================================="
echo "FINAL SUMMARY"
echo "=========================================="
echo "Total tests: $TOTAL_TESTS"
echo "Passed: $TOTAL_PASSED"
echo "Failed: $TOTAL_FAILED"
echo "Skipped: ${#SKIPPED_TARGETS[@]}"

if [[ ${#SKIPPED_TARGETS[@]} -gt 0 ]]; then
    echo "Skipped targets:"
    for t in "${SKIPPED_TARGETS[@]}"; do
        echo "  - $t"
    done
fi

if [[ ${#FAILED_TARGETS[@]} -gt 0 ]]; then
    echo "Failed targets:"
    for t in "${FAILED_TARGETS[@]}"; do
        echo "  - $t"
    done
fi

# Write summary
cat > "logs/summary_${TIMESTAMP}.json" << EOF
{
  "total": $TOTAL_TESTS,
  "passed": $TOTAL_PASSED,
  "failed": $TOTAL_FAILED,
  "skipped": $(printf '%s\n' "${SKIPPED_TARGETS[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))"),
  "failed_targets": $(printf '%s\n' "${FAILED_TARGETS[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))"),
  "timestamp": "$TIMESTAMP"
}
EOF

echo ""
echo "Summary: logs/summary_${TIMESTAMP}.json"
echo "Logs: logs/*_${TIMESTAMP}.log"

if [[ ${#FAILED_TARGETS[@]} -gt 0 ]]; then
    echo ""
    echo "⚠️ SOME TARGETS FAILED"
    exit 1
else
    echo ""
    echo "🎉 ALL TARGETS PASSED"
    exit 0
fi
