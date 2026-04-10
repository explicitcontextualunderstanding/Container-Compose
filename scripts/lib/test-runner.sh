#!/bin/bash
# Test runner utilities for Container-Compose test orchestration
# Handles logging, test result parsing, and orchestration
#
# Usage: source scripts/lib/test-runner.sh
#
# Functions provided:
#   - setup_test_logging()       Setup timestamped log file with tee output
#   - parse_test_results()       Parse swift test output and display tally
#   - check_stale_lock_files()   Detect and optionally clean stale lock files
#   - check_root_owned_files()   Detect root-owned files in .build directory

# Setup logging to timestamped file with console mirroring
# Globals: LOG_DIR, TIMESTAMP, LOG_FILE (set by this function)
# Usage: setup_test_logging [script_dir]
#   If script_dir not provided, uses parent directory of the calling script
setup_test_logging() {
    if [ -n "$1" ]; then
        SCRIPT_DIR="$1"
    else
        # Default: use parent directory of the script that sourced this library
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
    fi
    
    LOG_DIR="$SCRIPT_DIR/logs"
    mkdir -p "$LOG_DIR"
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="$LOG_DIR/test_run_$TIMESTAMP.log"

    # Redirect stdout and stderr to both console and log file
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo "Logging to: $LOG_FILE"
    echo ""
}

# Parse swift test output and display test tally
# Separates static tests (unit tests) from dynamic tests (integration tests)
# Usage: parse_test_results <log_file>
parse_test_results() {
    local log_file="$1"
    
    echo ""
    echo "=========================================="
    echo "TEST RESULTS SUMMARY"
    echo "=========================================="

    # Parse static tests (from swift test output)
    if grep -q "Test Suite 'Container-ComposePackageTests.xctest'" "$log_file" 2>/dev/null; then
        static_summary=$(grep "Test Suite 'Container-ComposePackageTests.xctest'" "$log_file" | tail -1)
        if [[ "$static_summary" =~ Executed\ ([0-9]+)\ tests.*with\ ([0-9]+)\ test.*skipped\ and\ ([0-9]+)\ failures ]]; then
            total="${BASH_REMATCH[1]}"
            skipped="${BASH_REMATCH[2]}"
            failed="${BASH_REMATCH[3]}"
            passed=$((total - skipped - failed))
            echo "Static Tests (Unit Tests):"
            echo "  Total:  $total"
            echo "  ✓ Passed: $passed"
            if [ "$skipped" -gt 0 ]; then
                echo "  ○ Skipped: $skipped"
            fi
            if [ "$failed" -gt 0 ]; then
                echo "  ✗ Failed: $failed"
            fi
            echo ""
        fi
    fi

    # Parse dynamic tests (from swift test output with Container-Compose-DynamicTests)
    if grep -q "Test Suite 'Container-Compose-DynamicTests'" "$log_file" 2>/dev/null; then
        dynamic_summary=$(grep "Test Suite 'Container-Compose-DynamicTests'" "$log_file" | tail -1)
        if [[ "$dynamic_summary" =~ Executed\ ([0-9]+)\ tests.*with\ ([0-9]+)\ test.*skipped\ and\ ([0-9]+)\ failures ]]; then
            total="${BASH_REMATCH[1]}"
            skipped="${BASH_REMATCH[2]}"
            failed="${BASH_REMATCH[3]}"
            passed=$((total - skipped - failed))
            echo "Dynamic Tests (Integration Tests):"
            echo "  Total:  $total"
            echo "  ✓ Passed: $passed"
            if [ "$skipped" -gt 0 ]; then
                echo "  ○ Skipped: $skipped"
            fi
            if [ "$failed" -gt 0 ]; then
                echo "  ✗ Failed: $failed"
            fi
            echo ""
        fi
    fi

    # Overall summary from swift test
    if grep -q "Test run with.* tests" "$log_file" 2>/dev/null; then
        overall_line=$(grep "Test run with.* tests" "$log_file" | tail -1)
        echo "Overall Result:"
        if echo "$overall_line" | grep -q "passed"; then
            echo "  Status: ✓ PASSED"
        else
            echo "  Status: ✗ FAILED"
        fi
        echo "$overall_line" | sed 's/Test run with/  /'
    fi

    echo "=========================================="
}

# Check for stale lock files in temp directory
# AUTO_CLEAN environment variable enables automatic cleanup
# Usage: check_stale_lock_files
check_stale_lock_files() {
    local lock_pattern="_Users_kieranlal_workspace_Container-Compose_.build"
    local temp_dir="/var/folders/1s/1zg1gfbn3j79qw5g2fqsf9q00000gn/T"

    if [ ! -d "$temp_dir" ]; then
        return 0
    fi

    local stale_locks
    stale_locks=$(find "$temp_dir" -name "*$lock_pattern*" -type f 2>/dev/null || true)
    
    if [ -n "$stale_locks" ]; then
        local lock_count
        lock_count=$(echo "$stale_locks" | wc -l | tr -d ' ')
        echo "⚠️  Detected $lock_count stale lock file(s) in temp directory:"
        echo "$stale_locks" | head -5 | while read -r lock; do
            echo " - $(basename "$lock")"
        done
        if [ "$lock_count" -gt 5 ]; then
            echo " ... and $((lock_count - 5)) more"
        fi
        echo ""
        echo " These can cause 'invalid access' errors during build."
        echo ""

        if [ "$AUTO_CLEAN" = true ]; then
            should_clean=true
        else
            echo "Remove stale lock files? [Y/n] "
            read -r -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                should_clean=true
            fi
        fi

        if [ "$should_clean" = true ]; then
            echo "$stale_locks" | while read -r lock; do
                rm -f "$lock" 2>/dev/null || true
            done
            echo "✓ Stale lock files removed"
            echo ""
        else
            echo "⚠️  Continuing without removing locks. Build may fail."
            echo ""
        fi
    fi
}

# Check for root-owned files in .build if not running as root
# Usage: check_root_owned_files
check_root_owned_files() {
    if [ ! -d ".build" ] || [ "$EUID" -eq 0 ]; then
        return 0
    fi

    local root_files
    root_files=$(find .build -user root -print -quit 2>/dev/null || true)
    
    if [ -n "$root_files" ]; then
        echo "⚠️  Detected root-owned files in .build directory."
        echo " This will cause 'Permission denied' errors during compilation."
        echo ""
        echo " Would you like to fix permissions using sudo? [y/N] "
        read -r -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo chown -R "$USER" .build
            echo "✓ Permissions fixed."
            echo ""
        else
            echo "⚠️  Continuing without fixing permissions. Build may fail."
            echo ""
        fi
    fi
}