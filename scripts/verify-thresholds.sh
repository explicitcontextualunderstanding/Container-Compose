#!/bin/bash
# verify-thresholds.sh
# Empirically verify memory thresholds are working

echo "========================================"
echo "  MEMORY THRESHOLD VERIFICATION"
echo "========================================"
echo ""

# Current memory
echo "=== CURRENT SYSTEM STATE ==="
FREE_MEM=$(vm_stat | awk '/Pages free/{f=$3}/Pages inactive/{i=$3}/Pages speculative/{s=$3}END{gsub(/\./,"",f);gsub(/\./,"",i);gsub(/\./,"",s);print int((f+i+s)*4096/1024/1024)}')
echo "Free Memory: ${FREE_MEM}MB"
echo ""

# Thresholds
echo "=== EMPIRICAL THRESHOLDS ==="
echo "Lightweight:  140MB (need: $((140 - FREE_MEM))MB more)"
echo "Medium:       270MB (need: $((270 - FREE_MEM))MB more)"
echo "Heavy:        450MB (need: $((450 - FREE_MEM))MB more)"
echo ""

# Check what's possible
echo "=== TEST AVAILABILITY ==="
if [ $FREE_MEM -ge 450 ]; then
    echo "✅ Heavy tests:     CAN RUN (≥450MB)"
else
    echo "❌ Heavy tests:     BLOCKED (need $((450 - FREE_MEM))MB more)"
fi

if [ $FREE_MEM -ge 270 ]; then
    echo "✅ Medium tests:    CAN RUN (≥270MB)"
else
    echo "❌ Medium tests:    BLOCKED (need $((270 - FREE_MEM))MB more)"
fi

if [ $FREE_MEM -ge 140 ]; then
    echo "✅ Lightweight:     CAN RUN (≥140MB)"
else
    echo "❌ Lightweight:     BLOCKED (need $((140 - FREE_MEM))MB more)"
fi
echo ""

# Test discovery
echo "=== TEST DISCOVERY ==="
echo "Heavy tests (have .heavyContainer):"
grep -r "\.heavyContainer" Tests/ --include="*.swift" | cut -d: -f1 | xargs basename -a 2>/dev/null | sort -u | sed 's/^/  - /'

echo ""
echo "Medium tests (would use .mediumContainer):"
echo "  (none currently configured - could be added to relay tests)"

echo ""
echo "Lightweight tests (no memory guard):"
grep -r "@Suite" Tests/Container-Compose-StaticTests/ --include="*.swift" | grep -v "containerDependent" | head -5 | sed 's/^.*@Suite("\([^"]*\)".*/  - \1/'
echo ""

# Check for skipped tests in logs
echo "=== EMPIRICAL EVIDENCE FROM LOGS ==="
echo "Recent test run:"
if ls logs/test_run_*.log 1>/dev/null 2>&1; then
    LATEST_LOG=$(ls -t logs/test_run_*.log | head -1)
    echo "Log: $LATEST_LOG"
    echo ""
    echo "Test count:"
    grep -c "^\[.*\] Testing " "$LATEST_LOG" 2>/dev/null || echo "  (no test output found)"
    echo ""
    echo "Skipped tests:"
    grep -i "skip\|SKIPPED\|Memory Guard" "$LATEST_LOG" | head -5 || echo "  (no skips found)"
else
    echo "  (no test logs found)"
fi
echo ""

# Top memory consumers
echo "=== TOP MEMORY CONSUMERS ==="
echo "(Close these to free memory for tests):"
ps aux | sort -nr -k 4 | head -8 | awk '{printf "  %-20s %5.1f%%\n", $11, $4}'
echo ""

# Recommendation
echo "=== RECOMMENDATION ==="
if [ $FREE_MEM -lt 450 ]; then
    echo "To run heavy tests (ComposeUp/Down), you need $((450 - FREE_MEM))MB more free."
    echo ""
    echo "Quick fixes:"
    echo "  1. Close applications consuming >100MB (see list above)"
    echo "  2. Kill derivers: pkill -f 'python.*deriver'"
    echo "  3. Restart to clear memory fragmentation"
    echo ""
    echo "Alternative: Run lightweight tests only:"
    echo "  swift test --filter 'Container-Compose-StaticTests'"
fi
