---
plan: container-compose-orchestration-hardening
title: container-compose Orchestration Hardening
status: draft
priority: high
created: 2026-04-02T07:10:00Z
updated: 2026-04-02T07:10:00Z
version: 1.0.0
author: Engineering Team
references:
  - type: document
    id: FORK_CHANGES.md
    link: https://github.com/explicitcontextualunderstanding/Container-Compose/blob/main/FORK_CHANGES.md
tags:
  - container-compose
  - crash-recovery
  - orchestration
  - tdd
estimated-duration: 2-3 weeks
---

# Plan: container-compose Orchestration Hardening

## Overview

Expand `container-compose` to handle crash recovery, health checks, and critical volume/image mapping gaps using Test-Driven Development (TDD). Incorporates adversarial review findings and risk-reduction recommendations.

## Goals

- Implement `--recover` mode for single-command crash recovery
- Add `service_completed_successfully` dependency condition
- Implement health status reporting via `container exec` polling
- Fix service bind-mount and file volume mapping
- Add XPC timeout hardening and digest-pinned image support

## Problem Statement

After a macOS crash, `container-compose up` fails on "container already exists" for pre-existing containers. Recovery requires a 200-line orchestrator script that checks each container individually. Additionally, bind-mount volumes are silently ignored, digest-pinned images are stripped, and XPC timeouts cause hangs during shutdown.

## High-Level Approach

### Phase 1: Recovery Mode (--recover)

1. Add `--recover` flag, mutually exclusive with `--build` and `--force-recreate`
2. Implement `configService` recovery logic: detect running/exited containers, skip or restart
3. Log verbose decisions and `[DRIFT WARNING]` if config differs from compose.yml
4. Soft health checks (3-5s timeout) in recovery mode

### Phase 2: Health & Lifecycle (service_completed_successfully)

1. Add `service_completed_successfully` condition to `DependsOnCondition` enum
2. Poll for "exited" status with exit code 0 before starting dependents
3. Use task's stored exit code for idempotency

### Phase 3: Health Status Reporting

1. Implement `HealthCommand.swift` using `container exec` polling
2. Report health status in `container-compose ps` output

### Phase 4: Service Bind-Mounts & File Mounts

1. Wire `service.volumes` into `makeRunArgs()` for bind-mount generation
2. Add virtiofs guardrail warnings for database paths
3. Remove file-mount restriction, implement safe mapping

### Phase 5: Resilience & Hardening

1. XPC timeout hardening with retry logic in `ComposeDown.swift`
2. Idempotent teardown — resume cleanup after partial failures
3. Digest-pinned image support (`@sha256:...` preserved)

## Execution Context

- Repo: `~/workspace/Container-Compose` (fork of `Mcrich23/Container-Compose`)
- Language: Swift 5.9+
- Target: Apple Container runtime (macOS)
- Test framework: XCTest (static + dynamic tests)

## Key Decisions

- **TDD methodology**: Red-Green cycle for each phase, deterministic failure simulation via dependency injection
- **Mutual exclusivity**: `--recover` incompatible with `--build` and `--force-recreate`
- **Soft health checks**: 3-5s timeout in recovery mode (not total skip) to prevent death spirals
- **State validation**: Only attach to `running` or `exited` containers; treat `creating`/`restarting`/`removing` as missing
- **Verbose logging**: Every recovery decision logged with rationale

## Verification

### Automated Tests

- Full `swift test` suite after each Green phase
- Deterministic failure simulations (XPC timeouts, hung responses) via dependency injection
- Static mapping tests for flag generation
- Dynamic tests for container lifecycle

### Commands to run

- [ ] Phase 1: `swift test --filter ComposeUpMappingTests` + dynamic recovery test
- [ ] Phase 2: `swift test --filter ServiceDependencyTests` + dynamic init-container test
- [ ] Phase 3: `swift test --filter HealthCommandTests`
- [ ] Phase 4: `swift test --filter ComposeUpMappingTests` (volume mapping)
- [ ] Phase 5: `swift test --filter ComposeDownTests` (XPC timeout) + digest test

### Manual Verification

- Deploy multi-tier app, simulate crash (`kill -9` daemon), run `container-compose up --recover`
- Verify all services restored with correct dependency ordering

## References

- Fork changes: `FORK_CHANGES.md`
- Upstream: https://github.com/Mcrich23/Container-Compose
- Apple Container runtime: `container` CLI documentation
