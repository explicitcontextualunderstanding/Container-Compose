#!/bin/bash
# Test Helper Functions for Container-Compose Tests
# Provides common utilities for test scripts

# Container command wrapper
container() {
    # Try Apple Container runtime first
    if command -v /usr/local/bin/container &> /dev/null; then
        /usr/local/bin/container "$@"
    # Fall back to docker
    elif command -v docker &> /dev/null; then
        docker "$@"
    # Fall back to podman
    elif command -v podman &> /dev/null; then
        podman "$@"
    else
        echo "ERROR: No container command found (container, docker, or podman)" >&2
        return 1
    fi
}

# Container-compose command wrapper
container-compose() {
    # Try Apple container-compose first
    if command -v /Users/kieranlal/bin/container-compose &> /dev/null; then
        /Users/kieranlal/bin/container-compose "$@"
    # Fall back to docker-compose
    elif command -v docker-compose &> /dev/null; then
        docker-compose "$@"
    # Fall back to podman-compose
    elif command -v podman-compose &> /dev/null; then
        podman-compose "$@"
    else
        echo "ERROR: No container-compose command found" >&2
        return 1
    fi
}

# Wait for file to exist with timeout
wait_for_file() {
    local file="$1"
    local timeout="${2:-30}"
    local interval="${3:-1}"
    
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if [[ -e "$file" ]]; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    return 1
}

# Wait for process to be running
wait_for_process() {
    local process_name="$1"
    local timeout="${2:-30}"
    local interval="${3:-1}"
    
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if pgrep -x "$process_name" > /dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    return 1
}

# Check if port is listening
is_port_listening() {
    local port="$1"
    local host="${2:-127.0.0.1}"
    
    if command -v nc &> /dev/null; then
        nc -z "$host" "$port" 2>/dev/null
    elif command -v lsof &> /dev/null; then
        lsof -i ":$port" -sTCP:LISTEN -n > /dev/null 2>&1
    else
        return 1
    fi
}

# Get container IP address
get_container_ip() {
    local container_name="$1"
    container inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name" 2>/dev/null
}

# Check if container is running
is_container_running() {
    local container_name="$1"
    local status=$(container inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null)
    [[ "$status" == "running" ]]
}

# Get container logs
get_container_logs() {
    local container_name="$1"
    local lines="${2:-100}"
    container logs --tail "$lines" "$container_name" 2>/dev/null
}

# Cleanup function
cleanup_containers() {
    local pattern="$1"
    for container in $(container ps -a --format "{{.Names}}" | grep "$pattern"); do
        container stop "$container" 2>/dev/null || true
        container rm "$container" 2>/dev/null || true
    done
}

# Export functions
export -f container
export -f container-compose
export -f wait_for_file
export -f wait_for_process
export -f is_port_listening
export -f get_container_ip
export -f is_container_running
export -f get_container_logs
export -f cleanup_containers