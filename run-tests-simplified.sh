#!/bin/bash
# run-tests-simplified.sh
# Clean test runner with proper filtering
# Usage: ./run-tests-simplified.sh [filter-pattern]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_LOG="$LOG_DIR/test_run_$TIMESTAMP.txt"

# Test targets with their characteristics
# Format: "TargetName:parallelism:memory_gate:description"
TEST_TARGETS=(
    "SecurityHardeningTests:parallel:50:Static unit tests with memory traits"
    "Container-Compose-StaticTests:parallel:50:Pure XCTest without network"
    "Container-Compose-Tests:serial:200:NWConnection async tests"
    "Container-Compose-DynamicTests:serial:400:Container-dependent tests"
)

# User filter
USER_FILTER="${1:-}"

echo "=========================================="
echo "CONTAINER-COMPOSE TEST RUNNER"
echo "=========================================="
echo "Log: $TEST_LOG"
echo ""

# Check memory
AVAILABLE_MB=$(vm_stat | awk '
/Pages free/ { free=$3 }
/Pages speculative/ { spec=$3 }
/Pages inactive/ { inactive=$3 }
END { 
    gsub(/\\./, "", free)
    gsub(/\\./, "", spec)
    gsub(/\\./, "", inactive)
    total=(free+spec+inactive)*16384/1024/1024
    printf "%.0f", total
}')

echo "Available Memory: ${AVAILABLE_MB}MB"
echo ""

# Determine which targets to run
TARGETS_TO_RUN=()
for target_info in "${TEST_TARGETS[@]}"; do
    IFS=':' read -r target parallelism gate desc <<< "$target_info"
    
    # If user provided filter, check if this target matches
    if [[ -n "$USER_FILTER" ]]; then
        if echo "$target" | grep -qiE "$USER_FILTER"; then
            TARGETS_TO_RUN+=("$target_info")
        fi
    else
        # No filter - run all targets
        TARGETS_TO_RUN+=("$target_info")
    fi
done

if [[ ${#TARGETS_TO_RUN[@]} -eq 0 ]]; then
    echo "No targets match filter: $USER_FILTER"
    exit 1
fi

echo "Targets to run: ${#TARGETS_TO_RUN[@]}"
for target_info in "${TARGETS_TO_RUN[@]}"; do
    IFS=':' read -r target parallelism gate desc <<< "$target_info"
    echo "  - $target ($parallelism, ${gate}MB): $desc"
done
echo ""

# Run each target
EXIT_CODE=0
for target_info in "${TARGETS_TO_RUN[@]}"; do
    IFS=':' read -r target parallelism gate desc <<< "$target_info"
    
    # Memory check
    if [[ $AVAILABLE_MB -lt $gate ]]; then
        echo "⚠️  Skipping $target: ${AVAILABLE_MB}MB < ${gate}MB required"
        continue
    fi
    
    echo "=========================================="
    echo "TARGET: $target"
    echo "Mode: $parallelism | Memory: ${gate}MB"
    echo "=========================================="
    
    # Determine parallel args
    PARALLEL_ARGS=""
    if [[ "$parallelism" == "parallel" ]]; then
        PARALLEL_ARGS="--parallel --num-workers 2"
    fi
    
    # Run tests
    if swift test $PARALLEL_ARGS --filter "$target" 2>&1 | tee -a "$TEST_LOG"; then
        echo "✓ $target passed"
    else
        echo "✗ $target failed"
        EXIT_CODE=1
    fi
    echo ""
done

echo "=========================================="
echo "TEST RUN COMPLETE"
echo "=========================================="
echo "Log: $TEST_LOG"
exit $EXIT_CODE
