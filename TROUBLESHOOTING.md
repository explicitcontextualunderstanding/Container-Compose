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

## Startup Time Analysis

### Current Implementation

**VsockRelay.swift lines 117-131:**
```swift
// Wait for PostgreSQL socket in Virtio-FS volume
let startTime = Date()
while Date().timeIntervalSince(startTime) < 60 {  // 60s timeout
  // Poll every 500ms for socket file
  try await Task.sleep(nanoseconds: 500_000_000)
}
```

### Expected Timing

| Phase | Estimated Time |
|-------|---------------|
| Container start | 2-5 seconds |
| PostgreSQL init | 3-10 seconds |
| Socket creation | < 1 second |
| Relay start | < 1 second |
| **Total** | **~10-15 seconds** |

### Target vs Actual

- **Target**: < 5 seconds (Plan 84 objective)
- **With socat**: ~30 seconds (previous timeout)
- **Expected with native relay**: ~10-15 seconds

### Measuring Startup Time

```bash
# Time the full deployment
time container-compose up -d

# Check relay logs for timing
container-compose logs honcho-db | grep -E "(socket|relay|started)"
```

### Optimization Opportunities

1. **Reduce timeout**: Currently 60s, could be 30s if PostgreSQL starts faster
2. **Faster polling**: 500ms could be reduced to 100ms for faster failure detection
3. **Health check integration**: Use PostgreSQL healthcheck instead of socket polling

### Current Limitation

The 60s timeout was chosen conservatively. If PostgreSQL takes longer to initialize (cold start, large database), the relay will wait up to 60 seconds before failing.

---

## Phase 3.5: Production Volume Runtime Testing

### Overview
Production volumes at `~/.containers/Volumes/` can be leveraged for runtime validation tests instead of temporary CCT_* test volumes. This provides more realistic testing against actual container runtime behavior.

### Production Volumes Available
- `~/.containers/Volumes/apple-honcho/honcho-db-data/` - Existing production database volume
- `~/.containers/Volumes/apple/` - General production volumes
- `~/.containers/Volumes/_devcontainer/` - Development container volumes

### Test Implementation
**Test File**: `Tests/Container-Compose-DynamicTests/ProductionVolumeDynamicTests.swift`

**Test Coverage**:
1. `testSocketCreationInProductionVolume()` - VsockRelay socket creation in real volumes
2. `testVirtioFsSocketForwarding()` - Bidirectional communication validation
3. `testVolumeSocketPathDetection()` - isVolumeSocket detection with production paths
4. `testSocketPersistenceAcrossRelayRestart()` - Socket survival across restarts
5. `testProductionVolumeStructure()` - Volume structure verification
6. `testSocketPathPermissions()` - Permission validation in production volumes

### Execution
```bash
# Run production volume tests
swift test --filter ProductionVolumeDynamicTests
```

### Benefits
- Tests run against real production volumes, not temporary CCT_* test volumes
- Validates actual Virtio-FS behavior with container runtime
- No need to wait for YAML deployment to test socket forwarding
- Uses existing test infrastructure (ComposeUpDynamicTests pattern)

---

## Phase 5: Deployment Validation

### Overview
Automated deployment validation script that tests prerequisites, YAML configuration, startup time, and socket creation.

### Test File
`Tests/test_deployment_validation.sh`

### Test Coverage
1. **Prerequisites** - container-compose binary, production volumes
2. **YAML Configuration** - x-apple-relays, socket_path validation
3. **Startup Time** - Target < 5 seconds measurement
4. **Socket Creation** - Virtio-FS volume socket creation
5. **Virtio-FS Detection** - Path detection validation
6. **Relay Configuration** - VsockRelay and RelayManager verification
7. **Production Volumes** - Volume existence checks

### Execution
```bash
# Run deployment validation
cd Tests && ./test_deployment_validation.sh

# Output includes:
# - Colored logging with timestamps
# - Detailed pass/fail results
# - Log file: logs/deployment_validation_YYYYMMDD_HHMMSS.log
```

### Success Criteria
- Startup time < 5 seconds (vs 30s with socat)
- Socket visible in Virtio-FS mount
- All prerequisite checks pass
- YAML configuration validates

---

## Phase 5.5: Database Connectivity Integration Tests

### Overview
Integration tests for actual database connectivity through vsock relay, including query execution, connection pooling, and transaction handling.

### Test File
`Tests/Container-Compose-DynamicTests/DatabaseConnectivityIntegrationTests.swift`

### Test Coverage
1. `testPostgresConnectionViaVsockRelay()` - Direct connection test
2. `testQueryExecution()` - SELECT, INSERT, UPDATE, DROP operations
3. `testConnectionPooling()` - Multiple concurrent connections (5)
4. `testTransactionHandling()` - BEGIN, COMMIT, ROLLBACK
5. `testLargeResultSet()` - Performance with 100 rows
6. `testConnectionResilience()` - Connection through relay restarts

### Mock Implementation
Tests use `MockDatabaseConnection` actor that simulates PostgreSQL client behavior without requiring actual database.

### Execution
```bash
# Run database connectivity tests
swift test --filter DatabaseConnectivityIntegrationTests
```

### Key Features
- Async/await patterns throughout
- Connection timeout handling (10s)
- Concurrent query testing with TaskGroup
- Transaction rollback verification
- Performance measurement for large result sets

---

## Test Execution Summary

### Running All Tests
```bash
# Full test suite with cleanup
./run-tests.sh --auto-clean

# Static tests only (no container runtime)
./run-tests.sh --static

# Dynamic tests only (requires container runtime)
./run-tests.sh --dynamic

# Specific test class
swift test --filter ProductionVolumeDynamicTests
swift test --filter DatabaseConnectivityIntegrationTests
```

### Test Artifacts
- Logs: `logs/test_run_YYYYMMDD_HHMMSS.log`
- Reports: `Tests/TestReports/`
- Deployment validation logs: `logs/deployment_validation_*.log`
