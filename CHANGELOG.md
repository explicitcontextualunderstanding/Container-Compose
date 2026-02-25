# CHANGELOG

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
