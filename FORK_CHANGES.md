# Fork Changes Summary

This document summarizes all changes in this fork (`explicitcontextualunderstanding/Container-Compose`) relative to the upstream repository (`Mcrich23/Container-Compose`).

**Current Release:** v0.10.3
**Last Updated:** 2026-03-26

---

## Index of Changed Files

### New Files (Fork-Only)
| File | Purpose |
|------|---------|
| `.github/workflows/release.yml` | Automated release workflow |
| `CHANGELOG.md` | Version changelog |
| `ADVERSARIAL_REVIEW_FIXES.md` | Comprehensive security audit and fix documentation |
| `DYNAMIC_TEST_ANALYSIS.md` | Analysis of dynamic test failures |

### Known Runtime Limitations

#### Service Name Length
There is a clinical 64-character limit for guest process labels in the macOS container runtime. When using long project names or UUID-based prefixes (common in test suites), service names must be kept short to avoid `Invalid argument (Code 22)` errors.

- **Proactive Validation:** The orchestrator now warns users if a container name exceeds 63 characters during `up` and provides a detailed discussion in `--help`.
- **Port Isolation:** Dynamic tests now use a dedicated, non-overlapping port range (18080–18085) to prevent "Address already in use" errors during parallel execution.
- **Image Compatibility:** WordPress tests have been transitioned to `wordpress:fpm-alpine` to bypass `Virtualization.framework` syscall limitations.
- **Security Compliance:** Installation now targets `~/bin` with ad-hoc signing to ensure stability under macOS security policies.

- **Recommended Names:** `wp`, `db`, `web`.
- **Avoid:** Long descriptive names like `wordpress-application-service` if the combined length exceeds ~63 characters.

| File | Purpose |
|------|---------|
| `VERIFICATION.md` | Verification procedures and testing guidelines |
| `build-release.sh` | Release build script with conda/xattr cleanup |
| `build-and-install.sh` | Combined build+install script with codesign |
| `build-sign-install.sh` | Build, sign, install with auto git hash injection and `/usr/local/bin` symlink |
| `install.sh` | Installation script with macOS provenance handling |
| `run-tests.sh` | Test runner with conda environment cleanup |
| `Sources/Container-Compose/Commands/CheckpointCommand.swift` | New checkpoint command using `container commit` |
| `Sources/Container-Compose/Errors.swift` | Centralized error types and definitions |
| `Tests/Container-Compose-StaticTests/CheckpointCommandTests.swift` | Unit tests for checkpoint command |
| `Tests/Container-Compose-StaticTests/ComposeUpMappingTests.swift` | Mapping tests for restart/init/entrypoint flags |
| `Tests/Container-Compose-StaticTests/NetworkVolumeMappingTests.swift` | Network and volume synchronization tests |
| `Tests/Container-Compose-StaticTests/HelperFunctionsTests.swift` | Tests for helper functions like deriveProjectName |
| `Tests/Container-Compose-StaticTests/EnvironmentVariableTests.swift` | Environment variable parsing tests |
| `Tests/Container-Compose-StaticTests/EnvFileLoadingTests.swift` | .env file loading tests |
| `Tests/Container-Compose-StaticTests/NetworkConfigurationTests.swift` | Network configuration parsing tests |
| `Tests/Container-Compose-StaticTests/ServiceDependencyTests.swift` | Service dependency graph tests |
| `Tests/Container-Compose-StaticTests/HealthcheckConfigurationTests.swift` | Healthcheck configuration tests |
| `Tests/Container-Compose-DynamicTests/ComposeDownTests.swift` | Dynamic tests for compose down command |
| `Tests/compose_static_checks.sh` | Static validation script for compose files |
| `Tests/network_reachability.sh` | Network connectivity testing script |
| `docs/checkpoint.md` | Documentation for checkpoint feature |

### Modified Files
| File | Change Summary |
|------|--------------|
| `.github/workflows/tests.yml` | Enhanced CI workflow, added static test filtering |
| `Sources/Container-Compose/Application.swift` | Added checkpoint command registration, git hash in version string |
| `Sources/Container-Compose/Codable Structs/Build.swift` | Added `target` field for multi-stage builds |
| `Sources/Container-Compose/Codable Structs/Network.swift` | Enhanced network synchronization |
| `Sources/Container-Compose/Codable Structs/Service.swift` | Added `dns_search` array support, validation for restart/platform/runtime/volumes/ports |
| `Sources/Container-Compose/Commands/CheckpointCommand.swift` | P0 fixes: error handling, pre-flight checks, exit code validation |
| `Sources/Container-Compose/Commands/ComposeUp.swift` | Refactored with `makeRunArgs`, added 8 field mappings, StopOldStuffError, VolumeConfigError, CPU validation, pre-decode `${VAR}` substitution, `--force-recreate`/`--no-recreate`, `__SERVICE_HOST__`/`__SERVICE_PORT__` resolution |
| `Sources/Container-Compose/Commands/ComposeDown.swift` | Added try/throw support for deriveProjectName |
| `Sources/Container-Compose/Commands/Version.swift` | Version display with git commit hash |
| `Sources/Container-Compose/Errors.swift` | Added `invalidResourceConfig` error case |
| `Sources/Container-Compose/Helper Functions.swift` | P0/P2 fixes: safe regex handling, VariableResolutionError, deriveProjectName sanitization, env_file error handling, `resolveYamlVariables()` with `$$` escaping |
| `Tests/TestHelpers/DockerComposeYamlFiles.swift` | Configurable test ports via environment variables |
| `Tests/Container-Compose-DynamicTests/ComposeUpTests.swift` | Updated for WordPress FPM variant, port-agnostic assertions, Feature 1 & 2 integration tests |
| `Tests/Container-Compose-DynamicTests/ComposeDownTests.swift` | Updated for 3-container WordPress setup |
| `Tests/Container-Compose-StaticTests/BuildConfigurationTests.swift` | Added build target tests |
| `Tests/Container-Compose-StaticTests/DockerComposeParsingTests.swift` | Replaced force unwraps with guard statements |
| `Tests/Container-Compose-StaticTests/CheckpointCommandTests.swift` | Checkpoint command tests |
| `Tests/Container-Compose-StaticTests/ComposeUpMappingTests.swift` | Mapping tests for restart/init/entrypoint flags |
| `Tests/Container-Compose-StaticTests/EnvFileLoadingTests.swift` | .env file loading tests |
| `Tests/Container-Compose-StaticTests/EnvironmentVariableTests.swift` | Environment variable tests |
| `Tests/Container-Compose-StaticTests/HelperFunctionsTests.swift` | deriveProjectName tests |
| `Tests/Container-Compose-StaticTests/NetworkConfigurationTests.swift` | Network configuration tests |
| `Tests/Container-Compose-StaticTests/NetworkVolumeMappingTests.swift` | Network and volume mapping tests |
| `Tests/Container-Compose-StaticTests/ServiceDependencyTests.swift` | Service dependency tests |
| `Tests/Container-Compose-StaticTests/HealthcheckConfigurationTests.swift` | Healthcheck configuration tests |

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

- **v0.10.3 Features & Fixes:**
  - **Pre-decode `${VAR}` substitution**: `resolveYamlVariables()` resolves environment variables in raw YAML before decode, enabling `${VAR}` in `image:`, `volumes:`, `command:`, etc. Supports `${VAR:-default}` and `${VAR:?error}` with Docker Compose-compatible `$$` escaping for literal `$`.
  - **`__SERVICE_HOST__` / `__SERVICE_PORT__` resolution**: Runtime container IPs and ports resolved for `__{NAME}_HOST__` and `__{NAME}_PORT__` patterns in env values with fuzzy matching.
  - **Container runtime diagnostics**: Test trait reports API server version, commit, and EUID.
  - **Idempotent compose up**: `--force-recreate` and `--no-recreate` flags.
  - **Build tooling**: Auto git hash injection in `build-sign-install.sh`, `/usr/local/bin` symlink maintenance.
  - **Test improvements**: Shortened container prefix, 128 static tests + 9 dynamic tests passing.
  - **`${VAR}` pipeline fix**: Replaced naive `${` stripping with `resolveVariable()` for proper default/error syntax.

- **v0.10.2 Fixes:**
  - **Healthcheck-aware depends_on**: Implemented `waitForHealthy()` in `ComposeUp.swift` that polls a dependency's healthcheck command via `container exec` before starting dependent services. Supports CMD, CMD-SHELL, and NONE formats with configurable interval/timeout/retries/start_period.
  - **Fixed `container exec` syntax**: Apple's `container exec` does not use `--` separator (unlike Docker). Updated exec arg construction to match Apple CLI format.
  - **Shorthand `env:` Key Support**: Fixed critical bug where `env:` shorthand was not decoded. Now properly recognized as alias for `environment:` (env takes precedence when both present)
  - **Environment Variable Test Fix**: Fixed `HOST` variable conflict in tests by using unique names (`DB_HOST`, `DB_PORT`, `DB_NAME`)
  - **Volume Creation Idempotency**: Gracefully handle "already exists" errors during volume creation
  - **Command String Parsing**: Split string-form commands into proper executable + arguments array
  - **Environment Variable Mapping**: Added `--env` flag mapping to pass service env vars to containers
  - **Port Mapping**: Added missing `--publish` flag mapping in `makeRunArgs` for service port mappings
- **Test Suite Stabilization**: Achieved 100% test pass rate (92/92) by resolving naming, port, and image compatibility issues.

- **v0.10.1 Fixes:**
  - **Restart stopped containers on compose up**: When containers exist but are stopped, automatically start them instead of returning an error
  - **Static checks**: Added `compose_static_checks.sh` for compose file validation
  - **Network reachability**: Added `network_reachability.sh` for DNS and connectivity testing

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

---

## Proposed Features & Roadmap

Based on analysis of `apple/container` v0.11.0 upcoming features and current fork capabilities.

### Current Status (v0.10.1)

| Feature | Status | Upstream Version |
|---------|--------|-----------------|
| `init`/`init_image` support | ✅ Complete | v0.10.0 |
| `runtime` flag | ✅ Complete | v0.10.0 |
| Checkpoint command | ✅ Complete | v0.10.0 |
| Restart stopped containers | ✅ Complete | v0.10.1 |
| Multi-stage build target | ✅ Complete | Fork-only |
| `dns_search` support | ✅ Complete | Fork-only |
| Pre-decode `${VAR}` substitution | ✅ Complete | v0.10.3 |
| `service_healthy` dependency enforcement | ✅ Complete | v0.10.3 |
| `__SERVICE_HOST__`/`__SERVICE_PORT__` resolution | ✅ Complete | v0.10.3 |

### Upcoming Release v0.11.0 (Target: Q2 2026)

#### 1. Build Secrets Support
- **Upstream:** #1300 - Add support for build secrets
- **Compose Mapping:** Add `secrets:` to service `build:` configuration
- **Implementation:** Extend `Build.swift` with secrets array, map to `container build --secret`

#### 2. Network MTU Configuration
- **Upstream:** #1267 - Add mtu option for network attachments
- **Compose Mapping:** Add `mtu:` to network definitions
- **Implementation:** Update `Network.swift` with MTU field

#### 3. Resource Limits
- **Upstream:** #1266, #1293 - Container and build resource tracking
- **Compose Mapping:**
  - Services: `cpus:`, `mem_limit:`
  - Build: `build.cpus:`, `build.memory:`
- **Implementation:** Extend `Service.swift` and `Build.swift`

#### 4. Registry Authentication
- **Upstream:** #1195 - RegistryResource
- **Compose Mapping:** Evaluate if native support replaces fork needs
- **Action:** Spike to determine if fork registry handling can be deprecated

#### 5. Checkpoint/Export Enhancement
- **Upstream:** #1303 - Refactor container export as tar archive
- **Compose Impact:** Update `CheckpointCommand.swift` for new export API
- **Note:** Breaking change - checkpoint files may need migration

#### 6. Robust Service Lifecycle (Restart Policies)
- **Status:** Deferred to v0.12.0
- **Depends on:** Upstream PR #1258 (not yet merged to main)
- **Scope:** `restart: always/on-failure/unless-stopped`

### Future Releases (v0.12.0+)

| Feature | Upstream PR | Notes |
|---------|-------------|-------|
| High-Performance File Transfer | #1190 | `container cp` for sync/hot-reload |
| Rootfs Override | #1323 | Custom init filesystem per service |
| Advanced Networking | #1151 | Multi-plugin network support |
| Auto-Start (LaunchAgent) | #1176, #1201 | Boot service installation |
| Container Prune on Start | #1290 | Reap auto-remove containers |

### Compose Orchestration Gaps

Features currently worked around in external orchestrator scripts (e.g., `apple-container-honcho-compose.sh`).

#### Real Gap

| Gap | Current Workaround | Impact | Priority |
|-----|-------------------|--------|----------|
| **`container restart`** | External watchdog scripts | No native restart policy enforcement after crashes; `restart: always/on-failure` is parsed but cannot be delegated to runtime | High |
| **`container cp`** | Volume mounts for all file sharing | No hot-reload or file sync capability; limits dev workflow | High |
| **`container wait`** | Polling with `container list` | Cannot efficiently block until a container exits; adds latency to shutdown orchestration | Medium |

#### Non-Gaps (already supported by container-compose)

The orchestrator script works around several features that container-compose already implements natively:

| Feature | Container-Compose Support | Orchestrator Workaround (unnecessary) |
|---------|--------------------------|--------------------------------------|
| **`-f` flag** | `@Option` on `ComposeUp` and `ComposeDown`; accepts filename relative to cwd | Symlink desired file to `compose.yml` before each call |
| **`${VAR}` interpolation** | `resolveYamlVariables()` in `Helper Functions.swift` resolves `${VAR}`, `${VAR:-default}`, `${VAR:?error}` on raw YAML before decode (Docker Compose compatible with `$$` escaping) | Python pre-renders compose file with `os.environ` substitution |
| **`depends_on` ordering** | `Service.topoSortConfiguredServices()` does topological sort at `ComposeUp.swift:147`; `waitForHealthy()` gates `service_healthy` dependencies | Manual sequential `container-compose up -d <service>` calls |
| **Partial compose / volumes** | `setupVolume()` handles "already exists" gracefully; top-level volumes created idempotently per compose file regardless of service selection | Regex-based stripping of `volumes:` and single-service extraction |

### Compatibility & Migration

#### v0.10.x → v0.11.0 Migration

**Breaking Changes:**
- Checkpoint export format changes (#1303)
- Build secrets require containerization 0.29.0+

**Deprecations:**
- Evaluate removing fork registry auth if #1195 meets needs

**New Dependencies:**
- Bump Containerization to 0.29.0
- Swift tools version unchanged (v5.9+)

### Testing Requirements

| Feature | Test Priority | Type |
|---------|--------------|------|
| Build secrets | High | Integration |
| Network MTU | Medium | Unit + Network |
| Resource limits | High | Resource validation |
| Checkpoint export | High | Migration/compat |
| RegistryResource | Medium | Auth flows |

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

| Feature | Test Coverage | Priority |
|--------|---------------|----------|
| **Persistence** | Named volumes, full path preservation | High |
| **Security** | SELinux compatibility, build secrets | High |
| **Reliability** | Memory validation, restart policies, stopped container restart | High |
| **Networking** | DNS search, network reachability, MTU configuration | Medium |
| **Build** | Multi-stage targets, build secrets, resource limits | High |
| **Lifecycle** | Checkpoint export/import, container restart | High |
| **Orchestration** | healthcheck-aware `depends_on` | High |
| **Registry** | Authentication, push/pull | Medium |

---

## TODOs

- [ ] Create detailed CHANGELOG.md with migration notes
- [ ] Update README and CLI --help strings for fork-only features
- [ ] Audit tests for upstream compatibility
- [ ] Consider upstreaming: dns_search, build.target, entrypoint fix, named-volume behavior
- [x] Implement healthcheck-aware `depends_on` (wait for dependency healthy before starting dependents)

---

## Feature Requests for Apple Containers (`container` CLI)

Features missing or incompatible in Apple's `container` CLI relative to Docker that block or complicate compose orchestration.

### High Priority — Blocks Core Compose Features

| Feature | Docker CLI | Apple `container` CLI | Impact on Compose |
|---------|-----------|----------------------|-------------------|
| **`exec --` separator** | `docker exec <id> -- cmd args` | No `--` support; args go directly after container ID: `container exec <id> cmd args` | Compose healthcheck execution must strip `--` from exec args (worked around in fork) |
| **`container wait`** | `docker wait <id>` returns exit code | Not implemented (`Plugin 'container-wait' not found`) | No way to block until a container exits; forces polling with `container list` |
| **`container cp`** | `docker cp <id>:src dest` | Not implemented (`Plugin 'container-cp' not found`) | No file sync or hot-reload; must use volume mounts for all file sharing |
| **`container restart`** | `docker restart <id>` | Not implemented (`Plugin 'container-restart' not found`) | Restart policies (`restart: always/on-failure`) cannot trigger restarts after crashes |
| **`container attach`** | `docker attach <id>` | Not implemented (`Plugin 'container-attach' not found`) | Cannot reconnect to a container's stdin/stdout after detach |

### Medium Priority — Complicates Orchestration

| Feature | Docker CLI | Apple `container` CLI | Impact on Compose |
|---------|-----------|----------------------|-------------------|
| **`container rename`** | `docker rename <old> <new>` | Not implemented (`Plugin 'container-restart' not found`) | Cannot rename containers; must track original names |
| **`container health` / health status in `inspect`** | `docker inspect` returns `Health.Status` | No health status field in container metadata | Compose must exec healthcheck commands manually via `container exec` (works, but native health state would avoid exec overhead per poll) |
| **`container logs --since` / `--tail`** | `docker logs --tail 100 --since 1m` | `container logs` lacks filtering flags | Cannot efficiently fetch recent logs for debugging |
| **`--restart` policy on `run`/`create`** | `docker run --restart=always` | Not present on `container run` | Compose `restart:` key cannot delegate to runtime; needs external watchdog |
| **`--hostname` on `run`/`create`** | `docker run --hostname foo` | Not present on `container run` | Compose `hostname:` key must be handled via `/etc/hosts` volume mount workaround |

### Low Priority — Nice to Have

| Feature | Docker CLI | Apple `container` CLI | Impact on Compose |
|---------|-----------|----------------------|-------------------|
| **`--cap-add` / `--cap-drop`** | `docker run --cap-add SYS_PTRACE` | Not present on `container run` | Cannot configure Linux capabilities |
| **`--security-opt`** | `docker run --security-opt seccomp=...` | Not present on `container run` | Cannot configure seccomp/AppArmor profiles |
| **`--pid` (PID sharing)** | `docker run --pid=container:id` | Not present on `container run` | Cannot share PID namespace between containers |
| **`--shm-size`** | `docker run --shm-size=256m` | Not present on `container run` | Cannot configure shared memory size |
| **`--tmpfs` with options** | `docker run --tmpfs /run:rw,noexec` | `container run --tmpfs` supports path only | Cannot set tmpfs mount options |
| **`--gpus`** | `docker run --gpus all` | Not present on `container run` | No GPU passthrough support |

### Syntax Incompatibilities (Implemented, Requires Workarounds)

| Feature | Docker Syntax | Apple `container` Syntax | Workaround in Fork |
|---------|-------------|------------------------|-------------------|
| **`exec` argument separation** | `docker exec <id> -- cmd args` | `container exec <id> cmd args` | Strip `--` before passing to exec |
| **Volume bind mount format** | `docker run -v src:dest:ro` | `container run --mount type=bind,source=src,target=dest,readonly` | Convert `-v` format to `--mount` format in `makeRunArgs` |
| **Network attach format** | `docker run --network foo` | `container run --network foo[,mac=XX:XX:XX:XX:XX:XX]` | Direct mapping, no issue |
| **Port publish format** | `docker run -p 127.0.0.1:8080:80` | `container run --publish 8080:80` (no bind address in older versions) | Verified: `--publish 127.0.0.1:8080:80` works in current version |

---

## Related Upstream PRs

- Tests overhaul: https://github.com/Mcrich23/Container-Compose/pull/22
- Named volume fixes: https://github.com/Mcrich23/Container-Compose/pull/32, https://github.com/Mcrich23/Container-Compose/pull/42
- ComposeDown tests: https://github.com/Mcrich23/Container-Compose/pull/50
