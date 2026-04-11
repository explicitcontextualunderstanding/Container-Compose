#!/bin/bash
# incremental-test.sh
# Incremental test execution - only run tests for changed files
# Usage: ./scripts/incremental-test.sh [--base-commit SHA]

set -e

# Default to HEAD~1 if no base commit specified
BASE_COMMIT="${1:-HEAD~1}"

echo "=========================================="
echo "Incremental Test Execution"
echo "=========================================="
echo "Base commit: $BASE_COMMIT"
echo ""

# Get changed files since base commit
CHANGED_FILES=$(git diff --name-only "$BASE_COMMIT" 2>/dev/null || git diff --name-only)

if [ -z "$CHANGED_FILES" ]; then
    echo "No files changed since $BASE_COMMIT"
    echo "Running all tests..."
    exec ./run-tests.sh
fi

echo "Changed files:"
echo "$CHANGED_FILES" | sed 's/^/  - /'
echo ""

# Determine which test targets to run
RUN_STATIC=false
RUN_DYNAMIC=false
RUN_TESTS=false
RUN_SECURITY=false

# Check each changed file and map to test targets
while IFS= read -r file; do
    case "$file" in
        # Source files affecting all test targets
        Sources/Container-Compose/*)
            RUN_STATIC=true
            RUN_DYNAMIC=true
            RUN_TESTS=true
            ;;
        Sources/SecurityHardening/*)
            RUN_SECURITY=true
            ;;
        Sources/ContainerComposeApp/*)
            RUN_STATIC=true
            RUN_DYNAMIC=true
            RUN_TESTS=true
            ;;
        # Test helper changes affect all tests
        Tests/TestHelpers/*)
            RUN_STATIC=true
            RUN_DYNAMIC=true
            RUN_TESTS=true
            RUN_SECURITY=true
            ;;
        # Static tests
        Tests/Container-Compose-StaticTests/*)
            RUN_STATIC=true
            ;;
        # Dynamic tests
        Tests/Container-Compose-DynamicTests/*)
            RUN_DYNAMIC=true
            ;;
        # Integration tests
        Tests/Container-Compose-Tests/*)
            RUN_TESTS=true
            ;;
        # Security tests
        Tests/SecurityHardeningTests/*)
            RUN_SECURITY=true
            ;;
        # Script changes - don't affect tests
        scripts/*|run-tests.sh|.github/*)
            echo "  (Script change - no test impact)"
            ;;
        # Config changes - run all tests to be safe
        Package.swift|CLAUDE.md|*.yml|*.yaml)
            RUN_STATIC=true
            RUN_DYNAMIC=true
            RUN_TESTS=true
            RUN_SECURITY=true
            ;;
    esac
done <<< "$CHANGED_FILES"

# Build filter list
FILTER=""
if [ "$RUN_STATIC" = true ]; then
    FILTER="Container-Compose-StaticTests"
fi
if [ "$RUN_DYNAMIC" = true ]; then
    [ -n "$FILTER" ] && FILTER="$FILTER|"
    FILTER="${FILTER}Container-Compose-DynamicTests"
fi
if [ "$RUN_TESTS" = true ]; then
    [ -n "$FILTER" ] && FILTER="$FILTER|"
    FILTER="${FILTER}Container-Compose-Tests"
fi
if [ "$RUN_SECURITY" = true ]; then
    [ -n "$FILTER" ] && FILTER="$FILTER|"
    FILTER="${FILTER}SecurityHardeningTests"
fi

# If nothing matched, run all tests
if [ -z "$FILTER" ]; then
    echo "Could not determine affected tests from changed files."
    echo "Running all tests to be safe..."
    exec ./run-tests.sh
fi

echo "=========================================="
echo "Running incremental test suite"
echo "=========================================="
echo "Test targets:"
[ "$RUN_STATIC" = true ] && echo "  ✓ Container-Compose-StaticTests"
[ "$RUN_DYNAMIC" = true ] && echo "  ✓ Container-Compose-DynamicTests"
[ "$RUN_TESTS" = true ] && echo "  ✓ Container-Compose-Tests"
[ "$RUN_SECURITY" = true ] && echo "  ✓ SecurityHardeningTests"
echo ""
echo "Skipping unaffected targets to save time"
echo ""

# Execute incremental tests
./run-tests.sh --filter "$FILTER"
