# Library Scripts

This directory contains shared library scripts for Container-Compose test infrastructure.

## Libraries

### container-cleanup.sh

Container and snapshot lifecycle management for Apple Container runtime.

**Functions:**
- `get_apple_container_state()` - Parse Apple Container state.json
- `prune_test_snapshots()` - Remove orphaned test snapshots
- `aggressive_cleanup_before_tests()` - Clean all CCT_* artifacts pre-test
- `cleanup_test_containers()` - Clean all CCT_* artifacts post-test

**Usage:**
```bash
source scripts/lib/container-cleanup.sh

# Pre-test cleanup
aggressive_cleanup_before_tests

# Post-test cleanup (via trap)
trap cleanup_test_containers EXIT
```

**Environment Variables:**
- `AC_DATA_DIR` - Apple Container data directory (default: `~/Library/Application Support/com.apple.container`)
- `AC_SNAPSHOTS_DIR` - Snapshots directory (default: `$AC_DATA_DIR/snapshots`)

### test-runner.sh

Test orchestration utilities for running and parsing Swift test results.

**Functions:**
- `setup_test_logging()` - Setup timestamped log file with tee output
- `parse_test_results()` - Parse swift test output and display tally
- `check_stale_lock_files()` - Detect and optionally clean stale lock files
- `check_root_owned_files()` - Detect root-owned files in .build directory

**Usage:**
```bash
source scripts/lib/test-runner.sh

# Setup logging
setup_test_logging

# Run tests
swift test 2>&1 | tee "$LOG_DIR/test_output_$TIMESTAMP.txt"

# Parse results
parse_test_results "$LOG_DIR/test_output_$TIMESTAMP.txt"
```

**Environment Variables:**
- `AUTO_CLEAN` - Set to `true` to automatically clean stale lock files
- `LOG_DIR` - Set by `setup_test_logging()` (default: `$SCRIPT_DIR/logs`)
- `LOG_FILE` - Set by `setup_test_logging()` (format: `test_run_YYYYMMDD_HHMMSS.log`)

### xpc-stability.sh

XPC service stability checks for Apple Container runtime (placeholder for future implementation).

**Functions:**
- `check_container_daemon()` - Verify container daemon is responsive
- `verify_xpc_connection()` - Check XPC connection health

**Status:** Placeholder - functions currently return success without actual checks.

## Design Principles

1. **Single Responsibility** - Each library has one clear purpose
2. **Independent Modules** - Libraries don't depend on each other
3. **Clear Function Signatures** - Well-documented input/output
4. **Error Handling** - Meaningful error messages with context
5. **Testability** - Functions can be unit tested independently

## Adding New Libraries

When adding a new library:

1. Create file in `scripts/lib/`
2. Add comprehensive header comment with:
   - Purpose
   - Usage example
   - Functions provided
3. Follow naming convention: `kebab-case.sh`
4. Document all functions with:
   - Purpose
   - Parameters
   - Return values
   - Environment variables used
5. Update this README

## Testing

Unit tests for library functions can be added to `Tests/lib-tests/` (create if needed).

Example:
```bash
# Tests/lib-tests/test-container-cleanup.sh
#!/bin/bash
source scripts/lib/container-cleanup.sh

test_get_apple_container_state() {
    # Test implementation
}

test_prune_test_snapshots() {
    # Test implementation
}

# Run tests
test_get_apple_container_state
test_prune_test_snapshots
```

## Related Files

- `../run-tests.sh` - Main test runner (uses these libraries)
- `../env-setup.sh` - Environment setup (independent module)
- `/Tests/network_reachability.sh` - Network tests (uses container-cleanup.sh)
- `/Tests/compose_static_checks.sh` - Static checks (potentially uses test-runner.sh)