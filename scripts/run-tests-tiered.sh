#!/bin/bash
#===----------------------------------------------------------------------===//
# run-tests-tiered.sh
# Execute tests by memory weight: light → medium → heavy → critical
# Critical tier: WordPress/MySQL multi-service (run last, when memory is freest)
# Usage: ./scripts/run-tests-tiered.sh
#===----------------------------------------------------------------------===//

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

get_available_memory() {
    local free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
    local spec_pages=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | tr -d '.' 2>/dev/null || echo 0)
    local inactive_pages=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
    echo $(( (free_pages + spec_pages + inactive_pages) * 16384 / 1024 / 1024 ))
}

check_memory() {
    local required="$1"
    local available=$(get_available_memory)
    echo "Memory: ${available}MB available, ${required}MB required"
    if [ "$available" -lt "$required" ]; then
        echo -e "${RED}⚠️ INSUFFICIENT MEMORY${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Memory OK${NC}"
    return 0
}

run_phase() {
    local phase_name="$1"
    local filter="$2"
    local mem_required="${3:-0}"
    local log_file="logs/tiered-${phase_name}.log"
    
    echo ""
    echo "=========================================="
    echo -e "${GREEN}PHASE: $phase_name${NC}"
    echo "=========================================="
    echo ""
    
    if [ "$mem_required" -gt 0 ]; then
        if ! check_memory "$mem_required"; then
            echo -e "${YELLOW}Skipping phase due to low memory${NC}"
            return 1
        fi
    fi
    
    local skip_args=""

    echo "Running: $filter"
    swift test --filter "$filter" 2>&1 | tee "$log_file"
    
    local passed=$(grep -c "passed" "$log_file" 2>/dev/null || echo 0)
    echo ""
    echo -e "${GREEN}Phase complete: $passed tests${NC}"
}

echo "=========================================="
echo "TIERED TEST EXECUTION (Memory-Weighted)"
echo "=========================================="
echo ""

# Tier 1: Ultra-lightweight (static tests, no containers) - ~50MB
echo "TIER 1: Ultra-lightweight (50MB)"
echo "Tests: Static parsing, configuration, mapping"
run_phase "tier1-static" "Container-Compose-StaticTests" 50

# Tier 2: Lightweight (unit tests, no containers) - ~100MB
echo ""
echo "TIER 2: Lightweight (100MB)"
echo "Tests: Security, validation"
run_phase "tier2-security" "SecurityHardeningTests" 100

# Tier 3: Medium (dynamic tests, single containers) - ~200MB
echo ""
echo "TIER 3: Medium (200MB)"
echo "Tests: Single container operations, networking"
run_phase "tier3-dynamic" "Container-Compose-DynamicTests" 200

# Tier 4: Heavy (multi-container, no databases) - ~400MB
echo ""
echo "TIER 4: Heavy (400MB)"
echo "Tests: Multi-service orchestration"
run_phase "tier4-heavy" "ComposeDownTests" 400

# Tier 5: Critical (WordPress/MySQL, three-tier) - ~800MB
echo ""
echo "TIER 5: Critical (800MB)"
echo "Tests: WordPress + MySQL, three-tier apps"

# Check if we should even attempt critical tier
AVAILABLE=$(get_available_memory)
if [ "$AVAILABLE" -lt 800 ]; then
    echo -e "${YELLOW}⚠️ Skipping critical tier: ${AVAILABLE}MB < 800MB required${NC}"
    echo "Tip: Close Chrome, Slack, or other memory-heavy apps"
else
    run_phase "tier5-critical" "ComposeUpTests" 800
fi

# Summary
echo ""
echo "=========================================="
echo "TIERED EXECUTION COMPLETE"
echo "=========================================="
echo ""

total_passed=0
total_failed=0
for log in logs/tiered-*.log; do
    if [ -f "$log" ]; then
        passed=$(grep -c "passed" "$log" 2>/dev/null || echo 0)
        total_passed=$((total_passed + passed))
        echo "$(basename $log): $passed tests"
    fi
done

echo ""
echo "Total passed: $total_passed"
echo "Logs: logs/tiered-*.log"
