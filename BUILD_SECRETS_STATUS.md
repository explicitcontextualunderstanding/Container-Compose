# Build Secrets Implementation Status

## Summary

Feature 1 of Plan 67 (Build Secrets) is **partially complete**:

- ✅ **YAML Parsing**: 7/7 static tests passing
- ⚠️ **CLI Wiring**: Implemented but blocked on upstream dependency
- ❌ **Integration Testing**: Cannot run actual builds with secrets

## What Works

1. **BuildSecret.swift**: Struct for build-time secrets (simpler than ServiceSecret)
2. **Build.swift**: `secrets` field added to Build configuration
3. **ComposeUp.swift**: Generates `--secret` CLI flags from buildConfig.secrets
4. **Static Tests**: All 7 parsing tests pass (env, src, multiple, backward compatibility)

## What's Blocked

**Integration test** requires `container build --secret` to work via Swift's ArgumentParser:

```
Error: ArgumentParser.ParserError.unknownOption("--secret")
```

The Apple Container CLI binary (v0.11.0) supports `--secret`, but the Swift package dependency
(`mcrich23/container` branch: `add-command-option-group-function-macro`) doesn't expose it in
`Application.BuildCommand`.

## Test Results

```bash
# Static tests (YAML parsing)
$ swift test --filter BuildSecretTests
✔ Test run with 7 tests in 1 suite passed after 0.015 seconds.

# Integration test (placeholder)
$ swift test --filter testBuildSecretsIntegration
⚠️  Integration test skipped: mcrich23/container lacks --secret ArgumentParser support
✓ YAML parsing validated by BuildSecretTests.swift (7 tests passing)
✔ Test "Build secrets integration - blocked on upstream" passed after 0.001 seconds.

# Full test suite
$ OCI_REGISTRY_URL=registry.rossollc.com swift test
✔ Test run with 200 tests in 16 suites passed after 181.894 seconds.
```

## Resolution Path

1. **Wait for upstream**: mcrich23/container to add ArgumentParser support for `--secret`
2. **Or fork**: Add the flag definition ourselves to the dependency
3. **Alternative**: Use `Process` to shell out to `container build` directly (bypass ArgumentParser)

## Use Case

Build secrets allow passing sensitive data (API keys, private keys) during Dockerfile builds
without persisting them in the final image:

```yaml
services:
  app:
    build:
      context: .
      secrets:
        - id: api_key
          env: API_KEY_ENV
```

```dockerfile
FROM alpine
RUN --mount=type=secret,id=api_key \
    cat /run/secrets/api_key > /tmp/config
```

This is more secure than `--build-arg` which persists values in image metadata.

## Current Workaround

For Hermes/Honcho stack: Runtime secrets injection via 1Password Connect (no build-time secrets
needed). Dockerfile.realsense.collapsed uses public git clones and TLS-only registry auth.

## Files Changed

- `Sources/Container-Compose/Codable Structs/BuildSecret.swift` (new)
- `Sources/Container-Compose/Codable Structs/Build.swift` (updated)
- `Sources/Container-Compose/Commands/ComposeUp.swift` (updated)
- `Tests/Container-Compose-StaticTests/BuildSecretTests.swift` (new, 7 tests)
- `Tests/Container-Compose-DynamicTests/ComposeUpTests.swift` (placeholder test added)

## Commit

`8cdb353` - feat: Add build secrets support (Plan 67 Feature 1)

Merged to main via `660a3a4`.
