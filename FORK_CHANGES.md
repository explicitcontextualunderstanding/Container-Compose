Summary of patches incorporated into this fork (expanded with upstream links)

This file summarizes notable patches and upstream PRs/commits that were incorporated into this fork (explicitcontextualunderstanding/Container-Compose) relative to the upstream repository (Mcrich23/Container-Compose).

Notable changes included in this fork (with links):

- fix: remove RuntimeStatus type that doesn't exist (commit: c509a2f)
  - Origin commit: https://github.com/explicitcontextualunderstanding/Container-Compose/commit/c509a2f07c2fe251deb66f0a0a920739e39c21a4
  - Description: Removes a reference to a RuntimeStatus type that wasn't present in the container library; cleans up status tracking used only for error messages.

- fixed incorrect waiting for running container (commit: 8a4e5bb)
  - Upstream commit: https://github.com/Mcrich23/Container-Compose/commit/8a4e5bb0e634155d122ac5d93905a75dcbf5b3da
  - Description: Fixes wait logic so waiting for container startup no longer always times out; user is informed when the container is already running.

- there is no longer 30 second timeout when container is already started (commit: eeddb26)
  - Upstream commit: https://github.com/Mcrich23/Container-Compose/commit/eeddb266a45686c99f53f300c2c5d049b1f3b157
  - Description: Removes unnecessary fixed timeout when the container is already running.

- added support for dnsSearch to enable communication between containers using their names (commit: d509f8a)
  - Upstream commit: https://github.com/Mcrich23/Container-Compose/commit/d509f8af30f9d2382c1804f575ea0f22eb4e5734
  - Description: Adds dns_search/dnsSearch support in the Service model and ComposeUp handling so containers can resolve each other by name when using custom DNS search domains.

- added support for multi stage build target (commit: 02ca646)
  - Upstream commit: https://github.com/Mcrich23/Container-Compose/commit/02ca6462b84121c1553bd7adb862ee22aabc4997
  - Description: Adds support for specifying a build target (multi-stage Dockerfile target) when using the build: configuration in compose files.

- added information about what command is being run for easier debugging (commit: 4968a86)
  - Upstream commit: https://github.com/Mcrich23/Container-Compose/commit/4968a8669babe7822ada82cc90328f102edfd02e
  - Description: Outputs the exact container tool command being executed to aid debugging of failed runs.

- fix: place --entrypoint flag before image name in container run (commit: 84201f9)
  - Upstream commit: https://github.com/Mcrich23/Container-Compose/commit/84201f9416f4a5f1bd383763679f8e2fd7579e94
  - Description: Ensures --entrypoint is passed before the image name so it is interpreted as a run flag (prevents immediate container exit when overriding entrypoint).

- test: add named volume full path preservation test (commit: 8edb8a9)
  - Upstream commit: https://github.com/Mcrich23/Container-Compose/commit/8edb8a9be0cb5b820eca78c86d6a70b79ac459c1
  - Related upstream PRs: https://github.com/Mcrich23/Container-Compose/pull/22 (tests overhaul)
  - Description: Adds unit/regression tests to preserve full destination paths for named volumes.

- fix: use full destination path for named volumes (commit: b1badf8)
  - Upstream commit: https://github.com/Mcrich23/Container-Compose/commit/b1badf86a4faf5c6ed512643e255760073d38988
  - Related upstream PRs: https://github.com/Mcrich23/Container-Compose/pull/32 (fixed wrong named volume destination), https://github.com/Mcrich23/Container-Compose/pull/42 (improve volume mount handling)
  - Description: Corrects handling of named volume destination paths so a named volume mapped to /path/subpath preserves the full destination.

- CI / release workflow additions (commits: 3f20dbf, 98b7fc4, 1d284fb)
  - Origin commits:
    - https://github.com/explicitcontextualunderstanding/Container-Compose/commit/3f20dbf6a6268a93fa196632caa2c178214892f7
    - https://github.com/explicitcontextualunderstanding/Container-Compose/commit/98b7fc4a50467067158d15eb47d9acca78121719
    - https://github.com/explicitcontextualunderstanding/Container-Compose/commit/1d284fbc58e1abb0ff793e0eef0993fbeaf26189
  - Description: Adds and configures GitHub Actions workflows for release automation and CI build steps used by this fork.

Additional upstream PRs of interest (not exhaustive):

- Tests overhaul / fixes: https://github.com/Mcrich23/Container-Compose/pull/22
- Named volume fixes & volume mount handling: https://github.com/Mcrich23/Container-Compose/pull/32 and https://github.com/Mcrich23/Container-Compose/pull/42
- ComposeDown tests and container_name handling: https://github.com/Mcrich23/Container-Compose/pull/50

Notes and suggested next steps:

- Upstream apple/container v0.10.0 already includes many of the core engine changes referenced above (notably: ClientContainer rework [#1139], runtime flag for create/run [#1109], --init and --init-image support [#1244, #937], container export/commit [#1172], support for multiple network plugins [#1151], build --pull [#844], named-volume auto-create warning [#1108], memory validation [#1208], and related CLI/output changes such as a --format option for system status [#1237]).

- Items present in this fork but NOT included in apple/container v0.10.0 (should be tracked or upstreamed):
  - Remove RuntimeStatus type (commit: c509a2f)
  - Fix incorrect waiting when container is already running (commit: 8a4e5bb)
  - Remove unnecessary 30s timeout when container already started (commit: eeddb26)
  - dnsSearch / dns_search support for service name resolution (commit: d509f8a)
  - Multi-stage build target support (build.target) (commit: 02ca646)
  - Debug output showing the exact container CLI command being executed (commit: 4968a86)
  - Ensure --entrypoint is passed before image name in run (commit: 84201f9)
  - Named-volume full-destination-path preservation and regression test (commits: b1badf8, 8edb8a9)
  - Fork-specific CI/release workflow additions (commits: 3f20dbf, 98b7fc4, 1d284fb)

- Recommended actions:
  1. Update this FORK_CHANGES.md and add a short CHANGELOG.md that clearly separates what was upstreamed in apple/container@0.10.0 and what remains unique to this fork.
  2. Update README and CLI --help strings for fork-only features (dns_search, build.target, entrypoint behavior, named-volume handling) and add migration notes where appropriate.
  3. For each fork-only item, decide whether to upstream as a PR against apple/container or keep it as a fork patch; open PRs for items that are broadly useful (dns_search, build.target, entrypoint fix, named-volume behavior).

TODOs:
- Create a detailed CHANGELOG.md entry describing user-facing changes and migration notes, split into "Upstream in container@0.10.0" and "Fork-only changes".
- Update README and CLI --help strings to reflect fork capabilities and any CLI differences.
- Audit tests that depend on fork-only behavior and mark or adapt them for upstream compatibility.

(Generated by repository inspection against apple/container v0.10.0.)

---

Proposed features to target for the next Apple Containers release

Based on the active development in the apple/container main branch (post-0.9.0), several high-impact features are landing that the Container-Compose fork is uniquely positioned to capitalize on. To stay ahead of the next release, focus development and testing on the following areas.

### 1. Robust Service Lifecycle (Restart Policies)

The Change: PR #1258 adds a native `--restart` policy to the `container run` command.

- Compose Feature to Add: Implement the `restart: always`, `restart: on-failure`, and `restart: unless-stopped` keys in docker-compose.yaml so the fork maps those keys to the new engine `--restart` flag.
- Testing Priority: Test "zombie" container cleanup. Since the engine is adding native restart support, ensure that `container-compose down` correctly stops and removes containers that the engine might be trying to restart automatically.

### 2. High-Performance Host-Container File Transfer

The Change: PR #1190 introduces a native `container cp` command.

- Compose Feature to Add: Use this to implement a "Sync" or "Hot Reload" feature that programmatically moves files into a running service container as an alternative to bind mounts for improved performance.
- Testing Priority: Verify large file transfers and directory structures. This is a significant improvement over the current "mount-only" storage strategy in 0.9.0.

### 3. Native "Init" Process Management

The Change: PR #1244 adds an `--init` flag to `run/create`.

- Compose Feature to Add: Add an `init: true` boolean to the service definition that maps to the engine `--init` flag when starting containers.
- Testing Priority: Test applications that spawn many child processes (Node.js, Python with workers). Using the native `--init` flag will prevent orphan processes from remaining in the micro-VM after the service stops.

### 4. Advanced Networking & Multi-Plugin Support

The Change: PR #1151 and #1227 enable multiple network plugins and loading configurations from files.

- Compose Feature to Add: Support complex `networks:` definitions in Compose to allow combinations of bridge, host-only, and routed networks for services within the same stack.
- Testing Priority: IPv6 connectivity. PR #1174 adds IPv6 gateway support — validate IPv6 addressing, routing, and DNS resolution across custom networks.

### 5. "Snapshot-based" Deployments

The Change: PR #1172 adds `container commit` (exporting a container to an image).

- Compose Feature to Add: Implement a `container-compose checkpoint <service>` command that commits a running container to a local image for future `up` commands or for fast rollbacks.
- Testing Priority: Validate database checkpoints and restore flows; ensure image metadata and layers are handled consistently across commits.

### Suggested Testing Matrix for the Fork

| Feature | Target PR | Test Case |
| --- | --- | --- |
| **Persistence** | #1108 / #1190 | Verify that named volumes aren't "lost" and `cp` works across them. |
| **Security** | #1152 / #1166 | Ensure Compose-generated containers respect the new SELinux-off-by-default boot. |
| **Reliability** | #1208 | Launch a Compose stack with `mem_limit: 128mb` and verify the CLI surfaces validation errors correctly. |

### Strategic Recommendation

The most valuable addition would be **Auto-Start support**. With Apple adding `LaunchAgent` support (#1176) and a `--system-start` flag (#1201), the fork could introduce a `container-compose install-service` command that generates macOS LaunchAgents to auto-start stacks on boot.

---

Would you like help drafting the Swift logic to map `restart: always` and related Compose keys to the engine `--restart` flag? (Can produce a focused patch for Sources/Container-Compose/Commands/ComposeUp.swift.)
