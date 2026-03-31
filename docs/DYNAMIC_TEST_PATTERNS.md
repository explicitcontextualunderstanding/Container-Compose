# Dynamic Test Patterns & Container Orchestration Insights

**Document Purpose:** The dynamic tests in `Container-Compose-DynamicTests` reveal critical patterns andedge cases in container orchestration. This document captures those insights.

---

## Test Infrastructure Overview

### Test Traits

```swift
@Suite("Compose Up Tests", .containerDependent, .serialized)
```

- **`.containerDependent`**: Custom trait that pings the container API server before tests
- **`.serialized`**: Tests run sequentially to avoid port/network collisions

### Polling Helpers (`ContainerPollingHelpers.swift`)

| Helper | Purpose | Why Needed |
|--------|---------|------------|
| `waitForContainers()` | Poll until N containers exist | Container creation is async |
| `waitForNetworks()` | Poll until container has IP | Networks populated asynchronously|
| `waitForRunning()` | Poll until `.status == .running` | Container start is async |

**Key Insight:** Apple Container runtime populates container state asynchronously. Tests cannot assume immediate availability after `container run`.

---

## Challenges Encountered

### 1. XPC Timeout on Container Stop

**Symptom:**
```
Error Stopping Container: internalError: "failed to stop container"
(cause: "XPC timeout for request to com.apple.container.runtime...")
```

**Root Cause:**
- Apple Container runtime uses XPC for IPC
- Container stop requests can timeout if runtime is under load
- Not a code bug in container-compose

**Mitigation in Tests:**
- Tests use `try? await composeDown.run()` to ignore stop failures
- Production code should handle stop errors gracefully

**Orchestration Lesson:**
> Container lifecycle operations (stop, delete) are **non-atomic** and may fail transiently. Idempotent cleanup with error tolerance is essential.

### 2. Registry Availability (Image Pull Failures)

**Symptom:**
```
HTTP request to http://192.168.1.86:30500/v2/pgmicro/manifests/latest
failed with response: 400 Bad Request. Reason: Unknown
```

**Root Cause:**
- Tests depend on local Zot registry with custom images (`pgmicro`)
- Registry may be unavailable or image missing

**Solution Pattern:**
```swift
private func getZotRegistryURL() -> String {
    if let registryURL = ProcessInfo.processInfo.environment["OCI_REGISTRY_URL"] {
        return registryURL
    }
    return "192.168.1.86:30500"// Default
}
```

**Orchestration Lesson:**
> Tests should allow runtime configuration of external dependencies via environment variables. Hardcoded registry URLs create fragility.

### 3. Async Network Population

**Symptom:**
- Container exists but `networks[]` is empty immediately after start
- IP address not available for `__SERVICE_HOST__` resolution

**Solution in Tests:**
```swift
let containers = try await ContainerPollingHelpers.waitForContainers(
    projectName: folderName,
    expectedCount: 3,
    timeout: 30
)
```

**Orchestration Lesson:**
> Container orchestration must account for **eventual consistency**. The `container run` command returns before the runtime has fully populated metadata.

### 4. Port Collisions in Parallel Tests

**Symptom:**
- Tests fail with "Address already in use"
- Containers from previous tests not cleaned up

**Solution:**
```swift
let testPort = DockerComposeYamlFiles.getAvailablePort()
```

And in `run-tests.sh`:
- Proactive cleanup of `CCT_*` containers before tests
- Trap to cleanup on exit

**Orchestration Lesson:**
> Parallel container tests require deterministic port assignment and aggressive cleanup. The "leave no trace" principle applies.

### 5. Container Name Length Limits (63 chars)

**Symptom:**
```
Invalid argument (Code 22)
```

**Root Cause:**
- macOS Virtualization.framework has 63-character limit for guest process labels
- Test project names like `ContainerComposeTest_` exceed limit

**Solution:**
```swift
// Test container names use CCT_ prefix (shorter)
let tempLocation = URL.temporaryDirectory.appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")
```

**Orchestration Lesson:**
> Container naming conventions must respect platform limits. Use short prefixes for generated names.

---

## Test Patterns

### Pattern 1: Polling for State

```swift
// DON'T: Assume immediate availability
let container = try await ClientContainer.get(id: name)
#expect(container.networks.count > 0)// May fail!

// DO: Poll for expected state
let container = try await ContainerPollingHelpers.waitForNetworks(
    containerId: name,
    timeout: 30
)
```

### Pattern 2: Idempotent Cleanup

```swift
// DON'T: Throw on cleanup failure
try await composeDown.run()

// DO: Tolerate cleanup failures
try? await composeDown.run()// Tests use try? to continue
```

### Pattern 3: Dynamic Port Assignment

```swift
// DON'T: Hardcode ports
ports:- "18080:80"

// DO: Use dynamic port assignment
let testPort = DockerComposeYamlFiles.getAvailablePort()
let yaml = """
ports:
  - "\(testPort):80"
"""
```

### Pattern 4: Environment Variable Override

```swift
// DON'T: Hardcode registry URLs
image: 192.168.1.86:30500/myimage:latest

// DO: Require environment variable with clear error
private func requireRegistryURL() throws -> String {
    guard let registryURL = ProcessInfo.processInfo.environment["OCI_REGISTRY_URL"] else {
        throw Errors.registryNotConfigured("""
            OCI_REGISTRY_URL environment variable is not set.
            
            Database tests require an OCI container registry accessible via HTTPS.
            Apple Container does not support HTTP for RFC1918 private IPs.
            
            Example: OCI_REGISTRY_URL=registry.example.com swift test
            """)
    }
    return registryURL
}
```

Run with custom registry:
```bash
OCI_REGISTRY_URL=registry.example.com swift test
```

---

## External Dependency Management

### The Registry Problem

Tests that depend on external images (like `pgmicro`) face:

1. **Availability:** Registry may be down
2. **Latency:** Pull times vary
3. **Content:** Images may change or be deleted

**Solutions:**

| Approach | Pros | Cons |
|----------|------|------|
| Local image build | Deterministic | Slower, requires Dockerfile |
| Cached image | Fast | Requires pre-seeding |
| Environment variable override | Flexible | Requires setup |
| Skip test if unavailable | Resilient | Reduces coverage |

### Current Test Strategy

```swift
// ComposeAdvancedTests.swift
private func requireRegistryURL() throws -> String {
    guard let registryURL = ProcessInfo.processInfo.environment["OCI_REGISTRY_URL"] else {
        throw Errors.registryNotConfigured("""
            OCI_REGISTRY_URL environment variable is not set.
            ...
            """)
    }
    return registryURL
}
```

Run with custom registry:
```bash
OCI_REGISTRY_URL=ghcr.io swift test
```

---

## XPC Timeout Analysis

### What is XPC?

XPC (Inter-Process Communication) is Apple's mechanism for:
- Container runtime communication
- Privileged operations
- Sandbox boundary crossing

### Why Timeouts Occur

1. **System load:** High CPU/memory pressure
2. **Container state:** Container in transitional state
3. **Runtime bugs:** Unresponsive daemon

### Mitigation Strategies

**In Tests:**
```swift
// Use try? for cleanup operations
try? await container.stop()
```

**In Production:**
- Add timeout handling to `streamCommand()` (already done)
- Implement retry with exponential backoff
- Consider "force kill" fallback

---

## Key Takeaways for Container Orchestration

### 1. Async is the Default
- Container creation, networking, and state changes are async
- Polling/waiting is essential
- Tests must not assume immediate state consistency

### 2. External Dependencies are Fragile
- Registries, networks, and volumes may be unavailable
- Tests need fallbacks or skip conditions
- Configuration should be injectable

### 3. Cleanup is Best-Effort
- Container stop may fail
- Resources may leak
- Idempotent cleanup with error tolerance is essential

### 4. Platform Limits Exist
- 63-character name limit
- Port availability
- Resource limits (CPU, memory)

### 5. Health Checks Must Account for Startup
- `start_period` allows grace time
- Polling intervals affect test speed
- Timeouts must be configurable

---

## Recommendations

### For Test Stability

1. Add `@spi(AppleContainer)` availability checks
2. Implement retry with exponential backoff for XPC operations
3. Use `try?` for cleanup in tests
4. Skip tests requiring external dependencies if unavailable

### For Production Code

1. Poll for state changes instead of assuming immediate availability
2. Handle cleanup failures gracefully
3. Make all external dependencies configurable
4. Document platform-specific limits

### For Documentation

1. Document required images for tests
2. Document environment variables for configuration
3. Document known limitations (XPC timeout, async state)
4. Provide setup scripts for external dependencies

---

## Related Files

- `Tests/Container-Compose-DynamicTests/ComposeUpTests.swift` - Core compose tests
- `Tests/Container-Compose-DynamicTests/ComposeAdvancedTests.swift` - Database integration tests
- `Tests/TestHelpers/ContainerPollingHelpers.swift` - Polling utilities
- `Tests/TestHelpers/DockerComposeYamlFiles.swift` - YAML fixtures
- `run-tests.sh` - Test runner with cleanup