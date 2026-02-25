Summary of patches incorporated into this fork (high level)

This file summarizes notable patches and upstream PRs that have been incorporated into this fork (explicitcontextualunderstanding/Container-Compose) relative to the upstream repository.

Commits included in this fork (selected highlights):

- fix: remove RuntimeStatus type that doesn't exist (c509a2f)
- fixed incorrect waiting for running container (8a4e5bb)
- there is no longer 30 second timeout when container is already started (eeddb26)
- added support for dnsSearch to enable communication between containers using their names (d509f8a)
- added support for multi stage build target (02ca646)
- added information about what command is being run for easier debugging (4968a86)
- fix: place --entrypoint flag before image name in container run (84201f9)
- test: add named volume full path preservation test (8edb8a9)
- fix: use full destination path for named volumes (b1badf8)
- CI / release workflow additions (3f20dbf, 98b7fc4, 1d284fb)

Notes and next steps:

- These commits appear to include functionality backported or merged from upstream PRs (e.g., DNS search support, resource options, multi-stage build support, volume path fixes) and CI/release automation.
- Suggest expanding each bullet into a short paragraph linking to the original upstream PR/commit and noting any behavioral differences or config flags added (e.g., dnsSearch, multi-stage build target support).
- Update the CLI --help text to document new flags/options (dnsSearch, multi-stage target, resource options like --cpus/--memory if present) and ensure examples reflect fork-specific behavior.

TODOs:
- Create a more detailed CHANGELOG entry describing user-facing changes and any migration notes.
- Update README and CLI --help strings to reflect fork capabilities.

(Generated automatically from a quick repo inspection.)
