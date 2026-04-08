# Troubleshooting Guide - Vsock Native Relay (Plan 84)

## Overview
This guide covers troubleshooting for the native vSock relay implementation that replaces the `socat` workaround.

## Architecture
The implementation uses a two-volume approach for PostgreSQL:
- `honcho-db-data` (disk image): Database files at `/var/lib/postgresql/data`
- `honcho-db-sockets` (directory): Socket files at `/var/run/postgresql/sockets`

The socket is visible to the host via Virtio-FS mount at:
`~/.containers/Volumes/apple-honcho/honcho-db-sockets/.s.PGSQL.5432`

## Common Issues

### Socket Not Appearing on Host

**Symptom:** PostgreSQL is running but the socket file doesn't appear in the Virtio-FS volume.

**Diagnosis:**
```bash
# Check if socket exists in container
container exec apple-honcho-honcho-db ls -la /var/run/postgresql/sockets/

# Check Virtio-FS volume on host
ls -la ~/.containers/Volumes/apple-honcho/honcho-db-sockets/
```

**Possible causes:**
1. PostgreSQL not configured to use the socket directory
2. Volume not mounted correctly
3. PostgreSQL still initializing

**Solution:** Ensure YAML includes:
```yaml
command:
  - postgres
  - -c
  - unix_socket_directories=/var/run/postgresql/sockets
```

### Relay Fails to Start

**Symptom:** `VsockRelay` fails with timeout error.

**Diagnosis:**
```bash
# Check relay logs
container-compose logs honcho-db
```

**Possible causes:**
1. Socket path mismatch between container and host
2. 60-second timeout exceeded during PostgreSQL startup

**Solution:**
- Verify `socket_path` in YAML matches Virtio-FS mount path
- Increase timeout if needed (currently hardcoded at 60s in VsockRelay.swift:120)

### CID Connection Issues

**Symptom:** Connections to vsock fail with connection refused.

**Note:** Current implementation uses "Ambient" path (Unix socket over Virtio-FS) which doesn't require correct CID for initial connection. The vsock CID only matters for the data transfer phase.

**For future Pure vSock implementation:** CID discovery is not yet implemented. The default CID is 2 (host).

### Database Connection Failures

**Symptom:** Applications can't connect to database.

**Diagnosis:**
```bash
# Test connection from host
psql -h localhost -p 5432 -U postgres -d honcho

# Check if relay is listening
lsof -i :5432
```

**Possible causes:**
1. Relay not started
2. Socket file not accessible
3. Network configuration issue

## Implementation Details

### Key Files
- `Sources/Container-Compose/Networking/VsockRelay.swift` - Relay implementation
- `Sources/Container-Compose/Networking/RelayManager.swift` - Relay orchestration
- `Sources/Container-Compose/Commands/ComposeUp.swift` - Relay startup

### Environment Variables
None required - all configuration via YAML `x-apple-relays` section.

## Rollback to socat

If native relay fails, revert to socat:
```bash
# Stop containers
container-compose down

# Use old YAML (without socket_path)
container-compose up -f honcho-stack-legacy.yml -d
```

## Known Limitations

1. **CID Discovery:** Not implemented - uses default CID 2
2. **Pure vSock Path:** Not implemented - uses "Ambient" path via Virtio-FS
3. **Performance:** Ambient path has higher metadata overhead than pure vsock
## Runtime Validation Checklist

### Phase 5: Socket-First Startup Validation

#### Pre-deployment
- [ ] Ensure Plan 85 build errors are fixed
- [ ] Backup existing database if needed

#### Deployment
- [ ] Deploy with new YAML: `container-compose up -d`
- [ ] Verify honcho-db container starts

#### Post-deployment (Host side)
```bash
# Check socket appears in Virtio-FS volume
ls -la ~/.containers/Volumes/apple-honcho/honcho-db-sockets/

# Should show: .s.PGSQL.5432
```

#### Post-deployment (Container side)
```bash
# Verify PostgreSQL created socket in correct location
container exec apple-honcho-honcho-db ls -la /var/run/postgresql/sockets/

# Verify PostgreSQL is listening
container exec apple-honcho-honcho-db pg_isready
```

#### Database Connectivity Test
```bash
# From host, test connection via relay
psql -h localhost -p 5432 -U postgres -d honcho -c "SELECT 1;"

# Should return: ?column? = 1
```

#### Startup Time Measurement
```bash
# Time the deployment
time container-compose up -d

# Target: < 5 seconds (vs 30s timeout with socat)
```

### Phase 6: Remove socat Workaround

#### Prerequisites
- [ ] Phase 5 validation passes
- [ ] Plan 85 security gating integrated (optional)

#### Execution
- [ ] Remove socat from base image Dockerfile
- [ ] Update documentation
- [ ] Archive socat workaround notes
