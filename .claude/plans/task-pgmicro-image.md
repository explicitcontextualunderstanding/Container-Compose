# Task: Build and Publish pgmicro Image to Zot Registry

**Created:** 2026-03-29
**Assigned to:** Nano1
**Priority:** Medium
**Status:** Pending

## Context

During test suite debugging (2026-03-28), we discovered that the pgmicro image `ghcr.io/glommer/pgmicro:latest` is not publicly available (returns 401/404). This blocked two tests:

1. `Test pgmicro container starts without volume mount issues` (ComposeAdvancedTests.swift:435)
2. `Test three-tier app with pgmicro database` (ComposeAdvancedTests.swift:483)

## Objective

Build the pgmicro image locally and publish it to the Zot registry for use in Container-Compose tests.

## Prerequisites

- pgmicro source code or Dockerfile
- Access to Zot registry (K3s-hosted OCI registry)
- Buildah or Docker for image building

## Tasks

### 1. Locate pgmicro Source
- [ ] Find pgmicro repository (likely github.com/glommer/pgmicro)
- [ ] Verify it builds SQLite-backed PostgreSQL-compatible database
- [ ] Check for existing Dockerfile or build instructions

### 2. Build Image
- [ ] Clone pgmicro repository
- [ ] Build image using buildah (preferred for Apple Container compatibility):
  ```bash
  buildah bud -t pgmicro:latest .
  ```
- [ ] Test image locally:
  ```bash
  container run pgmicro:latest --server 0.0.0.0:5432
  ```

### 3. Publish to Zot Registry
- [ ] Tag image for Zot registry:
  ```bash
  buildah tag pgmicro:latest <zot-registry>/pgmicro:latest
  ```
- [ ] Push to Zot:
  ```bash
  buildah push <zot-registry>/pgmicro:latest
  ```
- [ ] Verify image is accessible:
  ```bash
  container pull <zot-registry>/pgmicro:latest
  ```

### 4. Update Tests
- [ ] Update ComposeAdvancedTests.swift to use Zot registry URL
- [ ] Re-enable disabled tests:
  - Line 439: Remove `.disabled()` annotation
  - Line 486: Remove `.disabled()` annotation
- [ ] Run tests to verify:
  ```bash
  ./run-tests.sh --filter "ComposeAdvancedTests/testPgmicro"
  ```

## Success Criteria

- [ ] pgmicro image available in Zot registry
- [ ] Both pgmicro tests pass without manual intervention
- [ ] No reliance on external ghcr.io registry

## Notes

- Zot registry location: Check with Kieran for URL (likely `zot.k3s.local` or similar)
- pgmicro is valuable because it uses SQLite storage, avoiding Virtualization.framework volume permission issues on Apple Container

## Related Files

- `/Users/kieranlal/workspace/Container-Compose/Tests/Container-Compose-DynamicTests/ComposeAdvancedTests.swift` (lines 435-543)
- `/Users/kieranlal/workspace/Container-Compose/.claude/skills/managing-container-registry/SKILL.md`

## References

- Test debugging session: 2026-03-28
- Issue: Image `ghcr.io/glommer/pgmicro:latest` returns 401 Unauthorized
