# runtime and init-image support

This document describes planned Compose mappings to engine flags added in apple/container v0.10.0:

- `runtime: <name>` in a service maps to `container run --runtime <name>`.
- `init: true` maps to `container run --init` (already supported by the fork via earlier work).
- `init_image: <ref>` maps to `container run --init-image <ref>` allowing selection of the init filesystem image for the micro-VM.

Usage example in docker-compose.yml:

services:
  app:
    image: myapp:latest
    runtime: kata
    init: true
    init_image: some-init-image:latest

Tests will assert that ComposeUp.makeRunArgs places these flags before the image name as required by the container CLI.
