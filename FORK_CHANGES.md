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

- Convert each bullet above into a CHANGELOG section with short user-facing notes and example usage (e.g., how to use the new build target, how to set dns_search).
- Update CLI --help and README to document new/changed flags and behaviors (dnsSearch/dns_search, build.target, named-volume behavior, entrypoint handling).
- Where possible, link to the full upstream PR discussions for context (links provided above for the main PRs found).

TODOs:
- Create a detailed CHANGELOG.md entry describing user-facing changes and migration notes.
- Update README and CLI --help strings to reflect fork capabilities.

(Generated by repo inspection and upstream PR search.)
