# pgmicro: PostgreSQL-Compatible Database for Container Testing

## Overview

pgmicro is a Rust-based reimplementation of the PostgreSQL wire protocol that uses SQLite (via Turso/Libsql) as its storage engine. It translates PostgreSQL queries into SQLite bytecode, providing a lightweight, PostgreSQL-compatible database ideal for testing, AI agents, and edge deployments.

## Build Correction History

### Root Cause
The original Argo workflow built the wrong package:
- **Incorrect**: `cargo build --release --package turso_cli` (SQLite CLI, no PostgreSQL protocol)
- **Correct**: `cargo build --release --package pgmicro` (PostgreSQL wire protocol server)

### Correction Applied
- Updated workflow: `k3s/pgmicro-corrected-workflow.yaml`
- Build time: 63 minutes (single-threaded Rust compilation with `CARGO_BUILD_JOBS=1`)
- Image location: `192.168.100.1:30500/pgmicro:latest`
- Pulled via Cloudflare tunnel: `registry.example.com/pgmicro:latest`

### Verification Results
- ✅ Binary is `pgmicro` (not `tursodb`)
- ✅ `--server 0.0.0.0:5432` flag works
- ✅ PostgreSQL wire protocol server starts successfully
- ✅ All 164 Container-Compose tests pass
- ✅ No PostgreSQL environment variables required (`POSTGRES_DB`, `POSTGRES_USER`, etc.)

## ⚠️ Cannot Replace Honcho Database

**Honcho requires pgvector extension** — pgmicro is NOT a suitable replacement.

### Reason
- Honcho has **6,123 existing embeddings** (430 documents + 5,693 messages)
- Uses **pgvector extension** for semantic search over 1536-dimensional vectors
- pgmicro does **NOT support pgvector extension**
- Embeddings are core to Honcho's memory retrieval system

### Honcho Database Requirements
| Requirement | pgmicro | Honcho Needs |
|-------------|---------|--------------|
| pgvector extension | ❌ Not supported | ✅ Required |
| Vector similarity search | ❌ No | ✅ Yes (semantic search) |
| Existing embeddings | ❌ Cannot migrate | ✅ 6,123 vectors |
| WAL-G backup integration | ❌ Not tested | ✅ Required (Plan 52) |

**Honcho must continue using** `walg-db:latest` (PostgreSQL 15 + pgvector + WAL-G).

## Usage in Container-Compose

### Docker Compose Syntax

```yaml
version: '3.8'
services:
  db:
    image: registry.example.com/pgmicro:latest
    command: ["--server", "0.0.0.0:5432", ":memory:"]
    ports:
      - "5432:5432"
```

### Key Differences from PostgreSQL

| Aspect | PostgreSQL | pgmicro |
|--------|------------|---------|
| Storage Engine | Native heap/B-tree | SQLite/Turso |
| Environment Variables | `POSTGRES_DB`, `POSTGRES_USER`, etc. | Not required |
| Startup Command | `postgres` | `pgmicro --server 0.0.0.0:5432 :memory:` |
| Protocol | PostgreSQL wire (full) | PostgreSQL wire (compatible subset) |
| Extensions | pgvector, PostGIS, etc. | Limited (Turso extensions only) |

### In-Memory vs. Persistent Storage

**In-Memory Mode** (recommended for tests):
```bash
pgmicro --server 0.0.0.0:5432 :memory:
```
- Data exists only in RAM
- Zero disk I/O overhead
- Ideal for CI/CD, unit tests, short-lived containers
- Limited by available RAM on host

**Persistent Mode** (for stateful workloads):
```bash
pgmicro --server 0.0.0.0:5432 /data/database.db
```
- SQLite database file on disk
- Survives container restarts
- Requires volume mount for persistence

## Data Handling Capabilities

### Storage Limits (SQLite Inheritance)

| Metric | Limit |
|--------|-------|
| Maximum Database Size | 281 TB (theoretical) |
| Maximum Row Count | 2^64 (practically unlimited) |
| Maximum Field Size | 1 GB per field |
| Ideal Dataset Size (Jetson Nano) | 100 MB – 10 GB |

### Performance Characteristics

| Metric | Capability |
|--------|------------|
| Throughput | Thousands of TPS on modest hardware |
| Concurrency | Multiple readers, serialized writer |
| Query Latency | Microsecond-level (in-memory mode) |
| Wire Protocol | Full PostgreSQL compatibility for common queries |

### Implementation Maturity

**Verified Stable**:
- Large row counts (100+ rows)
- Standard SQL operations (SELECT, INSERT, UPDATE, DELETE)
- Basic joins and aggregations
- Connection pooling via PostgreSQL wire protocol

**Medium Risk / Untested**:
- Bulk inserts (millions of rows)
- Deeply nested queries
- Advanced PostgreSQL features (JSONB indexing, custom extensions)
- Virtual columns (some edge cases)

### Hardware Considerations

**Jetson Nano 8GB**:
- **Memory bottleneck**: In-memory mode limited by available RAM
- **I/O bottleneck**: SD card write speed for persistent mode
- **Recommendation**: Use external SSD for datasets >1 GB

**Mac M2 Host**:
- No significant constraints for test workloads
- In-memory mode handles millions of rows effortlessly

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    PostgreSQL Client                         │
│              (psql, pgvector, ORMs, etc.)                    │
└─────────────────────┬───────────────────────────────────────┘
                      │ PostgreSQL Wire Protocol
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                      pgmicro                                 │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  PostgreSQL Query Parser (libpg_query)                │  │
│  └────────────────────┬──────────────────────────────────┘  │
│                       │ Query Translation                    │
│                       ▼                                       │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  SQLite Bytecode Generator (Turso/Libsql)             │  │
│  └────────────────────┬──────────────────────────────────┘  │
│                       │                                       │
│                       ▼                                       │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  SQLite Storage Engine                                │  │
│  │  - :memory: (RAM)                                     │  │
│  │  - /path/to/database.db (disk)                        │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Container-Compose Test Integration

### Test Configuration

```swift
// ComposeAdvancedTests.swift
let registryURL = getZotRegistryURL() // registry.example.com via Cloudflare tunnel

let yaml = """
version: '3.8'
services:
  db:
    image: \(registryURL)/pgmicro:latest
    command: ["--server", "0.0.0.0:5432", ":memory:"]
    ports:
      - "\(testPort):5432"
"""
```

### Environment Variable Support

pgmicro does NOT require PostgreSQL environment variables:
- ❌ `POSTGRES_DB` - ignored
- ❌ `POSTGRES_USER` - ignored  
- ❌ `POSTGRES_PASSWORD` - ignored
- ❌ `POSTGRES_HOST_AUTH_METHOD` - ignored

This simplifies test setup compared to full PostgreSQL images.

### Registry Configuration

Tests use `OCI_REGISTRY_URL` environment variable:

```bash
# Via Cloudflare tunnel (bypasses Apple Container RFC1918 HTTP downgrade)
OCI_REGISTRY_URL=registry.example.com swift test

# Direct IP (fails on Apple Container due to RFC1918 bug)
OCI_REGISTRY_URL=192.168.1.86:30500 swift test
```

## Best Practices

### For Testing

1. **Use in-memory mode**: Fastest startup, zero disk I/O
2. **Set explicit command**: `["--server", "0.0.0.0:5432", ":memory:"]`
3. **No environment variables needed**: Simplifies test configuration
4. **Verify image reference**: Check for "pgmicro" in container image name

### For Production

1. **Persistent storage**: Mount volume at `/data/database.db`
2. **External SSD**: Required for datasets >1 GB on Jetson
3. **Connection pooling**: Use PgBouncer for high-concurrency workloads
4. **Monitoring**: Track SQLite write lock contention

### Migration from PostgreSQL

| PostgreSQL Feature | pgmicro Support |
|--------------------|-----------------|
| Basic SQL (SELECT, INSERT, UPDATE, DELETE) | ✅ Full |
| Transactions (BEGIN/COMMIT/ROLLBACK) | ✅ Full |
| Indexes (B-tree) | ✅ Full |
| Views | ✅ Full |
| Triggers | ⚠️ Partial |
| Stored Procedures | ❌ Not supported |
| **pgvector extension** | ❌ **Not supported** |
| **Vector similarity search** | ❌ **Not supported** |
| PostGIS | ❌ Not supported |

## Suitable Use Cases

### ✅ Recommended for:
- Container-Compose testing (current use)
- CI/CD pipelines without vector requirements
- Lightweight PostgreSQL protocol testing
- Edge deployments without semantic search
- Short-lived containers with in-memory databases
- Test environments where pgvector is not needed

### ❌ NOT Suitable for:
- **Honcho memory hub** (requires pgvector for embeddings)
- Applications using semantic search
- Vector embeddings storage and retrieval
- Similarity matching workloads
- Any workload requiring PostgreSQL extensions

## Troubleshooting

### Container Exits Immediately

**Symptom**: Container starts then stops with no logs

**Cause**: Missing `--server` flag or no database argument

**Fix**:
```yaml
command: ["--server", "0.0.0.0:5432", ":memory:"]
```

### Connection Refused

**Symptom**: `psql: could not connect to server: Connection refused`

**Cause**: Server not listening on 0.0.0.0

**Fix**: Ensure `--server 0.0.0.0:5432` (not `127.0.0.1:5432`)

### Image Pull Fails

**Symptom**: `HTTP request to http://192.168.1.86:30500/v2/pgmicro/manifests/latest failed with response: 400 Bad Request`

**Cause**: Apple Container RFC1918 HTTP auto-downgrade

**Fix**: Use Cloudflare tunnel URL:
```bash
export OCI_REGISTRY_URL=registry.example.com
```

## References

- **Repository**: https://github.com/glommer/pgmicro
- **Turso Database**: https://github.com/tursodatabase/turso
- **Build Workflow**: `k3s/pgmicro-corrected-workflow.yaml`
- **Container-Compose Tests**: `Tests/Container-Compose-DynamicTests/ComposeAdvancedTests.swift`
- **Build Correction Commit**: `718808438` (isaac_ros_custom), `8742329` (Container-Compose)

## Version History

| Date | Version | Changes |
|------|---------|---------|
| 2026-03-29 | v1.0.0 | Initial build correction (turso_cli → pgmicro) |
| 2026-03-29 | v1.0.1 | Integrated into Container-Compose test suite |
