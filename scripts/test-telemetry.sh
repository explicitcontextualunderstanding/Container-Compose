#!/bin/bash
# Test the new telemetry system with a simple container

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOG_DIR"

echo "=========================================="
echo "CONTAINER TELEMETRY TEST"
echo "=========================================="
echo ""

# Start telemetry collector
echo "[1/5] Starting telemetry collector..."
TELEMETRY_LOG="$LOG_DIR/test_telemetry_$(date +%Y%m%d_%H%M%S).csv"
"$SCRIPT_DIR/container-stats-telemetry.sh" --output "$TELEMETRY_LOG" --interval 1 &
TELEMETRY_PID=$!
echo "        Collector PID: $TELEMETRY_PID"
echo "        Output: $TELEMETRY_LOG"
echo ""

sleep 2

# Create a test container
echo "[2/5] Creating CCT test container..."
CONTAINER_NAME="CCT_telemetry_test_$(date +%s)"
container run -d \
    --name "$CONTAINER_NAME" \
    --memory 256M \
    --cpus 1 \
    nginx:alpine \
    2>/dev/null || {
    echo "ERROR: Failed to create container"
    kill $TELEMETRY_PID 2>/dev/null || true
    exit 1
}
echo "        Container: $CONTAINER_NAME"
echo ""

sleep 2

# Check container is running
echo "[3/5] Verifying container..."
if container list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    echo "        ✓ Container is running"
else
    echo "        ✗ Container not found"
fi
echo ""

# Let it run for a few seconds
echo "[4/5] Collecting samples (3 seconds)..."
sleep 3
echo "        ✓ Samples collected"
echo ""

# Cleanup
echo "[5/5] Cleaning up..."
container stop "$CONTAINER_NAME" 2>/dev/null || true
container delete "$CONTAINER_NAME" 2>/dev/null || true
echo "        ✓ Container stopped and deleted"
echo ""

# Stop telemetry
kill $TELEMETRY_PID 2>/dev/null || true
wait $TELEMETRY_PID 2>/dev/null || true
echo "        ✓ Telemetry stopped"
echo ""

# Analyze results
echo "=========================================="
echo "RESULTS"
echo "=========================================="
echo ""

if [ -f "$TELEMETRY_LOG" ] && [ -s "$TELEMETRY_LOG" ]; then
    LINE_COUNT=$(wc -l < "$TELEMETRY_LOG")
    if [ "$LINE_COUNT" -gt 1 ]; then
        echo "✓ Telemetry collected successfully!"
        echo "  Samples: $((LINE_COUNT - 1))"
        echo ""

        # Show first few samples
        echo "Sample data (first 5 rows):"
        head -6 "$TELEMETRY_LOG" | column -t -s,
        echo ""

        # Analyze with Python
        if [ -f "$SCRIPT_DIR/analyze-container-telemetry.py" ]; then
            echo "--- Analysis ---"
            python3 "$SCRIPT_DIR/analyze-container-telemetry.py" "$TELEMETRY_LOG" --json 2>/dev/null | python3 -m json.tool || echo "Analysis script not available"
        fi
    else
        echo "✗ Telemetry file empty (only header)"
        echo "  This indicates the container was not captured."
        echo ""
        cat "$TELEMETRY_LOG"
    fi
else
    echo "✗ Telemetry file not found"
fi

echo ""
echo "Full log: $TELEMETRY_LOG"
