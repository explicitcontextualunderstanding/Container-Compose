# checkpoint: export/commit service

This document describes the new `container-compose checkpoint <service>` command planned for the fork.

Goal

- Provide a simple way to commit/export a running service container into a local image for fast rollbacks, CI snapshots, or distributing a running container's state.

Behavior

- The command maps a service name to the running container name using the project naming convention (e.g., `<project>-<service>`).
- It invokes the underlying `container` engine command to export/commit the container to an image (upstream apple/container provides export/commit support in v0.10.0, PR #1172).
- The resulting image tag will default to `<project>-<service>:checkpoint-<timestamp>` unless explicitly provided via `--tag`.

Examples

- Export the running `web` service to an image with an auto-generated tag:

  container-compose checkpoint web

- Export with a specific tag:

  container-compose checkpoint web --tag myregistry.local/myproj/web:checkpoint-1

Notes

- This feature depends on apple/container@0.10.0 or later (PR #1172) which exposes commit/export functionality.
- Implementation details will be TDD-driven; tests in Tests/Container-Compose-StaticTests/CheckpointCommandTests.swift assert the command constructs the expected `container` CLI invocation.
