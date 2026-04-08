# Plan 84 Runtime Validation Guide

## Prerequisites
- [ ] Plan 85 build errors fixed (SecureRelayManager coupling resolved)
- [ ] `swift build` completes successfully

## Deployment Steps

### 1. Deploy with New YAML
```bash
cd /Users/kieranlal/workspace/isaac_ros_custom/.appcontainer
container-compose up -d -f honcho-stack-with-derivers.yml
```

### 2. Verify Socket Appears (Phase 5)
```bash
# Host side - check Virtio-FS mount
ls -la ~/.containers/Volumes/apple-honcho/honcho-db-sockets/
# Expected: .s.PGSQL.5432

# Container side - verify PostgreSQL created socket
container exec apple-honcho-honcho-db ls -la /var/run/postgresql/sockets/
# Expected: .s.PGSQL.5432
```

### 3. Verify Database Connectivity
```bash
# Test from host via relay
psql -h localhost -p 5432 -U postgres -d honcho -c "SELECT version();"
# Expected: PostgreSQL version output
```

### 4. Measure Startup Time
```bash
# Full redeploy timing
time container-compose down && time container-compose up -d

# Check logs for timing
container-compose logs honcho-db | grep -E "(socket|started|ready)"
```

### 5. Test Consumer Services (Phase 5)
```bash
# Test honcho-hub connectivity
curl -sf http://localhost:8000/health

# Test derivers
curl -sf http://localhost:8000/peers
```

### 6. Phase 6: Remove socat (After Validation)
Once Phases 4-5 confirmed working:
1. Remove socat from base image Dockerfiles
2. Update documentation
3. Archive socat workaround notes

## Troubleshooting

### Socket Not Appearing
- Check PostgreSQL command includes `unix_socket_directories=/var/run/postgresql/sockets`
- Verify volume mount: `~/.containers/Volumes/apple-honcho/`

### Connection Refused
- Check relay is running: `lsof -i :5432`
- Review logs: `container-compose logs vsock-relay`

### Slow Startup
- Current timeout: 60s in VsockRelay.swift:120
- Expected: 10-15s total
- Target: <5s (future optimization)