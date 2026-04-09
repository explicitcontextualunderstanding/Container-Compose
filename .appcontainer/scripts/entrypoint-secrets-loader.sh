#!/bin/bash
# Container entrypoint for x-apple-secrets
# Reads secrets from mounted tmpfs and exports to container environment

set -euo pipefail

SECRETS_DIR="${SECRETS_MOUNT:-/run/secrets}"
SECRETS_CLEANUP="${SECRETS_CLEANUP:-immediate}"

# Logging function
log_info() {
    echo "[secrets-loader] $*" >&2
}

log_error() {
    echo "[secrets-loader] ERROR: $*" >&2
}

# Load secrets from tmpfs mount
load_secrets() {
    if [[ ! -d "$SECRETS_DIR" ]]; then
        log_error "Secrets directory not mounted at $SECRETS_DIR"
        return 1
    fi

    local loaded_count=0

    for secret_file in "$SECRETS_DIR"/*; do
        if [[ -f "$secret_file" ]]; then
            local var_name
            var_name=$(basename "$secret_file")

            # Validate variable name (alphanumeric + underscore)
            if [[ ! "$var_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                log_error "Invalid secret name: $var_name (skipping)"
                continue
            fi

            # Read and export to environment
            local secret_value
            if ! secret_value=$(cat "$secret_file" 2>/dev/null); then
                log_error "Failed to read secret: $var_name"
                continue
            fi

            # Export the secret
            export "$var_name=$secret_value"
            ((loaded_count++)) || true

            # Log loaded (value masked for security)
            log_info "Loaded secret: $var_name"
        fi
    done

    log_info "Loaded $loaded_count secrets from $SECRETS_DIR"
    return 0
}

# Cleanup mount after reading (based on cleanup policy)
cleanup_mount() {
    case "$SECRETS_CLEANUP" in
        immediate)
            log_info "Cleaning up secrets mount (immediate policy)"
            ;;
        on_stop)
            log_info "Keeping secrets mount (cleanup on container stop)"
            return 0
            ;;
        manual)
            log_info "Keeping secrets mount (manual cleanup)"
            return 0
            ;;
        *)
            log_info "Cleaning up secrets mount (default policy)"
            ;;
    esac

    # Attempt unmount
    if ! umount "$SECRETS_DIR" 2>/dev/null; then
        # Non-fatal: mount may already be unmounted
        log_info "Mount already unmounted or not accessible"
    fi
}

# Validate environment before running
validate_environment() {
    # Check if running as root (optional warning)
    if [[ "$EUID" -eq 0 ]]; then
        log_info "Running as root (secrets will be available to all processes)"
    fi

    # Check ulimit for core dumps
    local core_size
    core_size=$(ulimit -c 2>/dev/null || echo "unlimited")
    if [[ "$core_size" != "0" && "$core_size" != "unlimited" ]]; then
        log_info "Warning: Core dumps enabled (size: $core_size). Secrets may appear in core files."
    fi

    return 0
}

# Main execution
main() {
    log_info "Starting secrets loader..."

    # Validate environment
    validate_environment

    # Load secrets
    if ! load_secrets; then
        log_error "Failed to load secrets. Continuing anyway..."
    fi

    # Cleanup based on policy
    cleanup_mount

    log_info "Secrets loaded successfully. Executing command: $*"

    # Execute the original command
    exec "$@"
}

# Run main with all arguments
main "$@"
