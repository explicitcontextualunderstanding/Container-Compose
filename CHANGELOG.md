# CHANGELOG

## Unreleased (explicitcontextualunderstanding) - 2026-03-27

### Added

- **Service-level volume mapping**: `service.volumes` entries now generate `-v` flags in `container run` commands. Bind mounts (paths with `/` or starting with `.`) and named volumes are supported.
- **Pre-decode `${VAR}` substitution**: Environment variables (`${VAR}`, `${VAR:-default}`, `${VAR:?error}`) are now resolved in raw YAML before decode, matching Docker Compose behavior. This resolves `${VAR}` in `image:`, `volumes:`, `command:`, and all other compose fields — not just `environment:` values.
- **`$$` escaping support**: Users can write `$$` in compose YAML to produce a literal `$` for shell interpreters (e.g., `command: ["sh", "-c", "echo $$HOME"]` → shell sees `$HOME`).
- **`resolveYamlVariables()` function**: New helper in `Helper Functions.swift` that wraps `resolveVariable()` with `$$` sentinel escaping for safe pre-decode substitution.
- **`__SERVICE_HOST__` / `__SERVICE_PORT__` placeholder resolution**: Runtime container IPs and ports are resolved for `__{SERVICE_NAME}_HOST__` and `__{SERVICE_NAME}_PORT__` patterns in environment variable values, with fuzzy matching (case-insensitive, strips hyphens/underscores).
- **Container runtime diagnostics**: `ContainerDependentTrait` now pings the container API server on test startup and reports version, commit, and EUID status.
- **Idempotent `compose up`**: Added `--force-recreate` and `--no-recreate` flags to control whether running containers are recreated.
- **Integration tests for Feature 1 and Feature 2**: Static tests verify pre-decode substitution through the full YAML decode pipeline; dynamic tests verify `${VAR}` resolution in running containers and `service_healthy` dependency enforcement.
- **Volume mapping tests**: Added `testBindMountMapping`, `testNamedVolumeMapping`, `testAbsolutePathBindMountMappingWithinCwd`, `testOutsidePathSecuritySkipped` to verify `-v` flag generation.

### Fixed

- **Dead code removal**: Removed unused `configVolume()` function at `ComposeUp.swift:839` that was never called; volume handling is now properly integrated into `makeRunArgs()`.
- **Service volume mounting**: Previously `service.volumes` was parsed from YAML but never generated `-v` flags for `container run`. Now properly wired to create bind mounts and named volume mappings.
- **Test suite stabilization**: 
  - Fixed WordPress test to check for IP pattern instead of `networks.first` which may be empty (race condition in container runtime API)
  - Added polling wait for container startup in `testUpAndDownComplex`
  - `testUpAndDownComplex` uses busybox/nginx instead of MySQL/WordPress (MySQL 8.0 initialization takes 30-60s and often times out)
  - Note: `testWordPressCompose` still tests WordPress/MySQL functionality; only the compose down complex test was simplified
- **`${VAR}` resolution in env pipeline**: Replaced naive `${` string stripping with `resolveVariable()` for proper `${VAR:-default}` and `${VAR:?error}` support in post-decode environment values.
- **Test container name limit**: Shortened test container prefix (`CCT_` instead of `ContainerComposeTest_`) to avoid the macOS 63-character container name limit.
- **`container start -d` flag**: Removed unsupported `-d` flag from `container start` calls.
- **Build tooling**: Updated `build-sign-install.sh` to maintain `/usr/local/bin` symlink and auto-inject git commit hash during build.

### Changed

- **`.env` loading order**: `.env` file is now loaded before YAML decode (moved up in pipeline) so environment variables are available for pre-decode substitution.
- **Post-decode `resolveVariable()`**: Retained as idempotent safety net; no longer the primary resolution point.

## v0.10.2 - Fork release (explicitcontextualunderstanding) - 2026-03-24

### Fixed

- **Shorthand `env:` Key Support**: Fixed critical bug where the shorthand `env:` key (e.g., `env: MY_VAR=value`) was not being decoded.
- **Environment Variable Test Fix**: Fixed `HOST` environment variable conflict in tests by using unique variable names.
- **Volume Creation Idempotency**: Fixed volume creation to gracefully handle "already exists" errors.
- **Command String Parsing**: Fixed parsing of string-form commands to properly split into executable and arguments.
- **Environment Variable Mapping**: Added missing `--env` flag mapping in `makeRunArgs`.
- **Port Mapping**: Added missing `--publish` flag mapping in `makeRunArgs`.
- **macOS Container Name Limit**: Implemented proactive validation and warnings for the 64-character container name limit on macOS.
- **Test Suite Stabilization**: Achieved 100% test pass rate (92/92 tests) on macOS by:
  - Transitioning WordPress tests to `wordpress:fpm-alpine` for runtime compatibility.
  - Implementing unique port assignments (18080-18085) for all dynamic tests to prevent parallel execution collisions.
  - Hardening `run-tests.sh` with build directory ownership checks and automated container pruning.
- **Security-Compliant Installation**: Updated `build-and-install.sh` to target `~/bin` with ad-hoc code signing to bypass macOS Gatekeeper and provenance restrictions.

## v0.10.1 - Fork release (explicitcontextualunderstanding) - 2026-03-24

This release includes critical fixes from adversarial code review, silent failure remediation, and missing field mappings.

### Fixed

- **Adversarial Review Fixes** - Comprehensive code review identified and fixed 63 confirmed issues:
  - Fixed silent failures where streamCommand results were discarded (volume creation, container start, checkpoint)
  - Fixed file handle resource leaks in Helper Functions with proper cleanup
  - Added timeout mechanism to streamCommand (default 300s) to prevent indefinite hangs
  - Fixed loadEnvFile to properly propagate errors instead of silently swallowing

- **Stopped container restart**: When a container exists but is not running (e.g., stopped), `container-compose up` now starts the existing container instead of failing with an error message.
  - Previously: Container existed with status: stopped. Error was printed and command returned without starting the container.
  - Now: Container is automatically started using `container start <name> -d`, then waits for it to be running and updates service IPs.

- **Missing Field Mappings** - Added support for compose fields that were parsed but never mapped to container run flags:
  - `--user` for service.user
  - `--hostname` for service.hostname
  - `--workdir` for service.working_dir
  - `--privileged` for service.privileged
  - `--read-only` for service.read_only
  - `--network` for service.networks (supports multiple networks)
  - `-t` for service.tty
  - `-i` for service.stdin_open

- **Checkpoint Command Improvements**:
  - Added pre-flight checks to verify container exists before checkpointing
  - Added validation that container is running (with --force flag to override)
  - Added exit code validation to ensure commit succeeded

## v0.9.1 - Fork release (explicitcontextualunderstanding)

This release bundles several upstream fixes and improvements merged into this fork. Highlights and user-facing notes:

- dnsSearch support
  - Commit: https://github.com/Mcrich23/Container-Compose/commit/d509f8af30f9d2382c1804f575ea0f22eb4e5734
  - User note: Services can now specify dns_search/dnsSearch entries so containers can resolve each other by name using custom DNS search domains. Configure in your service's networks or service definition.

- Multi-stage Docker build target support
  - Commit: https://github.com/Mcrich23/Container-Compose/commit/02ca6462b84121c1553bd7adb862ee22aabc4997
  - User note: When using build: with Dockerfiles that include multiple stages, the `target` field is respected so you can build a specific stage (e.g., `build: { context: ".", target: "release" }`).

- Improved volume handling and named-volume destination preservation
  - Commits/PRs: https://github.com/Mcrich23/Container-Compose/commit/b1badf86a4faf5c6ed512643e255760073d38988, https://github.com/Mcrich23/Container-Compose/pull/32, https://github.com/Mcrich23/Container-Compose/pull/42
  - User note: Named volumes now preserve full destination paths (e.g., `- elasticsearch-data:/usr/share/elasticsearch/data`), and relative host paths are normalized to absolute paths for bind mounts.

- Correct --entrypoint placement
  - Commit: https://github.com/Mcrich23/Container-Compose/commit/84201f9416f4a5f1bd383763679f8e2fd7579e94
  - User note: Entrypoint overrides in compose files are now passed to the container run command properly (as `--entrypoint <cmd>` before the image), preventing unexpected immediate container exit.

- Startup/wait fixes and improved command debugging
  - Commits: https://github.com/Mcrich23/Container-Compose/commit/8a4e5bb0e634155d122ac5d93905a75dcbf5b3da, https://github.com/Mcrich23/Container-Compose/commit/eeddb266a45686c99f53f300c2c5d049b1f3b157, https://github.com/Mcrich23/Container-Compose/commit/4968a8669babe7822ada82cc90328f102edfd02e
  - User note: Waiting logic no longer times out incorrectly when a container is already running; the tool prints the exact container run command being executed to aid debugging.

- CI and release automation (fork-specific)
  - Origin commits: https://github.com/explicitcontextualunderstanding/Container-Compose/commit/3f20dbf6a6268a93fa196632caa2c178214892f7 and https://github.com/explicitcontextualunderstanding/Container-Compose/commit/98b7fc4a50467067158d15eb47d9acca78121719
  - User note: This fork adds GitHub Actions for release automation used by the maintainers of this fork.

For full details and links to the source commits/PRs, see FORK_CHANGES.md.
