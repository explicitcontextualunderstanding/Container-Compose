//===----------------------------------------------------------------------===//
// TestImageConstants.swift
// Standardized image references for Container-Compose tests
//
// STRATEGY:
// - Use pgmicro (wire-compatible PostgreSQL) for almost all database tests
//   - 2-5s startup vs 30s for full PostgreSQL
//   - In-memory, no volume persistence issues
//   - Same socket behavior, wire protocol compatible
// - Only use full PostgreSQL images when testing pgvector or other extensions
// - Prefer alpine variants for local container daemon cache hits
// - Use ${OCI_REGISTRY_URL} for LAN registry images (pgmicro, etc.)
//===----------------------------------------------------------------------===//

import Foundation

/// Standardized image constants for Container-Compose tests
/// Use these instead of hardcoding image strings
public enum TestImages {

    // MARK: - Database Images

    /// Default PostgreSQL-compatible database image for tests
    /// Uses pgmicro (wire-compatible, in-memory) for fast startup (2-5s vs 30s)
    /// Set OCI_REGISTRY_URL env var to use local LAN registry (e.g., REMOVED_REGISTRY_URL)
    public static let pgmicro = "${OCI_REGISTRY_URL}/pgmicro:latest"

    /// Fallback alpine-based PostgreSQL for tests requiring full PostgreSQL features
    /// (e.g., pgvector extensions) - only use when pgmicro doesn't support needed feature
    public static let postgres = "postgres:15-alpine"

    // MARK: - Web/Proxy Images (available in local container daemon)

    /// Standard nginx image - alpine variant for smaller size
    public static let nginx = "nginx:alpine"

    /// Node.js for frontend apps
    public static let node = "node:18-alpine"

    // MARK: - Cache/Queue Images (available in local container daemon)

    /// Redis for caching
    public static let redis = "redis:alpine"

    // MARK: - Utility Images (available in local container daemon)

    /// Busybox for minimal containers
    public static let busybox = "busybox:latest"

    /// Alpine for minimal containers
    public static let alpine = "alpine:latest"

    /// Python for scripting
    public static let python = "python:3.12-alpine"

    // MARK: - Application Images

    /// WordPress with PHP-FPM
    public static let wordpress = "wordpress:fpm-alpine"

    /// MySQL (for legacy compatibility)
    public static let mysql = "mysql:8.0"

    /// pgvector for vector database tests (use only when testing vector features)
    public static let pgvector = "pgvector/pgvector:pg15"
}

/// Helper to get OCI registry URL from environment
/// Falls back to docker.io if not set
public func getOCIRegistryURL() -> String {
    return ProcessInfo.processInfo.environment["OCI_REGISTRY_URL"] ?? "docker.io"
}

/// Resolves image references with variable substitution
/// - Parameter image: Image reference potentially containing ${OCI_REGISTRY_URL}
/// - Returns: Resolved image reference
public func resolveImageReference(_ image: String) -> String {
    return image.replacingOccurrences(
        of: "${OCI_REGISTRY_URL}",
        with: getOCIRegistryURL()
    )
}
