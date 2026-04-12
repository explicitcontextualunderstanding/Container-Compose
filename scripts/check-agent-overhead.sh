#!/bin/bash
# check-agent-overhead.sh
# Pre-flight check for AI agent memory overhead
# Critical for 8GB M2 - agents consume 545MB+ combined

AGENT_PROCESSES=(
    "opencode-ai"
    "claude"
    "kilo"
    "kilocode"
)

echo "========================================"
echo "  AGENT MEMORY OVERHEAD CHECK"
echo "========================================"
echo ""

TOTAL_AGENT_MB=0
AGENT_COUNT=0

echo "=== DETECTED AGENTS ==="
for agent in "${AGENT_PROCESSES[@]}"; do
    PIDS=$(pgrep -f "$agent" 2>/dev/null)
    if [ -n "$PIDS" ]; then
        for pid in $PIDS; do
            RSS=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' ')
            if [ -n "$RSS" ]; then
                MB=$((RSS / 1024))
                CMD=$(ps -o comm= -p $pid 2>/dev/null | head -1)
                printf "  %-20s PID %6s: %4d MB\n" "$agent" "$pid" "$MB"
                TOTAL_AGENT_MB=$((TOTAL_AGENT_MB + MB))
                AGENT_COUNT=$((AGENT_COUNT + 1))
            fi
        done
    fi
done

echo ""
echo "=== MEMORY IMPACT ==="
printf "  Total agents running:     %d\n" "$AGENT_COUNT"
printf "  Total agent memory:       %d MB (%.1f%% of 8GB)\n" "$TOTAL_AGENT_MB" "$(echo "scale=1; $TOTAL_AGENT_MB * 100 / 8192" | bc -l 2>/dev/null || echo "N/A")"

FREE_MEM=$(vm_stat | awk '/Pages free/{f=$3}/Pages inactive/{i=$3}/Pages speculative/{s=$3}END{gsub(/\./,"",f);gsub(/\./,"",i);gsub(/\./,"",s);print int((f+i+s)*4096/1024/1024)}')
printf "  System free memory:       %d MB\n" "$FREE_MEM"
printf "  Projected free (no agents): %d MB\n" "$((FREE_MEM + TOTAL_AGENT_MB))"
echo ""

# Calculate if tests can run
THRESHOLD_HEAVY=450
THRESHOLD_MEDIUM=270
THRESHOLD_LIGHT=140

echo "=== TEST AVAILABILITY ==="

# Current
if [ $FREE_MEM -ge $THRESHOLD_HEAVY ]; then
    echo "  Current: Heavy tests CAN run (have ${FREE_MEM}MB, need ${THRESHOLD_HEAVY}MB)"
elif [ $FREE_MEM -ge $THRESHOLD_MEDIUM ]; then
    echo "  Current: Medium tests only (have ${FREE_MEM}MB, need ${THRESHOLD_HEAVY}MB for heavy)"
elif [ $FREE_MEM -ge $THRESHOLD_LIGHT ]; then
    echo "  Current: Lightweight tests only (have ${FREE_MEM}MB)"
else
    echo "  Current: NO tests can run (have ${FREE_MEM}MB, need ${THRESHOLD_LIGHT}MB minimum)"
fi

# Projected (without agents)
PROJECTED_FREE=$((FREE_MEM + TOTAL_AGENT_MB))
if [ $PROJECTED_FREE -ge $THRESHOLD_HEAVY ]; then
    echo "  Without agents: Heavy tests CAN run (+${TOTAL_AGENT_MB}MB = ${PROJECTED_FREE}MB)"
elif [ $PROJECTED_FREE -ge $THRESHOLD_MEDIUM ]; then
    echo "  Without agents: Medium tests can run (+${TOTAL_AGENT_MB}MB = ${PROJECTED_FREE}MB)"
else
    echo "  Without agents: Still limited (+${TOTAL_AGENT_MB}MB = ${PROJECTED_FREE}MB)"
fi

echo ""

# Recommendations
if [ $AGENT_COUNT -gt 1 ]; then
    echo "⚠️  WARNING: Multiple agents detected (${AGENT_COUNT})"
    echo "    Recommendation: Close $(($AGENT_COUNT - 1)) agent(s) to free ${TOTAL_AGENT_MB}MB"
    echo ""
    echo "    Quick commands:"
    echo "      pkill -f 'opencode-ai'  # Close opencode"
    echo "      pkill -f 'claude'        # Close claude"
    echo "      pkill -f 'kilo'          # Close kilo"
    echo ""
    
    # Show memory gain
    BIGGEST_AGENT=$(ps aux | grep -E "opencode|claude|kilo" | grep -v grep | sort -k6 -nr | head -1 | awk '{print $6/1024 "MB " $11}')
    echo "    Biggest consumer: $BIGGEST_AGENT"
fi

if [ $TOTAL_AGENT_MB -gt 400 ]; then
    echo "💡 INSIGHT: Agents consuming >400MB"
    echo "   This is the PRIMARY blocker for heavy tests"
    echo ""
fi

echo "=== DYNAMIC THRESHOLD INFO ==="
echo "  Current free: ${FREE_MEM}MB"
FREE_PERCENT=$((FREE_MEM * 100 / 8192))
echo "  Free percent: ${FREE_PERCENT}%"
if [ $FREE_PERCENT -lt 12 ]; then
    echo "  Pressure: CRITICAL (<12%) - threshold escalated to 1228MB"
elif [ $FREE_PERCENT -lt 37 ]; then
    echo "  Pressure: WARNING (<37%) - threshold escalated"
else
    echo "  Pressure: NORMAL - using base thresholds"
fi

echo ""
echo "========================================"

# Exit code based on whether tests can run
if [ $FREE_MEM -lt $THRESHOLD_LIGHT ]; then
    exit 1  # Cannot run any tests
elif [ $FREE_MEM -lt $THRESHOLD_MEDIUM ]; then
    exit 2  # Can run lightweight only
elif [ $FREE_MEM -lt $THRESHOLD_HEAVY ]; then
    exit 3  # Can run medium
else
    exit 0  # Can run heavy
fi
