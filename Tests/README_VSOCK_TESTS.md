# Vsock Native Relay Finalization - Test Suite

This directory contains automated validation tests for the vsock native relay finalization (Plan 84).

## Test Scripts

### Individual Tests

1. **test_virtio_fs_uds_forwarding.sh**
   - Validates Virtio-FS Unix Domain Socket forwarding
   - Tests socket creation, visibility, and bidirectional communication
   - Checks socket permissions and cleanup

2. **test_cid_assignment.sh**
   - Verifies Host and Guest CID assignment
   - Checks CIDVerifier implementation
   - Validates dynamic Guest CID support
   - Ensures no hardcoded CID restrictions

3. **test_vsock_relay_integration.sh**
   - End-to-end integration testing
   - Validates compose file configuration
   - Tests service startup and socket creation
   - Verifies database connectivity
   - Checks for socat workaround removal

4. **test_vsock_relay_performance.sh**
   - Performance benchmarking suite
   - Measures startup time (target: < 30s)
   - Tests connection latency (target: < 5s)
   - Measures throughput (target: >= 100 conn/s)
   - Benchmarks socket creation time (target: < 1s)

### Master Test Runner

**run_vsock_relay_tests.sh**
- Runs all tests in sequence
- Generates comprehensive test report
- Provides pass/fail summary
- Saves reports to `TestReports/` directory

## Usage

### Run All Tests
```bash
cd Tests
./run_vsock_relay_tests.sh
```

### Run Individual Tests
```bash
cd Tests
./test_virtio_fs_uds_forwarding.sh
./test_cid_assignment.sh
./test_vsock_relay_integration.sh
./test_vsock_relay_performance.sh
```

### Run with Custom Configuration
```bash
# Specify custom compose file
COMPOSE_FILE=/path/to/compose.yml ./test_vsock_relay_integration.sh

# Specify custom service name
SERVICE_NAME=my-service ./test_vsock_relay_integration.sh
```

## Test Reports

Test reports are automatically generated in the `TestReports/` directory with the format:
```
vsock_relay_test_report_YYYYMMDD_HHMMSS.txt
```

Reports include:
- Individual test results
- Performance metrics
- Pass/fail summary
- Detailed logs

## Requirements

- Apple Container runtime 0.11.0+
- container-compose CLI
- Docker/container CLI
- Bash shell
- Network connectivity for integration tests

## Environment Variables

- `COMPOSE_FILE`: Path to docker-compose file (default: `.devcontainer/docker-compose.apple.yml`)
- `SERVICE_NAME`: Service name to test (default: `honcho-db`)
- `DB_NAME`: Database name (default: `honcho`)
- `DB_USER`: Database user (default: `postgres`)

## Test Coverage

### Phase 3: Virtio-FS UDS Forwarding
- ✅ Socket creation in containers
- ✅ Socket visibility on host
- ✅ Bidirectional communication
- ✅ Socket permissions
- ✅ Socket cleanup

### Phase 4: CID Assignment
- ✅ Host CID constant verification
- ✅ CIDVerifier implementation
- ✅ Dynamic Guest CID support
- ✅ No hardcoded CID restrictions
- ✅ CID range validation

### Phase 5: Socket-First Startup
- ✅ Compose file validation
- ✅ Service startup time
- ✅ Socket file creation
- ✅ Database connectivity
- ✅ Relay configuration verification

### Phase 6: socat Removal
- ✅ No socat processes running
- ✅ Native relay functionality
- ✅ Performance benchmarks

## Troubleshooting

### Test Failures

1. **Virtio-FS UDS Forwarding Test Fails**
   - Check if Virtio-FS is properly mounted
   - Verify container runtime version
   - Check volume mount configuration

2. **CID Assignment Test Fails**
   - Review RelayTypes.swift for CID restrictions
   - Check for hardcoded CID values
   - Verify CIDVerifier implementation

3. **Integration Test Fails**
   - Verify compose file syntax: `container-compose config`
   - Check service logs: `container-compose logs <service>`
   - Ensure services are not already running

4. **Performance Test Fails**
   - Check system resources
   - Close other applications
   - Verify network connectivity

### Common Issues

**Permission Denied**
```bash
chmod +x Tests/*.sh
```

**Container Not Found**
```bash
container ps -a
container-compose ps
```

**Socket File Not Found**
```bash
ls -la /var/run/relays/
```

## Contributing

When adding new tests:
1. Follow existing naming convention: `test_<feature>.sh`
2. Use consistent output formatting (INFO/ERROR/WARN)
3. Return 0 for success, 1 for failure
4. Add documentation to this README
5. Update master test runner if needed

## References

- Plan 84: `isaac_ros_custom/.claude/plans/84-vsock-native-relay-finalization.md`
- VsockRelay: `Sources/Container-Compose/Networking/VsockRelay.swift`
- RelayManager: `Sources/Container-Compose/Networking/RelayManager.swift`
- RelayTypes: `Sources/Container-Compose/Networking/RelayTypes.swift`