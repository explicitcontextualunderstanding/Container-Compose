# Binary Verification

This document describes how to verify that your downloaded `container-compose` binary matches the source code in this repository.

## Release Checksums

Each release includes a SHA256 checksum file. You can verify your download matches the official release.

### Latest Release (v0.10.1)

| File | SHA256 |
|------|--------|
| container-compose | *(See release notes for current hash)* |

## Verification Steps

### 1. Download and Verify

```bash
# Download the binary
curl -L -o container-compose \
  https://github.com/explicitcontextualunderstanding/Container-Compose/releases/latest/download/container-compose

# Download the checksum file
curl -L -o container-compose.sha256 \
  https://github.com/explicitcontextualunderstanding/Container-Compose/releases/latest/download/container-compose.sha256

# Verify
shasum -a 256 -c container-compose.sha256

# Or manually check
shasum -a 256 ./container-compose
```

### 2. GitHub Attestation

Each release is cryptographically attested via GitHub Actions. Verify the attestation:

```bash
# Using GitHub CLI
gh attestation verify container-compose --owner explicitcontextualunderstanding

# Or with specific release
gh attestation verify container-compose \
  --repo explicitcontextualunderstanding/Container-Compose \
  --predicate-type https://slsa.dev/provenance/v1
```

## Reproducible Builds

You can rebuild the binary from source and compare:

### Build Environment

- **OS**: macOS 26.x
- **Xcode**: 26.3
- **Swift**: 6.2
- **Architecture**: arm64 (Apple Silicon)

### Build Steps

```bash
# Clone the repository
git clone https://github.com/explicitcontextualunderstanding/Container-Compose.git
cd Container-Compose

# Checkout the release tag
git checkout v0.10.1

# Build release binary
./build-release.sh

# Generate checksum
shasum -a 256 .build/release/container-compose
```

### Expected Result

The SHA256 hash should match the release checksum file. Note that fully reproducible builds require the exact same toolchain versions.

## Security

### Trust Model

1. **Source Code**: Publicly auditable on GitHub
2. **CI/CD**: GitHub Actions with transparent build logs
3. **Attestation**: Cryptographic proof of build provenance
4. **Checksums**: SHA256 for integrity verification

### Reporting Issues

If verification fails:
1. Check your download completed successfully
2. Verify you're using the correct platform binary
3. Open an issue at: https://github.com/explicitcontextualunderstanding/Container-Compose/issues

## Verification Automation

Add to your CI/CD pipeline:

```yaml
- name: Verify container-compose
  run: |
    curl -L -o container-compose.sha256 \
      https://github.com/explicitcontextualunderstanding/Container-Compose/releases/download/v0.10.1/container-compose.sha256
    EXPECTED_HASH=$(cut -d' ' -f1 container-compose.sha256)
    ACTUAL_HASH=$(shasum -a 256 /usr/local/bin/container-compose | cut -d' ' -f1)
    if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
      echo "Verification failed! Expected: $EXPECTED_HASH, Got: $ACTUAL_HASH"
      exit 1
    fi
    echo "✓ Binary verified"
```

---

*Last updated: 2026-03-24*
