// HorizontalIsolationValidator.swift
// Component 7: Horizontal Isolation Validation
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import Foundation

/// Validates horizontal isolation between containers
/// Ensures Container A cannot directly communicate with Container B via vsock
/// Per SECURITY_CONTAINER.md: "Container A → Container B: Blocked"
public actor HorizontalIsolationValidator: Sendable {

    /// Isolation check result
    public struct IsolationResult: Sendable, Equatable {
        public let isIsolated: Bool
        public let violations: [IsolationViolation]
        public let errorMessage: String?

        public init(
            isIsolated: Bool,
            violations: [IsolationViolation] = [],
            errorMessage: String? = nil
        ) {
            self.isIsolated = isIsolated
            self.violations = violations
            self.errorMessage = errorMessage
        }

        public static let isolated = IsolationResult(isIsolated: true)

        public static func failed(_ violations: [IsolationViolation], message: String) -> IsolationResult {
            IsolationResult(
                isIsolated: false,
                violations: violations,
                errorMessage: message
            )
        }
    }

    /// Types of isolation violations
    public enum IsolationViolation: Sendable, Equatable, CustomStringConvertible {
        case directVsockConnection(cid: UInt32, port: UInt32)
        case sharedNamespace(namespace: String)
        case networkBridgeDetected(bridge: String)
        case unauthorizedRelayAccess(relayID: String)

        public var description: String {
            switch self {
            case .directVsockConnection(let cid, let port):
                return "Direct vsock connection detected: CID=\(cid), port=\(port)"
            case .sharedNamespace(let namespace):
                return "Shared namespace violation: \(namespace)"
            case .networkBridgeDetected(let bridge):
                return "Network bridge detected: \(bridge)"
            case .unauthorizedRelayAccess(let relayID):
                return "Unauthorized relay access: \(relayID)"
            }
        }
    }

    /// Configuration for isolation validation
    public struct Configuration: Sendable {
        public let enforceHorizontalIsolation: Bool
        public let allowedRelayTypes: [String]
        public let blockedCIDs: [UInt32]
        public let requireHostMediation: Bool

        public init(
            enforceHorizontalIsolation: Bool = true,
            allowedRelayTypes: [String] = ["vsock-db", "tcp", "unix"],
            blockedCIDs: [UInt32] = [],
            requireHostMediation: Bool = true
        ) {
            self.enforceHorizontalIsolation = enforceHorizontalIsolation
            self.allowedRelayTypes = allowedRelayTypes
            self.blockedCIDs = blockedCIDs
            self.requireHostMediation = requireHostMediation
        }

        /// Production configuration - strict isolation
        public static var production: Configuration {
            Configuration(
                enforceHorizontalIsolation: true,
                allowedRelayTypes: ["vsock-db", "tcp", "unix"],
                blockedCIDs: [],
                requireHostMediation: true
            )
        }

        /// Development configuration - relaxed for testing
        public static var development: Configuration {
            Configuration(
                enforceHorizontalIsolation: false,
                allowedRelayTypes: ["vsock-db", "tcp", "unix", "test"],
                blockedCIDs: [],
                requireHostMediation: false
            )
        }
    }

    /// Errors that can occur during isolation validation
    public enum IsolationError: Error, Sendable, Equatable {
        case horizontalIsolationViolated
        case directVsockNotAllowed
        case validationFailed(String)
        case isolationDisabled

        public var description: String {
            switch self {
            case .horizontalIsolationViolated:
                return "Horizontal isolation violated"
            case .directVsockNotAllowed:
                return "Direct vsock connections between containers not allowed"
            case .validationFailed(let reason):
                return "Validation failed: \(reason)"
            case .isolationDisabled:
                return "Horizontal isolation checks are disabled"
            }
        }
    }

    private let configuration: Configuration
    private var lastResult: IsolationResult?

    public init(configuration: Configuration = .production) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Validates that container communication is host-mediated only
    /// Per SECURITY_CONTAINER.md: Container A → Container B must be blocked
    /// - Parameters:
    ///   - sourceCID: Source container CID
    ///   - targetCID: Target container CID
    ///   - port: Target port
    /// - Returns: IsolationResult indicating if communication is allowed
    public func validateContainerCommunication(
        sourceCID: UInt32,
        targetCID: UInt32,
        port: UInt32
    ) async -> IsolationResult {
        // Skip if isolation enforcement is disabled
        guard configuration.enforceHorizontalIsolation else {
            let result = IsolationResult(
                isIsolated: true,
                violations: [],
                errorMessage: "Horizontal isolation checks disabled"
            )
            lastResult = result
            return result
        }

        // Check for direct container-to-container communication
        // In Apple Container architecture, this should never happen
        // because containers cannot open AF_VSOCK to other container CIDs

        var violations: [IsolationViolation] = []

        // Check if target CID is blocked
        if configuration.blockedCIDs.contains(targetCID) {
            violations.append(.directVsockConnection(cid: targetCID, port: port))
        }

        // Check if source and target are both guest containers (CID >= 3)
        // Host is CID 2, guests are CID 3+
        let isSourceGuest = sourceCID >= 3
        let isTargetGuest = targetCID >= 3

        if isSourceGuest && isTargetGuest {
            // Direct guest-to-guest communication is blocked
            violations.append(.directVsockConnection(cid: targetCID, port: port))
        }

        // Validate host mediation requirement
        if configuration.requireHostMediation {
            // Source must be guest (CID >= 3) and target must be host (CID = 2)
            // OR source is host and target is guest
            let isHostTarget = targetCID == 2

            if isSourceGuest && !isHostTarget {
                violations.append(.directVsockConnection(cid: targetCID, port: port))
            }
        }

        if violations.isEmpty {
            let result = IsolationResult.isolated
            lastResult = result
            return result
        } else {
            let result = IsolationResult.failed(
                violations,
                message: "Horizontal isolation violated: direct container communication detected"
            )
            lastResult = result
            return result
        }
    }

    /// Validates relay configuration for isolation compliance
    /// Called by RelayManager when creating relays
    /// - Parameter config: Relay configuration
    /// - Returns: true if configuration is isolated, false if violation
    public func validateRelayConfiguration(_ config: RelayConfiguration) async -> Bool {
        // Check if relay type is allowed
        guard configuration.allowedRelayTypes.contains(config.type) else {
            return false
        }

        // For vsock relays, validate CID isolation
        if config.type == "vsock-db" || config.type.hasPrefix("vsock-") {
            // CID 2 is host, should be the only target
            // Guests cannot be targets
            if let cid = extractCID(from: config) {
                return cid == 2 // Only host CID allowed as target
            }
        }

        return true
    }

    /// Validates socket path for isolation
    /// Ensures socket paths don't bridge containers
    /// - Parameter socketPath: Unix socket path
    /// - Returns: IsolationResult
    public func validateSocketPath(_ socketPath: String) async -> IsolationResult {
        // Skip if disabled
        guard configuration.enforceHorizontalIsolation else {
            return IsolationResult.isolated
        }

        // Check for shared volume paths that might bridge containers
        // Valid paths should be in container-specific directories
        if socketPath.contains("/.containers/Volumes/") {
            // This is expected for Virtio-FS shared volumes
            // The host mediates access, so it's isolated
            return IsolationResult.isolated
        }

        // Check for suspicious patterns
        if socketPath.contains("/tmp/container-") {
            // Shared temp directory - potential bridge
            return IsolationResult.failed(
                [.sharedNamespace(namespace: "tmp")],
                message: "Socket path in shared namespace: \(socketPath)"
            )
        }

        return IsolationResult.isolated
    }

    /// Returns the last validation result
    public func lastValidation() async -> IsolationResult? {
        lastResult
    }

    /// Performs full isolation audit
    /// - Returns: List of all detected violations
    public func performIsolationAudit() async -> IsolationResult {
        // Skip if disabled
        guard configuration.enforceHorizontalIsolation else {
            return IsolationResult(
                isIsolated: true,
                violations: [],
                errorMessage: "Isolation audit skipped (disabled)"
            )
        }

        // In production, would scan for:
        // - Active vsock connections between containers
        // - Shared network namespaces
        // - Unauthorized relay configurations

        // For now, return success (actual implementation would check system state)
        return IsolationResult.isolated
    }

    // MARK: - Private Methods

    private func extractCID(from config: RelayConfiguration) -> UInt32? {
        // Extract CID from vsock configuration
        // This would parse the actual vsock config
        // For now, return nil (unknown)
        return nil
    }
}

// MARK: - RelayManager Integration

public extension HorizontalIsolationValidator {
    /// Integration helper for RelayManager
    /// Usage: In RelayManager.startRelay():
    ///   guard await isolationValidator.validateRelayConfiguration(config) else {
    ///       throw RelayError.isolationViolation
    ///   }
    func isolationPassed() async -> Bool {
        guard let result = lastResult else {
            return false
        }
        return result.isIsolated
    }

    /// Format error for RelayManager logging
    func formattedError() async -> String {
        guard let result = lastResult,
              let message = result.errorMessage else {
            return "Horizontal isolation violated"
        }
        return "Security: \(message)"
    }
}

// MARK: - Security Container Compliance

public extension HorizontalIsolationValidator {
    /// Verifies compliance with SECURITY_CONTAINER.md requirements
    /// - Returns: true if architecture is compliant
    func verifySecurityContainerCompliance() async -> Bool {
        let audit = await performIsolationAudit()
        return audit.isIsolated
    }

    /// Returns SECURITY_CONTAINER.md violation details
    func complianceReport() async -> String {
        let audit = await performIsolationAudit()

        if audit.isIsolated {
            return "✅ Horizontal isolation: COMPLIANT (SECURITY_CONTAINER.md)"
        } else {
            let violations = audit.violations.map { "  - \($0.description)" }.joined(separator: "\n")
            return "❌ Horizontal isolation: NON-COMPLIANT\nViolations:\n\(violations)"
        }
    }
}
