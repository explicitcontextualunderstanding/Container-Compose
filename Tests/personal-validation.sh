#!/bin/bash
# Personal Production Validation Script
# Simplified validation for personal use without full security gates

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${2:-\033[0m}$1${NC}"; }
info() { log "$1" "\033[0;34m"; }
success() { log "✅ $1" "$GREEN"; }
warn() { log "⚠️  $1" "$YELLOW"; }
error() { log "❌ $1" "$RED"; }

section() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

section "Personal Production Validation"
info "Started: $(date)"

# Test 1: Check production volumes
section "1. Production Volumes"
if [[ -d "$HOME/.containers/Volumes" ]]; then
    success "Production volumes directory exists"
    ls -la "$HOME/.containers/Volumes/" 2>/dev/null | head -5
else
    error "Production volumes not found"
    exit 1
fi

# Test 2: Check socket in Virtio-FS
section "2. Socket in Virtio-FS Mount"
SOCKET_PATH="$HOME/.containers/Volumes/apple-honcho/honcho-db-sockets/.s.PGSQL.5432"
if [[ -S "$SOCKET_PATH" ]]; then
    success "Socket found: $SOCKET_PATH"
    ls -la "$SOCKET_PATH"
else
    warn "Socket not found - may need to deploy first"
    info "Deploy with: container-compose up -d"
fi

# Test 3: Database connectivity
section "3. Database Connectivity"
if command -v pg_isready &>/dev/null; then
    if pg_isready -h localhost -p 5432 &>/dev/null; then
        success "Database accepting connections on localhost:5432"
        
        # Try simple query if psql available
        if command -v psql &>/dev/null; then
            info "Testing query..."
            psql -h localhost -p 5432 -U postgres -c "SELECT 1 as test" 2>/dev/null && success "Query successful" || warn "Query failed (may need credentials)"
        fi
    else
        warn "Database not ready on localhost:5432"
    fi
else
    warn "pg_isready not installed - skipping connectivity test"
fi

# Test 4: Container status
section "4. Container Status"
if command -v container &>/dev/null; then
    container list 2>/dev/null | grep -E "honcho-db|postgres" && success "Database container running" || warn "No database container found"
else
    warn "container CLI not available"
fi

# Test 5: Relay logs
section "5. Relay Logs (if available)"
if command -v container-compose &>/dev/null; then
    container-compose logs honcho-db 2>/dev/null | tail -10 || warn "No logs available"
else
    warn "container-compose not in PATH"
fi

section "Validation Complete"
success "Personal validation complete!"
info "Next steps:"
echo "  - If socket not found: deploy with 'container-compose up -d'"
echo "  - If database not ready: wait for container startup (~30s)"
echo "  - For full validation: ./Tests/test_phase6_socat_removal.sh"
echo ""
echo "Note: socat removal blocked until signed binary (expected behavior)"
