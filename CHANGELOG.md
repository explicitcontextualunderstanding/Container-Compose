# CHANGELOG

## v0.10.2 - Fork release (explicitcontextualunderstanding) - 2026-03-24

### Fixed

- **Shorthand `env:` Key Support**: Fixed critical bug where the shorthand `env:` key (e.g., `env: MY_VAR=value`) was not being decoded. The `env:` key is now properly recognized as an alias for `environment:` and takes precedence when both are present in a service definition.
- **Environment Variable Test Fix**: Fixed `HOST` environment variable conflict in tests by using unique variable names (`DB_HOST`, `DB_PORT`, `DB_NAME`) to avoid collision with system environment variables.
- **Volume Creation Idempotency**: Fixed volume creation to gracefully handle "already exists" errors, preventing failures when re-running compose up with existing volumes.
- **Command String Parsing**: Fixed parsing of string-form commands (e.g., `command: python -m http.server 8000`) to properly split into executable and arguments array for container runtime.
- **Environment Variable Mapping**: Added missing `--env` flag mapping in `makeRunArgs` to pass service environment variables to containers.
- **Port Mapping**: Added missing `--publish` flag mapping in `makeRunArgs` for service port mappings.

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
