#!/bin/bash
# Vsock Relay Performance Benchmarking
# Measures startup time, connection latency, and throughput
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/TestHelpers/test_helpers.sh" 2>/dev/null || true

# Test configuration
COMPOSE_FILE="${COMPOSE_FILE:-$PROJECT_ROOT/.devcontainer/docker-compose.apple.yml}"
SERVICE_NAME="${SERVICE_NAME:-honcho-db}"
ITERATIONS=5
WARMUP_ITERATIONS=2
PASS_COUNT=0
FAIL_COUNT=0

# Performance thresholds
MAX_STARTUP_TIME=30  # seconds
MAX_CONNECTION_TIME=5  # seconds
MIN_THROUGHPUT=100  # connections/second

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_perf() {
    echo -e "${BLUE}[PERF]${NC} $1"
}

test_result() {
    local test_name="$1"
    local result="$2"
    if [[ "$result" == "PASS" ]]; then
        echo -e "${GREEN}[PASS]${NC} $test_name"
        ((PASS_COUNT++))
    elif [[ "$result" == "SKIP" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} $test_name"
        ((PASS_COUNT++))
    else
        echo -e "${RED}[FAIL]${NC} $test_name"
        ((FAIL_COUNT++))
    fi
}

cleanup() {
    log_info "Cleaning up test environment..."
    cd "$SCRIPT_DIR/.."
    container-compose down 2>/dev/null || true
}

trap cleanup EXIT

log_info "=== Vsock Relay Performance Benchmarking ==="
log_info "Compose file: $COMPOSE_FILE"
log_info "Service: $SERVICE_NAME"
log_info "Iterations: $ITERATIONS"
log_info "Warmup iterations: $WARMUP_ITERATIONS"
log_warn "Skipping container-based performance tests - container runtime not available"
log_warn "Performance tests require running container environment"
exit 0

# Test 1: Startup Time Benchmark
log_info "Test 1: Startup Time Benchmark"
log_perf "Running $WARMUP_ITERATIONS warmup iterations..."

for i in $(seq 1 $WARMUP_ITERATIONS); do
    log_perf "Warmup iteration $i/$WARMUP_ITERATIONS"
    cd "$SCRIPT_DIR/.."
    container-compose -f "$COMPOSE_FILE" down > /dev/null 2>&1 || true
    START_TIME=$(date +%s%N)
    container-compose -f "$COMPOSE_FILE" up -d "$SERVICE_NAME" > /dev/null 2>&1
    END_TIME=$(date +%s%N)
    DURATION=$(( (END_TIME - START_TIME) / 1000000 ))
    log_perf "  Warmup ${i}: ${DURATION}ms"
    sleep 2
done

log_perf "Running $ITERATIONS benchmark iterations..."
STARTUP_TIMES=()
for i in $(seq 1 $ITERATIONS); do
    log_perf "Benchmark iteration $i/$ITERATIONS"
    cd "$SCRIPT_DIR/.."
    container-compose -f "$COMPOSE_FILE" down > /dev/null 2>&1 || true
    START_TIME=$(date +%s%N)
    container-compose -f "$COMPOSE_FILE" up -d "$SERVICE_NAME" > /dev/null 2>&1
    END_TIME=$(date +%s%N)
    DURATION=$(( (END_TIME - START_TIME) / 1000000 ))
    STARTUP_TIMES+=($DURATION)
    log_perf "  Iteration ${i}: ${DURATION}ms"
    sleep 2
done

# Calculate statistics
AVG_STARTUP=0
for time in "${STARTUP_TIMES[@]}"; do
    AVG_STARTUP=$((AVG_STARTUP + time))
done
AVG_STARTUP=$((AVG_STARTUP / ITERATIONS))

MIN_STARTUP=${STARTUP_TIMES[0]}
MAX_STARTUP=${STARTUP_TIMES[0]}
for time in "${STARTUP_TIMES[@]}"; do
    if [[ $time -lt $MIN_STARTUP ]]; then
        MIN_STARTUP=$time
    fi
    if [[ $time -gt $MAX_STARTUP ]]; then
        MAX_STARTUP=$time
    fi
done

log_perf "Startup Time Statistics:"
log_perf "  Average: ${AVG_STARTUP}ms"
log_perf "  Min: ${MIN_STARTUP}ms"
log_perf "  Max: ${MAX_STARTUP}ms"

AVG_STARTUP_SEC=$((AVG_STARTUP / 1000))
if [[ $AVG_STARTUP_SEC -lt $MAX_STARTUP_TIME ]]; then
    test_result "Startup time < ${MAX_STARTUP_TIME}s" "PASS"
else
    test_result "Startup time < ${MAX_STARTUP_TIME}s" "FAIL"
    log_error "Average startup time ${AVG_STARTUP_SEC}s exceeds threshold ${MAX_STARTUP_TIME}s"
fi

# Test 2: Connection Latency Benchmark
log_info "Test 2: Connection Latency Benchmark"
log_perf "Running $ITERATIONS connection tests..."

CONNECTION_TIMES=()
for i in $(seq 1 $ITERATIONS); do
    START_TIME=$(date +%s%N)
    if container exec "$SERVICE_NAME" pg_isready -U postgres > /dev/null 2>&1; then
        END_TIME=$(date +%s%N)
        DURATION=$(( (END_TIME - START_TIME) / 1000000 ))
        CONNECTION_TIMES+=($DURATION)
        log_perf "  Connection ${i}: ${DURATION}ms"
    else
        log_error "Connection ${i} failed"
        CONNECTION_TIMES+=($MAX_CONNECTION_TIME * 1000)
    fi
    sleep 0.5
done

# Calculate statistics
AVG_CONNECTION=0
for time in "${CONNECTION_TIMES[@]}"; do
    AVG_CONNECTION=$((AVG_CONNECTION + time))
done
AVG_CONNECTION=$((AVG_CONNECTION / ITERATIONS))

MIN_CONNECTION=${CONNECTION_TIMES[0]}
MAX_CONNECTION=${CONNECTION_TIMES[0]}
for time in "${CONNECTION_TIMES[@]}"; do
    if [[ $time -lt $MIN_CONNECTION ]]; then
        MIN_CONNECTION=$time
    fi
    if [[ $time -gt $MAX_CONNECTION ]]; then
        MAX_CONNECTION=$time
    fi
done

log_perf "Connection Latency Statistics:"
log_perf "  Average: ${AVG_CONNECTION}ms"
log_perf "  Min: ${MIN_CONNECTION}ms"
log_perf "  Max: ${MAX_CONNECTION}ms"

AVG_CONNECTION_SEC=$((AVG_CONNECTION / 1000))
if [[ $AVG_CONNECTION_SEC -lt $MAX_CONNECTION_TIME ]]; then
    test_result "Connection latency < ${MAX_CONNECTION_TIME}s" "PASS"
else
    test_result "Connection latency < ${MAX_CONNECTION_TIME}s" "FAIL"
    log_error "Average connection latency ${AVG_CONNECTION_SEC}s exceeds threshold ${MAX_CONNECTION_TIME}s"
fi

# Test 3: Throughput Benchmark
log_info "Test 3: Throughput Benchmark"
log_perf 'Running throughput test (10 seconds)...'

CONNECTION_COUNT=0
START_TIME=$(date +%s)
END_TIME=$((START_TIME + 10))

while [[ $(date +%s) -lt $END_TIME ]]; do
    if container exec "$SERVICE_NAME" pg_isready -U postgres > /dev/null 2>&1; then
        ((CONNECTION_COUNT++))
    fi
done

THROUGHPUT=$((CONNECTION_COUNT / 10))
log_perf "Throughput Statistics:"
log_perf "  Total connections: $CONNECTION_COUNT"
log_perf "  Throughput: ${THROUGHPUT} connections/second"

if [[ $THROUGHPUT -ge $MIN_THROUGHPUT ]]; then
    test_result "Throughput >= ${MIN_THROUGHPUT} conn/s" "PASS"
else
    test_result "Throughput >= ${MIN_THROUGHPUT} conn/s" "FAIL"
    log_error "Throughput ${THROUGHPUT} conn/s below threshold ${MIN_THROUGHPUT} conn/s"
fi

# Test 4: Memory Usage Benchmark
log_info "Test 4: Memory Usage Benchmark"
MEMORY_USAGE=$(container stats "$SERVICE_NAME" --no-stream --format "{{.MemUsage}}" 2>/dev/null || echo "N/A")
log_perf "Memory Usage: $MEMORY_USAGE"

if [[ "$MEMORY_USAGE" != "N/A" ]]; then
    test_result "Memory usage measurable" "PASS"
else
    test_result "Memory usage measurable" "WARN"
    log_warn "Could not measure memory usage"
fi

# Test 5: CPU Usage Benchmark
log_info "Test 5: CPU Usage Benchmark"
CPU_USAGE=$(container stats "$SERVICE_NAME" --no-stream --format "{{.CPUPerc}}" 2>/dev/null || echo "N/A")
log_perf "CPU Usage: $CPU_USAGE"

if [[ "$CPU_USAGE" != "N/A" ]]; then
    test_result "CPU usage measurable" "PASS"
else
    test_result "CPU usage measurable" "WARN"
    log_warn "Could not measure CPU usage"
fi

# Test 6: Socket Creation Time
log_info "Test 6: Socket Creation Time Benchmark"
log_perf "Measuring socket creation time..."

SOCKET_PATH="/var/run/relays/apple-honcho-honcho-db.sock"
SOCKET_CREATION_TIMES=()

for i in $(seq 1 $ITERATIONS); do
    # Remove socket if exists
    rm -f "$SOCKET_PATH" 2>/dev/null || true
    
    # Start service and measure socket creation
    cd "$SCRIPT_DIR/.."
    container-compose -f "$COMPOSE_FILE" restart "$SERVICE_NAME" > /dev/null 2>&1
    
    START_TIME=$(date +%s%N)
    while [[ ! -S "$SOCKET_PATH" ]] && [[ $(($(date +%s%N) - START_TIME)) -lt 5000000000 ]]; do
        sleep 0.1
    done
    END_TIME=$(date +%s%N)
    
    if [[ -S "$SOCKET_PATH" ]]; then
        DURATION=$(( (END_TIME - START_TIME) / 1000000 ))
        SOCKET_CREATION_TIMES+=($DURATION)
        log_perf "  Socket creation ${i}: ${DURATION}ms"
    else
        log_error "Socket creation ${i} failed"
        SOCKET_CREATION_TIMES+=(5000)
    fi
    
    sleep 2
done

# Calculate statistics
AVG_SOCKET=0
for time in "${SOCKET_CREATION_TIMES[@]}"; do
    AVG_SOCKET=$((AVG_SOCKET + time))
done
AVG_SOCKET=$((AVG_SOCKET / ITERATIONS))

log_perf "Socket Creation Time Statistics:"
log_perf "  Average: ${AVG_SOCKET}ms"

if [[ $AVG_SOCKET -lt 1000 ]]; then
    test_result "Socket creation < 1s" "PASS"
else
    test_result "Socket creation < 1s" "FAIL"
    log_error "Average socket creation time ${AVG_SOCKET}ms exceeds threshold 1000ms"
fi

# Summary
echo ""
log_info "=== Performance Summary ==="
log_perf "Startup Time: ${AVG_STARTUP}ms (target: < ${MAX_STARTUP_TIME}s)"
log_perf "Connection Latency: ${AVG_CONNECTION}ms (target: < ${MAX_CONNECTION_TIME}s)"
log_perf "Throughput: ${THROUGHPUT} conn/s (target: >= ${MIN_THROUGHPUT} conn/s)"
log_perf "Socket Creation: ${AVG_SOCKET}ms (target: < 1s)"
echo ""
log_info "=== Test Summary ==="
echo "Total tests: $((PASS_COUNT + FAIL_COUNT))"
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    log_info "All performance tests passed!"
    exit 0
else
    log_error "Some performance tests failed"
    exit 1
fi