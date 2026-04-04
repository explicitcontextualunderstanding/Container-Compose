# Runtime Compatibility: 0.10.0 and 0.11.0

## Overview

Container-Compose supports both Apple Container 0.10.0 and 0.11.0 runtimes through a feature gating layer. This document describes the compatibility approach during the TCP/IP bug investigation and downgrade process.

## Feature Gate System

The `RuntimeFeatureGate` module provides runtime version detection and conditional feature execution:

### Features by Version

| Feature | 0.10.0 | 0.11.0 |
|---------|--------|--------|
| `--scheme` flag | ❌ No | ✅ Yes |
| `--secret` flag (build) | ❌ No | ✅ Yes |
| `CONTAINER_DEFAULT_PLATFORM` env | ❌ No | ✅ Yes |
| Container prune on startup | ❌ No | ✅ Yes |

### Usage

```swift
// Check feature availability
guard RuntimeFeatureGate.isAvailable(.scheme) else {
 // Fallback for 0.10.0
 return
}

// Conditional execution
RuntimeFeatureGate.ifAvailable(.scheme) {
 commands.append("--scheme")
 commands.append(scheme)
}

// With fallback
let result = RuntimeFeatureGate.withFeature(
 .scheme,
 ifAvailable: { /* use --scheme */ },
 fallback: { /* skip --scheme */ }
)
```

### Environment Override

Force disable features for testing:

```bash
# Disable specific features
DISABLE_SCHEME_FLAG=1 swift test
DISABLE_SECRET_FLAG=1 swift test

# Check current runtime version
container version
```

## Test Compatibility

Tests automatically skip 0.11.0 features when running on 0.10.0:

```
Test Suite 'ComposeUpMappingTests' passed
Executed 44 tests, with 2 tests skipped and 0 failures
```

The 2 skipped tests are:
- `testSchemeMappingHttps` — requires `--scheme` flag
- `testSchemeMappingHttp` — requires `--scheme` flag

## Downgrade Process

### Current Status (2026-04-04)

- **Runtime**: Investigating TCP/IP bug in 0.11.0
- **Container-Compose**: Fully compatible with both 0.10.0 and 0.11.0
- **Tests**: Passing on both versions (with skips on 0.10.0)

### Evidence Collection

We are gathering evidence to confirm:
1. Bug is not environment-specific
2. Downgrade is necessary
3. Feature gating provides safe fallback

### Rollback Plan

If downgrade proceeds:
1. All 0.11.0 features will be automatically disabled
2. Tests will skip applicable test cases
3. No code changes required
4. No user-facing impact

## Implementation Details

### Version Detection

```swift
// Cached at startup
RuntimeFeatureGate.currentVersion // "0.10.0" or "0.11.0"

// Comparison
RuntimeFeatureGate.isVersionAtLeast("0.11.0") // true on 0.11.0
```

### Test Skip Pattern

```swift
func testSchemeMappingHttps() throws {
 guard RuntimeFeatureGate.isAvailable(.scheme) else {
 throw XCTSkip("Skipping: --scheme flag requires Apple Container 0.11.0+")
 }
 // Test implementation
}
```

## Related Files

- `Sources/Container-Compose/Helper Functions/RuntimeFeatureGate.swift` — Feature detection
- `Tests/Container-Compose-StaticTests/ComposeUpMappingTests.swift` — Skip logic
- `Sources/Container-Compose/Commands/ComposeUp.swift` — Feature usage

## References

- Plan 67: Apple Container 0.11.0 Features
- Adversarial Review: All 17 findings resolved
- Container runtime: 0.11.0 (d9b8a8d) → 0.10.0 (pending investigation)
