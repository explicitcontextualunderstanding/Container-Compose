#!/bin/bash
# DEPRECATED: This script has been merged into run-tests.sh
# All manifest-driven execution, timeouts, and validation are now in run-tests.sh.
echo "⚠️  run-tests-full.sh is deprecated. Use run-tests.sh instead."
echo ""
echo "  ./run-tests.sh              # Run all targets from tests-manifest.json"
echo "  ./run-tests.sh --auto-clean # Same, with automatic cleanup"
echo "  ./run-tests.sh <filter>     # Run a specific test filter"
echo ""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run-tests.sh" "$@"
