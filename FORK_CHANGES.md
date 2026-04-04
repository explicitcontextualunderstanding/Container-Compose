# Fork Changes Summary

This document summarizes all changes in this fork (`explicitcontextualunderstanding/Container-Compose`) relative to the upstream repository (`Mcrich23/Container-Compose`).

**Current Release:** v0.11.0
**Container Runtime:** v0.11.0
**Last Updated:** 2026-04-03

---

## Version History

### v0.11.0 — Apple Container 0.11.0 Compatibility (Plan 67)

**Release Date:** 2026-04-03

**New Features:**

1. **Build secrets support** — `build.secrets` in compose files with `id` + `env`/`src` fields
2. **CONTAINER_DEFAULT_PLATFORM** — env var fallback for platform resolution
3. **Registry protocol control** — `--scheme` flag for HTTP/HTTPS/auto registry access

**Implementation Status:**

- Build secrets: YAML parsing complete (7 tests), CLI wiring blocked on upstream mcrich23/container
- Platform fallback: Complete and tested
- Registry scheme: Complete and wired

**Test Results:** 200/200 tests passing (199 existing + 1 placeholder for blocked integration test)

### v0.10.3 — Orchestration Hardening (Plan 65)

## Index of Changed Files

### Known Runtime Limitations

#### Service Name Length

There is a clinical 64-character limit for guest process labels in the macOS container runtime. When using long project names or UUID-based prefixes (common in test suites), service names must be kept short to avoid `Invalid argument (Code 22)` errors.

- **Proactive Validation:** The orchestrator now warns users if a container name exceeds 63 characters during `up` and provides a detailed discussion in `--help`.
- **Port Isolation:** Dynamic tests now use a dedicated, non-overlapping port range (18080–18085) to prevent "Address already in use" errors during parallel execution.
- **Image Compatibility:** WordPress tests have been transitioned to `wordpress:fpm-alpine` to bypass `Virtualization.framework` syscall limitations.
- **Security Compliance:** Installation now targets `~/bin` with ad-hoc signing to ensure stability under macOS security policies.

- **Recommended Names:** `wp`, `db`, `web`.
- **Avoid:** Long descriptive names like `wordpress-application-service` if the combined length exceeds ~63 characters.

### Testing with Custom Registries

The test suite supports custom container registries via the `OCI_REGISTRY_URL` environment variable:

```bash
# Use custom registry (e.g., Cloudflare tunnel to bypass Apple Container RFC1918 HTTP downgrade)
OCI_REGISTRY_URL=registry.example.com swift test
```

This is particularly useful when working around Apple Container's HTTP auto-downgrade bug for private IP addresses (RFC1918). Database tests require `OCI_REGISTRY_URL` to be set because Apple Container does not support HTTP for private IPs.

#### Apple Container IP Address Bug Workaround

Apple Container cannot pull images from registries using IP addresses (RFC1918 private IPs). It only supports domain names. This fork uses a Cloudflare tunnel with IP-based bypass authentication to route a domain to the local Zot registry:

```
Apple Container → registry.example.com → Cloudflare Tunnel → Zot (internal IP)
```

**Cloudflare Access Configuration:**

| Setting     | Value                                                           |
| ----------- | --------------------------------------------------------------- |
| Application | Zot Registry Secure (your domain)                               |
| Policy      | Service Token Bypass                                            |
| Action      | BYPASS                                                          |
| IP Ranges   | Your local network ranges (e.g., `192.168.1.0/24`, IPv6 prefix) |

**Usage:**

```bash
# Set registry URL for database tests
OCI_REGISTRY_URL=your-registry.example.com swift test --filter ComposeAdvancedTests

# Pull images via domain (works with Apple Container)
container run your-registry.example.com/your-image:latest echo "test"
```

**Troubleshooting 403 Errors:**

1. Verify your public IP: `curl -s ifconfig.me`
2. Check Cloudflare Access policy includes your IP range
3. IPv6 users need `/64` prefix (not `/128` single address)
4. Policy changes take 30-60 seconds to propagate

### All Changed Files

| Status         | File                                                                      | Change Summary                                                                                                                                                                                                                                                                                                                                                                                |
| -------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Added          | `.github/workflows/release.yml`                                           | Automated release workflow                                                                                                                                                                                                                                                                                                                                                                    |
| Modified       | `.github/workflows/tests.yml`                                             | Enhanced CI workflow, added static test filtering                                                                                                                                                                                                                                                                                                                                             |
| Added+Modified | `CHANGELOG.md`                                                            | Version changelog                                                                                                                                                                                                                                                                                                                                                                             |
| Added          | `FORK_CHANGES.md`                                                         | This file — fork change tracking                                                                                                                                                                                                                                                                                                                                                              |
| Added          | `VERIFICATION.md`                                                         | Verification procedures and testing guidelines                                                                                                                                                                                                                                                                                                                                                |
| Added+Modified | `build-release.sh`                                                        | Release build script with conda/xattr cleanup                                                                                                                                                                                                                                                                                                                                                 |
| Added+Modified | `build-sign-install.sh`                                                   | Build, sign, install with auto git hash injection and `/usr/local/bin` symlink                                                                                                                                                                                                                                                                                                                |
| Added+Modified | `install.sh`                                                              | Installation script with macOS provenance handling                                                                                                                                                                                                                                                                                                                                            |
| Added+Modified | `run-tests.sh`                                                            | Test runner with conda environment cleanup                                                                                                                                                                                                                                                                                                                                                    |
| Added+Modified | `scripts/env-setup.sh`                                                    | Shared conda environment cleanup for build and test scripts                                                                                                                                                                                                                                                                                                                                   |
| Modified       | `Sources/Container-Compose/Application.swift`                             | Added checkpoint command registration, git hash in version string                                                                                                                                                                                                                                                                                                                             |
| Modified       | `Sources/Container-Compose/Codable Structs/Build.swift`                   | Added `target` field for multi-stage builds                                                                                                                                                                                                                                                                                                                                                   |
| Modified       | `Sources/Container-Compose/Codable Structs/Network.swift`                 | Enhanced network synchronization                                                                                                                                                                                                                                                                                                                                                              |
| Modified       | `Sources/Container-Compose/Codable Structs/Service.swift`                 | Added `dns_search` array support, validation for restart/platform/runtime/volumes/ports                                                                                                                                                                                                                                                                                                       |
| Added+Modified | `Sources/Container-Compose/Commands/CheckpointCommand.swift`              | Checkpoint command using `container commit`; post-creation P0 error handling fixes                                                                                                                                                                                                                                                                                                            |
| Modified       | `Sources/Container-Compose/Commands/ComposeDown.swift`                    | Added try/throw support for deriveProjectName, `-f` flag with absolute/relative path handling, `--timeout-seconds` with graceful→force escalation, `.container-compose.state` for idempotent teardown, `DownResult` exit codes (0=clean, 1=timeout, 2=fatal)                                                                                                                                  |
| Modified       | `Sources/Container-Compose/Commands/ComposeUp.swift`                      | Refactored with `makeRunArgs`, added 8 field mappings, StopOldStuffError, VolumeConfigError, CPU validation, pre-decode `${VAR}` substitution, `--force-recreate`/`--no-recreate`, `__SERVICE_HOST__`/`__SERVICE_PORT__` resolution, `-f` flag, `--recover` mode with drift detection, `waitForCompletedSuccessfully()` for `service_completed_successfully`, virtiofs database path warnings |
| Modified       | `Sources/Container-Compose/Commands/Version.swift`                        | Version display with git commit hash                                                                                                                                                                                                                                                                                                                                                          |
| Modified       | `Sources/Container-Compose/Errors.swift`                                  | Added `invalidResourceConfig`, `DependencyFailedError` error cases                                                                                                                                                                                                                                                                                                                            |
| Added          | `Sources/Container-Compose/Commands/ComposePs.swift`                      | `container-compose ps` command: service-to-container matching, table/JSON output, service filter, exit codes                                                                                                                                                                                                                                                                                  |
| Added          | `Sources/Container-Compose/Commands/HealthCommand.swift`                  | `container-compose health` command: container health polling via `container exec`, table/JSON/watch output, service filtering                                                                                                                                                                                                                                                                 |
| Modified       | `Sources/Container-Compose/Helper Functions.swift`                        | P0/P2 fixes: safe regex handling, VariableResolutionError, deriveProjectName sanitization, env_file error handling, `resolveYamlVariables()` with `$$` escaping                                                                                                                                                                                                                               |
| Added          | `Tests/Container-Compose-StaticTests/CheckpointCommandTests.swift`        | Unit tests for checkpoint command                                                                                                                                                                                                                                                                                                                                                             |
| Added+Modified | `Tests/Container-Compose-StaticTests/ComposeUpMappingTests.swift`         | Mapping tests for makeRunArgs flag generation, `-f` path resolution, `--recover` mutual exclusivity.                                                                                                                                                                                                                                                                                          |
| Added          | `Tests/Container-Compose-StaticTests/NetworkVolumeMappingTests.swift`     | Network and volume synchronization tests                                                                                                                                                                                                                                                                                                                                                      |
| Modified       | `Tests/Container-Compose-DynamicTests/ComposeDownTests.swift`             | Updated for 3-container WordPress setup                                                                                                                                                                                                                                                                                                                                                       |
| Modified       | `Tests/Container-Compose-DynamicTests/ComposeUpTests.swift`               | Updated for WordPress FPM variant, port-agnostic assertions, Feature 1 & 2 integration tests                                                                                                                                                                                                                                                                                                  |
| Modified       | `Tests/Container-Compose-DynamicTests/ComposeAdvancedTests.swift`         | Fixed YAML string interpolation, added `getZotRegistryURL()` helper for custom registry configuration                                                                                                                                                                                                                                                                                         |
| Modified       | `Tests/Container-Compose-StaticTests/BuildConfigurationTests.swift`       | Added build target tests                                                                                                                                                                                                                                                                                                                                                                      |
| Modified       | `Tests/Container-Compose-StaticTests/DockerComposeParsingTests.swift`     | Replaced force unwraps with guard statements                                                                                                                                                                                                                                                                                                                                                  |
| Modified       | `Tests/Container-Compose-StaticTests/EnvFileLoadingTests.swift`           | .env file loading tests                                                                                                                                                                                                                                                                                                                                                                       |
| Modified       | `Tests/Container-Compose-StaticTests/EnvironmentVariableTests.swift`      | Environment variable tests                                                                                                                                                                                                                                                                                                                                                                    |
| Modified       | `Tests/Container-Compose-StaticTests/HealthcheckConfigurationTests.swift` | Healthcheck configuration tests                                                                                                                                                                                                                                                                                                                                                               |
| Modified       | `Tests/Container-Compose-StaticTests/HelperFunctionsTests.swift`          | deriveProjectName tests                                                                                                                                                                                                                                                                                                                                                                       |
| Modified       | `Tests/Container-Compose-StaticTests/ServiceDependencyTests.swift`        | Service dependency tests                                                                                                                                                                                                                                                                                                                                                                      |
| Modified       | `Tests/TestHelpers/DockerComposeYamlFiles.swift`                          | Configurable test ports via environment variables                                                                                                                                                                                                                                                                                                                                             |
| Added          | `Tests/Container-Compose-StaticTests/ComposePsMappingTests.swift`         | 40 static tests: PsStatus model, service-to-container matching, table/JSON formatting, summary                                                                                                                                                                                                                                                                                                |
| Added          | `Tests/Container-Compose-DynamicTests/ComposePsTests.swift`               | 8 dynamic tests: real container ps output, filter, JSON, exit codes                                                                                                                                                                                                                                                                                                                           |
| Added          | `Tests/Container-Compose-DynamicTests/HealthCommandTests.swift`           | Dynamic tests: health polling, watch mode, service filtering                                                                                                                                                                                                                                                                                                                                  |
| Added          | `Tests/TestHelpers/ContainerPollingHelpers.swift`                         | Async container state polling helpers for robust network validation                                                                                                                                                                                                                                                                                                                           |
| Added          | `Tests/compose_static_checks.sh`                                          | Static validation script for compose files                                                                                                                                                                                                                                                                                                                                                    |
| Added          | `Tests/network_reachability.sh`                                           | Network connectivity testing script                                                                                                                                                                                                                                                                                                                                                           |
| Added          | `docs/checkpoint.md`                                                      | Documentation for checkpoint feature                                                                                                                                                                                                                                                                                                                                                          |

### Deleted Files (existed in fork history, now removed)

| File                          | Reason                                        |
| ----------------------------- | --------------------------------------------- |
| `ADVERSARIAL_REVIEW_FIXES.md` | Audit findings resolved, folded into codebase |
| `DYNAMIC_TEST_ANALYSIS.md`    | Analysis superseded by stabilized test suite  |
| `build-and-install.sh`        | Consolidated into `build-sign-install.sh`     |
| `docs/FORK_README_UPDATE.md`  | Merged into `FORK_CHANGES.md`                 |

---

## Detailed Change History

### Notable Patches (with upstream links)

- **fix: remove RuntimeStatus type that doesn't exist** (commit: c509a2f)
  - Removes a reference to a RuntimeStatus type that wasn't present in the container library

- **fixed incorrect waiting for running container** (commit: 8a4e5bb)
  - [Upstream commit](https://github.com/Mcrich23/Container-Compose/commit/8a4e5bb0e634155d122ac5d93905a75dcbf5b3da)
  - Fixes wait logic so waiting for container startup no longer always times out

- **removed 30 second timeout when container already started** (commit: eeddb26)
  - [Upstream commit](https://github.com/Mcrich23/Container-Compose/commit/eeddb266a45686c99f53f300c2c5d049b1f3b157)
  - Removes unnecessary fixed timeout when container is already running

- **added support for dnsSearch** (commit: d509f8a)
  - [Upstream commit](https://github.com/Mcrich23/Container-Compose/commit/d509f8af30f9d2382c1804f575ea0f22eb4e5734)
  - Adds dns_search/dnsSearch support for service name resolution with custom DNS search domains

- **added support for multi stage build target** (commit: 02ca646)
  - [Upstream commit](https://github.com/Mcrich23/Container-Compose/commit/02ca6462b84121c1553bd7adb862ee22aabc4997)
  - Adds support for specifying a build target (multi-stage Dockerfile target)

- **added information about what command is being run** (commit: 4968a86)
  - [Upstream commit](https://github.com/Mcrich23/Container-Compose/commit/4968a8669babe7822ada82cc90328f102edfd02e)
  - Outputs the exact container tool command being executed for debugging

- **fix: place --entrypoint flag before image name** (commit: 84201f9)
  - [Upstream commit](https://github.com/Mcrich23/Container-Compose/commit/84201f9416f4a5f1bd383763679f8e2fd7579e94)
  - Ensures --entrypoint is passed before the image name for proper interpretation

- **test: add named volume full path preservation test** (commit: 8edb8a9)
  - [Upstream commit](https://github.com/Mcrich23/Container-Compose/commit/8edb8a9be0cb5b820eca78c86d6a70b79ac459c1)
  - Adds unit/regression tests to preserve full destination paths for named volumes

- **fix: use full destination path for named volumes** (commit: b1badf8)
  - [Upstream commit](https://github.com/Mcrich23/Container-Compose/commit/b1badf86a4faf5c6ed512643e255760073d38988)
  - Corrects handling of named volume destination paths

- **CI / release workflow additions** (commits: 3f20dbf, 98b7fc4, 1d284fb)
  - GitHub Actions workflows for release automation

- **v0.10.0 Features:**
  - **Standardized Argument Construction**: Refactored `ComposeUp.swift` with centralized `makeRunArgs` helper
  - **Entrypoint Positioning**: Fixed `--entrypoint` placement relative to image name
  - **Shared Utilities**: Extracted `streamCommand` and `deriveProjectName` into `Helper Functions.swift`
  - **Service Property Restoration**: Restored `runtime`, `init`, and `init_image` support in `Service.swift`
  - **Checkpoint Subcommand**: Added `container-compose checkpoint <service>` using `container commit`
  - **Mapping Tests**: Added `ComposeUpMappingTests` for flag generation validation
  - **Network/Volume Sync**: Improved synchronization of network and volume definitions

- **Unreleased Features & Fixes:**
  - **Pre-decode `${VAR}` substitution**: `resolveYamlVariables()` resolves environment variables in raw YAML before decode, enabling `${VAR}` in `image:`, `volumes:`, `command:`, etc. Supports `${VAR:-default}` and `${VAR:?error}` with Docker Compose-compatible `$$` escaping for literal `$`.
  - **`__SERVICE_HOST__` / `__SERVICE_PORT__` resolution**: Runtime container IPs and ports resolved for `__{NAME}_HOST__` and `__{NAME}_PORT__` patterns in env values with fuzzy matching.
  - **Container runtime diagnostics**: Test trait reports API server version, commit, and EUID.
  - **Idempotent compose up**: `--force-recreate` and `--no-recreate` flags.
  - **Build tooling**: Auto git hash injection in `build-sign-install.sh`, `/usr/local/bin` symlink maintenance.
  - **Test improvements**: Shortened container prefix, 128 static tests + 9 dynamic tests passing.
  - **`${VAR}` pipeline fix**: Replaced naive `${` stripping with `resolveVariable()` for proper default/error syntax.

- **v0.10.2 Fixes:**
- **Service-level volume mapping**: Fixed critical bug where `service.volumes` entries were parsed from YAML but never generated `-v` flags for `container run`. Integrated volume handling into `makeRunArgs()` with support for bind mounts and named volumes. Removed dead `configVolume()` function. Added 4 new mapping tests.
- **Healthcheck-aware depends_on**: Implemented `waitForHealthy()` in `ComposeUp.swift` that polls a dependency's healthcheck command via `container exec` before starting dependent services. Supports CMD, CMD-SHELL, and NONE formats with configurable interval/timeout/retries/start_period.
- **Container polling helpers**: Added `ContainerPollingHelpers.swift` to `TestHelpers` module providing async polling for container state verification (networks, status) with proper error handling and timeouts. Re-enabled `testThreeTierWebApp()` with safe network assertions replacing force unwraps.
  - **Fixed `container exec` syntax**: Apple's `container exec` does not use `--` separator (unlike Docker). Updated exec arg construction to match Apple CLI format.
  - **Shorthand `env:` Key Support**: Fixed critical bug where `env:` shorthand was not decoded. Now properly recognized as alias for `environment:` (env takes precedence when both present)
  - **Environment Variable Test Fix**: Fixed `HOST` variable conflict in tests by using unique names (`DB_HOST`, `DB_PORT`, `DB_NAME`)
  - **Volume Creation Idempotency**: Gracefully handle "already exists" errors during volume creation
  - **Command String Parsing**: Split string-form commands into proper executable + arguments array
  - **Environment Variable Mapping**: Added `--env` flag mapping to pass service env vars to containers
  - **Port Mapping**: Added missing `--publish` flag mapping in `makeRunArgs` for service port mappings
  - **Test Suite Stabilization**: Achieved 100% test pass rate (141/141 static + 9/9 dynamic) by resolving naming, port, image compatibility, and volume mapping issues.

- **v0.10.1 Fixes:**
  - **Restart stopped containers on compose up**: When containers exist but are stopped, automatically start them instead of returning an error
  - **Static checks**: Added `compose_static_checks.sh` for compose file validation
  - **Network reachability**: Added `network_reachability.sh` for DNS and connectivity testing

- **v0.10.3 — Orchestration Hardening (Plan 65):**
  - **Phase 1 — `--recover` mode**: Crash recovery for compose projects. Detects existing containers, skips running ones, starts stopped ones, creates missing ones, respects dependency order. Replaces 200-line orchestrator scripts with `container-compose up --recover -f compose.yml`.
  - **Phase 2a — Dependency chain halt**: `waitForCompletedSuccessfully()` blocks dependents when a container exits with non-zero code. 6 static tests.
  - **Phase 2b — `service_completed_successfully` condition**: Compose file support for `depends_on: { service: { condition: service_completed_successfully } }`. 8 static tests.
  - **Phase 3 — Virtiofs database path warnings**: Warns on named volumes with DB-like paths (`postgres`, `mysql`, `mongodb`, `data`) under virtiofs, where `chmod`/`chown` will fail.
  - **Phase 4 — `container-compose health` command**: Container health polling via `container exec`, table/JSON/watch output modes, service filtering, exit codes (0=healthy, 1=unhealthy, 2=error).
  - **Phase 5a — `container-compose down` timeout hardening**: `--timeout-seconds N` flag with graceful→force escalation. `.container-compose.state` file for idempotent teardown across interrupted runs. `DownResult` exit codes (0=clean, 1=timeout, 2=fatal).
  - **Phase 6 — `container-compose ps` command**: Service-to-container matching by `container_name` override or `{project}-{service}` convention. Table/JSON output, service filter, exit codes, summary line. 40 static tests + 8 dynamic tests.
  - **Test suite**: 188 total tests (141 static + 8 dynamic passing + 1 skip + 1 disabled).

---

## Fork-Only Features (not yet upstreamed)

These features are present in this fork but not in `apple/container` v0.10.0:

1. **RuntimeStatus type removal** (c509a2f)
2. **Container wait logic fixes** (8a4e5bb, eeddb26)
3. **dnsSearch / dns_search support** (d509f8a)
4. **Multi-stage build target support** (02ca646)
5. **Debug output for CLI commands** (4968a86)
6. **Entrypoint flag positioning fix** (84201f9)
7. **Named volume full-path preservation** (b1badf8, 8edb8a9)
8. **Checkpoint command** (v0.10.0)
9. **Restart stopped containers** (v0.10.1)
10. **`--recover` mode** (v0.10.3) — crash recovery: skip running, start stopped, create missing, respect dependency order
11. **`service_completed_successfully` condition** (v0.10.3) — halt dependency chain on non-zero container exit
12. **`container-compose health` command** (v0.10.3) — container health polling via `container exec`, table/JSON/watch output
13. **`container-compose ps` command** (v0.10.3) — service status table, JSON output, service filter, exit codes
14. **`container-compose down` timeout** (v0.10.3) — `--timeout-seconds` with graceful→force escalation, `.container-compose.state` for idempotent teardown
15. **Virtiofs database path warnings** (v0.10.3) — warn on named volumes with DB-like paths under virtiofs

---

## Proposed Features & Roadmap

Based on analysis of `apple/container` v0.11.0 upcoming features and current fork capabilities.

---

## v0.11.x Architecture: External Dependency Contract

### The Dependency Contract

`container-compose` distinguishes dependencies by ownership:

| Type         | Ownership                     | Lifecycle               | Gating                      | Pattern                         |
| ------------ | ----------------------------- | ----------------------- | --------------------------- | ------------------------------- |
| **Internal** | Managed by compose            | Create/Start/Destroy    | `service_healthy` supported | Orchestrator verifies readiness |
| **External** | Host/Another project/Hardware | Persistent, independent | Addressable-only            | App-level retries               |

### Implementation Spec (v0.11.x Target)

| Component             | Change                                                                     | UX Impact                |
| --------------------- | -------------------------------------------------------------------------- | ------------------------ |
| **Parser**            | `external: true` strips `healthcheck` blocks                               | Prevents accidental hang |
| **Dependency Engine** | `condition: service_healthy` → error/warning for externals                 | Fail-fast behavior       |
| **Resolver**          | `__SERVICE_HOST__` resolved before runtime                                 | Enables late-binding     |
| **CLI/Logs**          | `[WARN] 'db' is external. Ignoring health-gate; ensure app-level retries.` | Educates user            |

### Best Practice: Render-Time Injection

For external services, use pre-processing to resolve host-specific endpoints:

```yaml
# Before render (template)
services:
  app:
    environment:
      DATABASE_URL: postgres://${DB_USER}:${DB_PASSWORD}@${EXTERNAL_DB_HOST}:${DB_PORT}/mydb
    depends_on:
      - db # Short form only - no health gating


# render-script.py resolves ${EXTERNAL_DB_HOST} before compose up
```

### Preflight TCP Check (Optional)

Soft check with short timeout:

- **Logic:** `nc -z ${HOST} ${PORT}` (500ms timeout)
- **Result:** Log `[INFO] External service 'db' not reachable on port 15432. Proceeding anyway...`
- **Rationale:** Don't block deployment for momentary network issues; app handles retries

---

### Current Status (v0.10.3)

| Feature                                                 | Status               | Upstream Version | Production Validated               |
| ------------------------------------------------------- | -------------------- | ---------------- | ---------------------------------- |
| `init`/`init_image` support                             | ✅ Complete          | v0.10.0          | Yes                                |
| `runtime` flag                                          | ✅ Complete          | v0.10.0          | Yes                                |
| Checkpoint command                                      | ✅ Complete          | v0.10.0          | No                                 |
| Restart stopped containers                              | ✅ Complete          | v0.10.1          | Yes (post-crash)                   |
| Multi-stage build target                                | ✅ Complete          | Fork-only        | No                                 |
| `dns_search` support                                    | ✅ Complete          | Fork-only        | Yes                                |
| Pre-decode `${VAR}` substitution                        | ✅ Complete          | Unreleased       | Yes (replaces renderer)            |
| `service_healthy` dependency enforcement                | ✅ Complete          | Unreleased       | Yes (compose-managed only)         |
| `__SERVICE_HOST__`/`__SERVICE_PORT__` resolution        | ✅ Complete          | Unreleased       | Yes                                |
| External dependency fail-fast                           | ✅ Complete          | v0.10.3          | Yes                                |
| External dependency health-gating skip (crash recovery) | ✅ Complete          | Unreleased       | Yes (post-crash)                   |
| `-f` / `--file` flag                                    | ✅ Complete          | Unreleased       | Yes (use long form)                |
| `--recover` mode                                        | ✅ Complete          | Fork-only        | Yes (post-crash)                   |
| `service_completed_successfully` condition              | ✅ Complete          | Fork-only        | Yes (Phase 2b)                     |
| `container-compose health` command                      | ✅ Complete          | Fork-only        | Yes (Phase 4)                      |
| `container-compose ps` command                          | ✅ Complete          | Fork-only        | Yes (Phase 6)                      |
| `container-compose down` timeout + state file           | ✅ Complete          | Fork-only        | Yes (Phase 5a)                     |
| Virtiofs database path warnings                         | ✅ Complete          | Fork-only        | Yes (Phase 3)                      |
| File volume mounts                                      | ⚠️ Warning           | —                | Warning logged, mount attempted    |
| `--env-file` support                                    | ❌ Missing           | —                | Workaround: render env vars        |
| Named volume recreation (skip if exists)                | ❌ Error             | —                | Workaround: pre-create             |
| Multi-service changed-only restart                      | ❌ All restart       | —                | Workaround: per-service render     |
| Named volume virtiofs chmod/chown                       | ❌ Permission denied | —                | Workaround: `container run` for DB |

### Container Runtime v0.11.0 (Released 2026-03-31)

[Release notes](https://github.com/apple/container/releases/tag/0.11.0) — no breaking CLI or API changes.

#### Landed in v0.11.0

| Feature                              | Upstream PR | Compose Impact                                         | Fork Action                                 |
| ------------------------------------ | ----------- | ------------------------------------------------------ | ------------------------------------------- |
| Build secrets support                | #1300       | Add `secrets:` to `build:` config                      | Extend `Build.swift` with secrets array     |
| Network MTU configuration            | #1267       | Add `mtu:` to network definitions                      | Update `Network.swift` with MTU field       |
| Default CPUs/memory (container)      | #1266       | System properties set defaults                         | May affect `makeRunArgs()` resource flags   |
| Default CPUs/memory (builder)        | #1293       | System properties set defaults                         | May affect build resource allocation        |
| CONTAINER_DEFAULT_PLATFORM           | #1286       | Default image platform selection                       | Evaluate if fork needs explicit arch flag   |
| Checkpoint export as OCI tar         | #1303       | Breaking change to checkpoint format                   | Update `CheckpointCommand.swift`            |
| Dockerfile ignore files              | #1273       | `.dockerignore` per Dockerfile                         | No compose change needed                    |
| ARG parsing fixes                    | #1342       | Build arg resolution                                   | Verify existing `${VAR}` handling           |
| Auto-remove container prune on start | #1290       | Reaps orphaned auto-remove containers                  | No compose change needed                    |
| Rootfs override                      | #1323       | Custom init filesystem per service                     | Evaluate for compose integration            |
| Registry resource (auth)             | #1195       | Native registry authentication                         | Spike to deprecate fork registry handling   |
| Volumes allow "."                    | #1326       | Current directory as volume source                     | No compose change needed                    |
| Container lifecycle hang fixes       | Multiple    | Addresses XPC timeout issues                           | May reduce need for `--timeout-seconds`     |
| CLI stop/delete error on not found   | #878        | `container stop`/`delete` error instead of silent fail | Scripts should handle exit codes explicitly |
| Containerization 0.29.0              | #1327       | Runtime dependency bump                                | Required for build secrets                  |

#### Not Yet Landed (Deferred to v0.12.0+)

| Feature                                     | Upstream PR  | Notes                                       |
| ------------------------------------------- | ------------ | ------------------------------------------- |
| High-Performance File Transfer              | #1190        | `container cp` for sync/hot-reload          |
| Advanced Networking                         | #1151        | Multi-plugin network support                |
| Auto-Start (LaunchAgent)                    | #1176, #1201 | Boot service installation                   |
| Robust Service Lifecycle (Restart Policies) | #1258        | `restart: always/on-failure/unless-stopped` |

### Crash Recovery Mode (v0.10.3)

**Implemented in v0.10.3 (Plan 65 Phase 1).** See `container-compose up --recover --help` for usage.

The `--recover` flag is the single highest-impact feature for production use. After a macOS crash, the current recovery path requires a 200-line orchestrator script that checks each container individually, skips running ones, starts missing ones, and manages startup order manually.

#### Spec: `container-compose up --recover`

| Behavior                            | Description                                                                                       |
| ----------------------------------- | ------------------------------------------------------------------------------------------------- |
| **Detect existing containers**      | Scan for containers with matching project+service names                                           |
| **Skip running containers**         | Don't attempt to recreate or restart already-running services                                     |
| **Start stopped containers**        | `container start` for containers that exist but are stopped                                       |
| **Create missing containers**       | `container run` for services with no existing container                                           |
| **Respect dependency order**        | Topological sort ensures dependencies start before dependents                                     |
| **Skip health-gates for externals** | Don't wait for `service_healthy` on pre-existing containers (v0.10.3 already does this partially) |
| **Idempotent**                      | Safe to run multiple times — no-op if all services are running                                    |

#### Recovery Path Comparison

| Step              | Current (orchestrator script)                   | With `--recover`                                |
| ----------------- | ----------------------------------------------- | ----------------------------------------------- |
| 1                 | Check if DB exists → `container run` or skip    | `container-compose up --recover -f compose.yml` |
| 2                 | Check if hub exists → `container-compose up`    | Single command handles all services             |
| 3                 | Check if hermes exists → `container-compose up` | Automatic dependency ordering                   |
| 4                 | Start 4 derivers individually                   | All services recovered in one pass              |
| 5                 | Verify all running                              | Built-in status reporting                       |
| **Lines of code** | ~200 (shell script)                             | **1 command**                                   |

### Compose Orchestration Gaps

Features currently worked around in external orchestrator scripts (e.g., `apple-container-honcho-compose.sh`).
Updated 2026-04-02 after macOS crash recovery effort revealed critical gaps in crash resilience.

#### Real Gap

| Gap                                      | Current Workaround                                            | Impact                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Priority         |
| ---------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| **`--recover` mode**                     | ~~200-line orchestrator script~~ — **RESOLVED**               | ~~**No single-command crash recovery.**~~ **Resolved in v0.10.3.** `container-compose up --recover -f compose.yml` detects existing containers, skips running ones, starts stopped ones, creates missing ones, respects dependency order. Replaces the 200-line orchestrator script with one command. See Plan 65 Phase 1.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | ~~**Critical**~~ |
| **`container restart`**                  | External watchdog scripts                                     | No native restart policy enforcement after crashes; `restart: always/on-failure` is parsed but cannot be delegated to runtime                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | High             |
| **Digest-pinned images**                 | Zot mirror with stable tag (`honcho-hub:stable`)              | `container-compose` strips `@sha256:...` suffix from image references and pulls `:latest` instead, defeating digest-based pinning. Workaround: copy pinned image to local Zot with a stable tag and reference that tag. This breaks on Zot registries that return HTTP 400 for Docker v2 pull API.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | **High**         |
| **Service bind-mount volumes**           | Render compose with patches in `command`                      | `configVolume()` function exists as dead code in `ComposeUp.swift:839` (parses paths, validates traversal, generates `-v` args) but is never called from `makeRunArgs()`. Service-level `volumes:` entries are parsed into `service.volumes` but zero `-v`/`--mount` flags are generated for `container run`. File mounts are explicitly skipped with a warning (line 880). Directory mounts generate `-v` but mode (`:ro`) is stripped. All bind mounts silently ignored. **Workaround pattern**: A Python render script (`render-honcho-compose.py`) injects live-patches into the compose `command:` block before `container-compose up`. This enables a "Circuit Breaker" that skips Alembic migrations when the database schema already exists, preventing data loss on image updates. To force migrations when needed, set `HONCHO_FORCE_MIGRATION=1` on the hub service. | **High**         |
| **`container cp`**                       | Volume mounts for all file sharing                            | No hot-reload or file sync capability; limits dev workflow                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | High             |
| **`container wait`**                     | Polling with `container list`                                 | Cannot efficiently block until a container exits; adds latency to shutdown orchestration                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Medium           |
| **`container-compose down` XPC timeout** | ~~`container stop` + `container rm` manually~~ — **RESOLVED** | ~~`container-compose down` fails with `internalError: "XPC timeout"`~~ **Resolved in v0.10.3.** `container-compose down --timeout-seconds 30` uses graceful→force escalation. `.container-compose.state` file tracks teardown state for idempotent recovery. See Plan 65 Phase 5a.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | ~~**High**~~     |
| **Multi-service restart scope**          | Per-service rendered compose                                  | `container-compose up` restarts ALL services in the compose file even when only one changed. docker compose only restarts changed services. **Workaround**: Render per-service compose files (one service per file) and run `container-compose up -d <service>` individually. The orchestrator's `render_compose()` function strips all non-target services.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Medium           |
| **File volume mount (single file)**      | `container run` instead of compose                            | `container-compose` logs a warning and attempts the mount anyway: `Warning: Volume mount source '/path/to/file' is a file. The 'container' tool does not support direct file mounts. Skipping this volume.` Hermes kubeconfig still requires `container run` workaround.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | **High**         |
| **Named volume recreation error**        | `container volume create` before compose                      | `container-compose` errors when a named volume already exists. docker compose gracefully skips. **Workaround**: Run `container volume create <name>` before `container-compose up` in the orchestrator.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Medium           |
| **`--env-file` support**                 | Render env vars into compose file                             | `container-compose` does not support `--env-file` for loading `.env` files. All env vars must be in the compose file's `environment:` block or host env. **Workaround**: Python `render_compose()` resolves secrets from 1Password Connect and bakes them into the rendered YAML.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Medium           |
| **Named volume virtiofs chmod failure**  | `container run` for DB (Phase 1)                              | `container-compose` converts named volumes to host directory bind mounts via virtiofs, where `chmod`/`chown` fails. PostgreSQL's entrypoint requires chmod/chown on the data directory. `container run` uses the native ext4 volume driver where this works. **Workaround**: Two-phase startup — DB via `container run`, all other services via `container-compose`. This is the single biggest architectural constraint on the Honcho stack.                                                                                                                                                                                                                                                                                                                                                                                                                                   | **High**         |

#### Non-Gaps (already supported by container-compose)

The orchestrator script works around several features that container-compose already implements natively:

| Feature                                                | Container-Compose Support                                                                                                                                                                                                                    | Orchestrator Workaround (unnecessary)                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`-f` flag**                                          | `-f` on `ComposeUp` and `ComposeDown`; accepts absolute or relative paths, skips CWD scanning when explicit                                                                                                                                  | Symlink desired file to `compose.yml` before each call                                                                                                                                                                                                                                                                                                                                                                          |
| **`${VAR}` interpolation**                             | `resolveYamlVariables()` in `Helper Functions.swift` resolves `${VAR}`, `${VAR:-default}`, `${VAR:?error}` on raw YAML before decode (Docker Compose compatible with `$$` escaping)                                                          | Python pre-renders compose file with `os.environ` substitution                                                                                                                                                                                                                                                                                                                                                                  |
| **`depends_on` ordering**                              | `Service.topoSortConfiguredServices()` does topological sort at `ComposeUp.swift:147`; `waitForHealthy()` gates `service_healthy` dependencies                                                                                               | Manual sequential `container-compose up -d <service>` calls                                                                                                                                                                                                                                                                                                                                                                     |
| **`service_healthy` on externally managed containers** | `waitForHealthy()` now verifies container exists before health polling (v0.10.3)                                                                                                                                                             | **Mitigated**: Now fails fast with `ContainerNotFoundError` if dependency container doesn't exist. **Root cause remains**: For externally managed containers (started outside compose), use `depends_on: [service_name]` (short form) instead of `depends_on: { service_name: { condition: service_healthy } }`. The `service_healthy` condition assumes compose owns the dependency's lifecycle and healthcheck configuration. |
| **Partial compose / volumes**                          | `setupVolume()` handles "already exists" gracefully; **top-level** named volumes created idempotently per compose file. Service-level `volumes:` are parsed but never wired to `container run` args (dead code `configVolume()` at line 839) | Regex-based stripping of `volumes:` and single-service extraction; orchestrator renders patches into `command` instead                                                                                                                                                                                                                                                                                                          |

### Compatibility & Migration

#### v0.10.x → v0.11.0 Migration

**No breaking CLI or API changes.** Safe to upgrade with containers running — existing containers continue on the old runtime until stopped and restarted.

**Behavioral Changes:**

- Checkpoint export format changes (#1303) — checkpoint files may need migration
- `container stop`/`delete` now error on not-found containers (#878) — scripts should handle exit codes explicitly
- Default CPUs/memory set via system properties (#1266, #1293) — may affect resource allocation on next `container run`/`container-compose up`
- Auto-remove containers reaped on system start (#1290) — orphaned auto-remove containers cleaned up

**New Capabilities Available:**

- Build secrets via `container build --secret` (#1300)
- Network MTU via `--network ...mtu=N` (#1267)
- `CONTAINER_DEFAULT_PLATFORM` env var for image arch selection (#1286)
- Rootfs override per container (#1323)
- Registry resource for authentication (#1195)
- Volumes allow "." as source (#1326)

**Deprecations:**

- Evaluate removing fork registry auth if #1195 meets needs

**New Dependencies:**

- Containerization 0.29.0 (bundled with v0.11.0)
- Swift tools version unchanged (v5.9+)

### Testing Requirements

| Feature           | Test Priority | Type                |
| ----------------- | ------------- | ------------------- |
| Build secrets     | High          | Integration         |
| Network MTU       | Medium        | Unit + Network      |
| Resource limits   | High          | Resource validation |
| Checkpoint export | High          | Migration/compat    |
| RegistryResource  | Medium        | Auth flows          |
| Rootfs override   | Low           | Integration         |
| v0.11.0 compat    | High          | Full suite          |

### Upstreaming Strategy

**Ready to upstream:**

- [ ] `dns_search` support (if not in v0.11.0)
- [ ] Build `target` field
- [ ] Named volume full-path preservation

**Blocked on upstream:**

- Restart policies (waiting for #1258)
- `container cp` integration (waiting for #1190)

**Fork-only:**

- Checkpoint command (compose-specific)
- Restart stopped containers (compose lifecycle)
- Debug output formatting

---

## Testing Matrix

| Feature                 | Test Coverage                                                  | Priority |
| ----------------------- | -------------------------------------------------------------- | -------- |
| **Persistence**         | Named volumes, full path preservation                          | High     |
| **Security**            | SELinux compatibility, build secrets                           | High     |
| **Reliability**         | Memory validation, restart policies, stopped container restart | High     |
| **Networking**          | DNS search, network reachability, MTU configuration            | Medium   |
| **Build**               | Multi-stage targets, build secrets, resource limits            | High     |
| **Lifecycle**           | Checkpoint export/import, container restart                    | High     |
| **Orchestration**       | healthcheck-aware `depends_on`                                 | High     |
| **Registry**            | Authentication, push/pull                                      | Medium   |
| **Test Infrastructure** | Container polling helpers, async state verification            | High     |

---

## TODOs

- [ ] Create detailed CHANGELOG.md with migration notes
- [ ] Update README and CLI --help strings for fork-only features
- [ ] Audit tests for upstream v0.11.0 compatibility
- [ ] Add build secrets support to `Build.swift` (v0.11.0 upstream #1300)
- [ ] Add network MTU to `Network.swift` (v0.11.0 upstream #1267)
- [ ] Spike RegistryResource (#1195) to evaluate deprecating fork registry auth
- [ ] Update `CheckpointCommand.swift` for OCI tar export format (v0.11.0 #1303)
- [ ] Consider upstreaming: dns_search, build.target, entrypoint fix, named-volume behavior
- [x] Implement healthcheck-aware `depends_on` (wait for dependency healthy before starting dependents)
- [x] Fix `service_healthy` handling for externally managed existing containers (v0.10.3: crash recovery detection skips health-gates)
- [x] **Implement `--recover` mode** (v0.10.3 Plan 65 Phase 1) — detect existing running containers, skip them, start missing ones, respect dependency order
- [x] Fix XPC timeout on `container-compose down` for long-running containers (v0.10.3 Plan 65 Phase 5a — graceful→force escalation, state file)
- [x] Add file volume mount support (v0.10.3 — warning logged, mount attempted)
- [x] Add `container-compose health` command (v0.10.3 Plan 65 Phase 4)
- [x] Add `container-compose ps` command (v0.10.3 Plan 65 Phase 6)
- [x] Add `service_completed_successfully` condition (v0.10.3 Plan 65 Phase 2b)
- [x] Add virtiofs database path warnings (v0.10.3 Plan 65 Phase 3)
- [ ] Add `--env-file` support for `.env` file loading
- [ ] Implement changed-service-only restart (skip services with identical config)
- [ ] Fix named volume "already exists" error (skip gracefully like docker compose)
- [ ] Investigate virtiofs chmod/chown failure for named volumes (PostgreSQL use case)

---

## Feature Requests for Apple Containers (`container` CLI)

Features missing or incompatible in Apple's `container` CLI relative to Docker that block or complicate compose orchestration.

### High Priority — Blocks Core Compose Features

| Feature                 | Docker CLI                           | Apple `container` CLI                                                                | Impact on Compose                                                                     |
| ----------------------- | ------------------------------------ | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| **`exec --` separator** | `docker exec <id> -- cmd args`       | No `--` support; args go directly after container ID: `container exec <id> cmd args` | Compose healthcheck execution must strip `--` from exec args (worked around in fork)  |
| **`container wait`**    | `docker wait <id>` returns exit code | Not implemented (`Plugin 'container-wait' not found`)                                | No way to block until a container exits; forces polling with `container list`         |
| **`container cp`**      | `docker cp <id>:src dest`            | Not implemented (`Plugin 'container-cp' not found`)                                  | No file sync or hot-reload; must use volume mounts for all file sharing               |
| **`container restart`** | `docker restart <id>`                | Not implemented (`Plugin 'container-restart' not found`)                             | Restart policies (`restart: always/on-failure`) cannot trigger restarts after crashes |
| **`container attach`**  | `docker attach <id>`                 | Not implemented (`Plugin 'container-attach' not found`)                              | Cannot reconnect to a container's stdin/stdout after detach                           |

### Medium Priority — Complicates Orchestration

| Feature                                             | Docker CLI                               | Apple `container` CLI                                    | Impact on Compose                                                                                                                        |
| --------------------------------------------------- | ---------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| **`container rename`**                              | `docker rename <old> <new>`              | Not implemented (`Plugin 'container-restart' not found`) | Cannot rename containers; must track original names                                                                                      |
| **`container health` / health status in `inspect`** | `docker inspect` returns `Health.Status` | No health status field in container metadata             | Compose must exec healthcheck commands manually via `container exec` (works, but native health state would avoid exec overhead per poll) |
| **`container logs --since` / `--tail`**             | `docker logs --tail 100 --since 1m`      | `container logs` lacks filtering flags                   | Cannot efficiently fetch recent logs for debugging                                                                                       |
| **`--restart` policy on `run`/`create`**            | `docker run --restart=always`            | Not present on `container run`                           | Compose `restart:` key cannot delegate to runtime; needs external watchdog                                                               |
| **`--hostname` on `run`/`create`**                  | `docker run --hostname foo`              | Not present on `container run`                           | Compose `hostname:` key must be handled via `/etc/hosts` volume mount workaround                                                         |

### Low Priority — Nice to Have

| Feature                        | Docker CLI                              | Apple `container` CLI                      | Impact on Compose                             |
| ------------------------------ | --------------------------------------- | ------------------------------------------ | --------------------------------------------- |
| **`--cap-add` / `--cap-drop`** | `docker run --cap-add SYS_PTRACE`       | Not present on `container run`             | Cannot configure Linux capabilities           |
| **`--security-opt`**           | `docker run --security-opt seccomp=...` | Not present on `container run`             | Cannot configure seccomp/AppArmor profiles    |
| **`--pid` (PID sharing)**      | `docker run --pid=container:id`         | Not present on `container run`             | Cannot share PID namespace between containers |
| **`--shm-size`**               | `docker run --shm-size=256m`            | Not present on `container run`             | Cannot configure shared memory size           |
| **`--tmpfs` with options**     | `docker run --tmpfs /run:rw,noexec`     | `container run --tmpfs` supports path only | Cannot set tmpfs mount options                |
| **`--gpus`**                   | `docker run --gpus all`                 | Not present on `container run`             | No GPU passthrough support                    |

### Syntax Incompatibilities (Implemented, Requires Workarounds)

| Feature                        | Docker Syntax                     | Apple `container` Syntax                                              | Workaround in Fork                                               |
| ------------------------------ | --------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------- |
| **`exec` argument separation** | `docker exec <id> -- cmd args`    | `container exec <id> cmd args`                                        | Strip `--` before passing to exec                                |
| **Volume bind mount format**   | `docker run -v src:dest:ro`       | `container run --mount type=bind,source=src,target=dest,readonly`     | Convert `-v` format to `--mount` format in `makeRunArgs`         |
| **Network attach format**      | `docker run --network foo`        | `container run --network foo[,mac=XX:XX:XX:XX:XX:XX]`                 | Direct mapping, no issue                                         |
| **Port publish format**        | `docker run -p 127.0.0.1:8080:80` | `container run --publish 8080:80` (no bind address in older versions) | Verified: `--publish 127.0.0.1:8080:80` works in current version |

---

## Related Upstream PRs

- Tests overhaul: https://github.com/Mcrich23/Container-Compose/pull/22
- Named volume fixes: https://github.com/Mcrich23/Container-Compose/pull/32, https://github.com/Mcrich23/Container-Compose/pull/42
- ComposeDown tests: https://github.com/Mcrich23/Container-Compose/pull/50
