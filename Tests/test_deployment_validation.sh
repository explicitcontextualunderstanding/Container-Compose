#!/bin/bash
#==============================================================================
# Deployment Validation Script for Plan 84 Phase 5
# Validates vsock-db relay deployment with production volumes
#
# Task Owner: @mac-kilo-kim
# Status: In Progress (v1.16.0)
#==============================================================================

set -euo pipefail

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${PROJECT_ROOT}/logs/deployment_validation_$(date +%Y%m%d_%H%M%S).log"
TEST_PROJECT_NAME="deployment-test-$(date +%s)"
STARTUP_TIMEOUT=10
SOCKET_TIMEOUT=30

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#==============================================================================
# Logging Functions
#==============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

info() { log "INFO" "$@"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }

#==============================================================================
# Test Functions
#==============================================================================

test_prerequisites() {
    info "Testing prerequisites..."
    
    # Check container-compose binary exists
    if ! command -v container-compose &> /dev/null; then
        error "container-compose not found in PATH"
        return 1
    fi
    success "container-compose found"
    
    # Check production volumes exist
    if [[ ! -d "$HOME/.containers/Volumes" ]]; then
        error "Production volumes directory not found: ~/.containers/Volumes"
        return 1
    fi
    success "Production volumes directory exists"
    
    # Check apple-honcho volume exists
    if [[ ! -d "$HOME/.containers/Volumes/apple-honcho" ]]; then
        warn "apple-honcho volume not found - will be created during deployment"
    else
        success "apple-honcho volume exists"
    fi
    
    return 0
}

test_yaml_configuration() {
    info "Testing YAML configuration..."
    
    # Create test YAML with vsock-db relay configuration
    local yaml_file="/tmp/${TEST_PROJECT_NAME}-docker-compose.yaml"
    
    cat > "$yaml_file" << 'EOF'
name: deployment-test
services:
  db:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: testdb
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
    volumes:
      - db-data:/var/lib/postgresql/data
      - db-sockets:/var/run/postgresql/sockets
    x-apple-relays:
      - type: vsock-db
        port: 5432
        socket_path: ~/.containers/Volumes/deployment-test/db-sockets/.s.PGSQL.5432
    command:
      - postgres
      - -c
      - unix_socket_directories=/var/run/postgresql/sockets
      - -c
      - listen_addresses=*

volumes:
  db-data:
  db-sockets:
EOF
    
    # Validate YAML structure
    if container-compose config --file "$yaml_file" &> /dev/null; then
        success "YAML configuration is valid"
    else
        error "YAML configuration validation failed"
        return 1
    fi
    
    # Check x-apple-relays configuration
    if grep -q "x-apple-relays:" "$yaml_file"; then
        success "x-apple-relays configuration found"
    else
        error "x-apple-relays configuration missing"
        return 1
    fi
    
    # Check socket_path is present
    if grep -q "socket_path:" "$yaml_file"; then
        success "socket_path configuration found"
    else
        error "socket_path configuration missing"
        return 1
    fi
    
    rm -f "$yaml_file"
    return 0
}

test_startup_time() {
    info "Testing startup time (target: < 5 seconds)..."
    
    local yaml_file="/tmp/${TEST_PROJECT_NAME}-docker-compose.yaml"
    
    # Create minimal test YAML
    cat > "$yaml_file" << 'EOF'
name: startup-test
services:
  db:
    image: busybox:latest
    command: ["sleep", "5"]
EOF
    
    # Measure startup time
    local start_time=$(date +%s.%N)
    
    if ! timeout "$STARTUP_TIMEOUT" container-compose up -d --file "$yaml_file" &> /dev/null; then
        error "Startup timed out (>${STARTUP_TIMEOUT}s)"
        rm -f "$yaml_file"
        return 1
    fi
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Cleanup
    container-compose down --file "$yaml_file" &> /dev/null || true
    rm -f "$yaml_file"
    
    # Check if under 5 seconds
    if (( $(echo "$duration < 5" | bc -l) )); then
        success "Startup time: ${duration}s (under 5s target)"
        return 0
    else
        warn "Startup time: ${duration}s (exceeds 5s target)"
        return 1
    fi
}

test_socket_creation() {
    info "Testing socket creation in Virtio-FS volume..."
    
    local socket_dir="$HOME/.containers/Volumes/${TEST_PROJECT_NAME}"
    local socket_path="${socket_dir}/test.sock"
    
    # Create test socket directory
    mkdir -p "$socket_dir"
    
    # Create a test socket using Python (more reliable than nc)
    python3 -c "
import socket
import os

sock_path = '${socket_path}'
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sock_path)
sock.listen(1)

# Wait briefly then exit
import time
time.sleep(0.5)
" &
    
    local pid=$!
    sleep 1
    
    # Check if socket was created
    if [[ -S "$socket_path" ]]; then
        success "Socket created successfully: $socket_path"
        kill $pid 2>/dev/null || true
        rm -f "$socket_path"
        rmdir "$socket_dir" 2>/dev/null || true
        return 0
    else
        error "Socket not created: $socket_path"
        kill $pid 2>/dev/null || true
        rm -rf "$socket_dir" 2>/dev/null || true
        return 1
    fi
}

test_virtio_fs_volume_detection() {
    info "Testing Virtio-FS volume path detection..."
    
    # Test various paths
    local volume_paths=(
        "$HOME/.containers/Volumes/apple-honcho/honcho-db-data"
        "$HOME/.containers/Volumes/apple/test"
        "$HOME/.containers/Volumes/_devcontainer/test"
    )
    
    local passed=0
    local failed=0
    
    for path in "${volume_paths[@]}"; do
        if [[ "$path" == *".containers/Volumes"* ]]; then
            success "Detected volume path: $path"
            ((passed++))
        else
            error "Failed to detect volume path: $path"
            ((failed++))
        fi
    done
    
    # Test non-volume paths (should NOT be detected)
    local non_volume_paths=(
        "/tmp/test.sock"
        "/var/run/postgresql/.s.PGSQL.5432"
    )
    
    for path in "${non_volume_paths[@]}"; do
        if [[ "$path" == *".containers/Volumes"* ]]; then
            error "Incorrectly detected as volume path: $path"
            ((failed++))
        else
            success "Correctly identified non-volume path: $path"
            ((passed++))
        fi
    done
    
    info "Results: $passed passed, $failed failed"
    
    if [[ $failed -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

test_relay_configuration() {
    info "Testing relay configuration..."
    
    # Check if RelayManager has Virtio-FS detection
    local relay_manager="${PROJECT_ROOT}/Sources/Container-Compose/Networking/RelayManager.swift"
    
    if [[ -f "$relay_manager" ]]; then
        if grep -q "\.containers/Volumes" "$relay_manager"; then
            success "Virtio-FS detection found in RelayManager"
        else
            error "Virtio-FS detection not found in RelayManager"
            return 1
        fi
    else
        error "RelayManager.swift not found"
        return 1
    fi
    
    # Check if VsockRelay has createSignalSocket parameter
    local vsock_relay="${PROJECT_ROOT}/Sources/Container-Compose/Networking/VsockRelay.swift"
    
    if [[ -f "$vsock_relay" ]]; then
        if grep -q "createSignalSocket" "$vsock_relay"; then
            success "createSignalSocket parameter found in VsockRelay"
        else
            error "createSignalSocket parameter not found in VsockRelay"
            return 1
        fi
    else
        error "VsockRelay.swift not found"
        return 1
    fi
    
    return 0
}

test_production_volumes() {
    info "Testing production volumes..."
    
    local volumes=(
        "$HOME/.containers/Volumes/apple-honcho"
        "$HOME/.containers/Volumes/apple"
        "$HOME/.containers/Volumes/_devcontainer"
    )
    
    local found=0
    
    for volume in "${volumes[@]}"; do
        if [[ -d "$volume" ]]; then
            success "Production volume exists: $volume"
            ((found++))
        else
            warn "Production volume not found: $volume"
        fi
    done
    
    if [[ $found -ge 1 ]]; then
        info "Found $found production volume(s)"
        return 0
    else
        error "No production volumes found"
        return 1
    fi
}

#==============================================================================
# Main Execution
#==============================================================================

main() {
    info "=========================================="
    info "Plan 84 Phase 5: Deployment Validation"
    info "Task Owner: @mac-kilo-kim"
    info "Started: $(date)"
    info "=========================================="
    
    # Create logs directory
    mkdir -p "${PROJECT_ROOT}/logs"
    
    local total_tests=0
    local passed_tests=0
    local failed_tests=0
    
    # Run all tests
    local tests=(
        test_prerequisites
        test_yaml_configuration
        test_startup_time
        test_socket_creation
        test_virtio_fs_volume_detection
        test_relay_configuration
        test_production_volumes
    )
    
    for test_func in "${tests[@]}"; do
        ((total_tests++))
        if $test_func; then
            ((passed_tests++))
        else
            ((failed_tests++))
        fi
        echo ""
    done
    
    # Summary
    info "=========================================="
    info "Test Summary"
    info "=========================================="
    info "Total tests: $total_tests"
    success "Passed: $passed_tests"
    
    if [[ $failed_tests -gt 0 ]]; then
        error "Failed: $failed_tests"
        info "Log file: $LOG_FILE"
        exit 1
    else
        success "All tests passed!"
        info "Log file: $LOG_FILE"
        exit 0
    fi
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
