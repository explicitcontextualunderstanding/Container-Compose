// SecureRelayManager.swift
// Security wrapper for RelayManager (Option B architecture)
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import Foundation
import SecurityHardening

// MARK: - Protocol for Relay Configuration

/// Protocol for relay configuration to avoid circular dependency with ContainerComposeCore
/// RelayManager.RelayConfiguration conforms to this protocol
public protocol RelayConfigProviding: Sendable {
    var relayId: String { get }
    var relayType: String { get }
    var relayTransport: RelayTransportType { get }
    var socketPath: String? { get }
    var cid: UInt32? { get }
}

/// Transport types for relay configuration
public enum RelayTransportType: String, Sendable, Codable {
    case vsock
    case unixSocket
    case tcp
}

/// Security wrapper for RelayManager that enforces TCC, AMFI, and isolation checks
/// Implements Option B architecture: cleaner, testable, non-invasive
public actor SecureRelayManager: Sendable {

    /// Security check result for relay operations
    public struct SecurityCheckResult: Sendable, Equatable {
        public let passed: Bool
        public let blockedBy: SecurityGate?
        public let errorMessage: String?
        public let logEntry: ESFClient.LogEntry?

        public init(
            passed: Bool,
            blockedBy: SecurityGate? = nil,
            errorMessage: String? = nil,
            logEntry: ESFClient.LogEntry? = nil
        ) {
            self.passed = passed
            self.blockedBy = blockedBy
            self.errorMessage = errorMessage
            self.logEntry = logEntry
        }

        public static let passed = SecurityCheckResult(passed: true)

        public static func blocked(_ gate: SecurityGate, message: String) -> SecurityCheckResult {
            SecurityCheckResult(
                passed: false,
                blockedBy: gate,
                errorMessage: message
            )
        }
    }

    /// Security gates that can block relay operations
    public enum SecurityGate: String, Sendable, CustomStringConvertible {
        case tccPreflight = "TCC Preflight"
        case amfiValidation = "AMFI Validation"
        case horizontalIsolation = "Horizontal Isolation"
        case relayConfiguration = "Relay Configuration"

        public var description: String { rawValue }
    }

    /// Configuration for secure relay manager
    public struct Configuration: Sendable {
        public let tccConfig: TCCRelayIntegration.Configuration
        public let amfiConfig: AMFIRelayGating.Configuration
        public let isolationConfig: HorizontalIsolationValidator.Configuration
        public let logSecurityEvents: Bool

        public init(
            tccConfig: TCCRelayIntegration.Configuration = .production,
            amfiConfig: AMFIRelayGating.Configuration = .production,
            isolationConfig: HorizontalIsolationValidator.Configuration = .production,
            logSecurityEvents: Bool = true
        ) {
            self.tccConfig = tccConfig
            self.amfiConfig = amfiConfig
            self.isolationConfig = isolationConfig
            self.logSecurityEvents = logSecurityEvents
        }

        /// Production configuration with all security gates enabled
        public static var production: Configuration {
            Configuration(
                tccConfig: .production,
                amfiConfig: .production,
                isolationConfig: .production,
                logSecurityEvents: true
            )
        }

        /// Development configuration with relaxed gates
        public static var development: Configuration {
            Configuration(
                tccConfig: .development,
                amfiConfig: .development,
                isolationConfig: .development,
                logSecurityEvents: true
            )
        }
    }

    private let configuration: Configuration
    private let tccIntegration: TCCRelayIntegration
    private let amfiGating: AMFIRelayGating
    private let isolationValidator: HorizontalIsolationValidator
    private let esfClient: ESFClient?

    /// Creates secure relay manager with security components
    public init(
        configuration: Configuration = .production,
        tccIntegration: TCCRelayIntegration? = nil,
        amfiGating: AMFIRelayGating? = nil,
        isolationValidator: HorizontalIsolationValidator? = nil,
        esfClient: ESFClient? = nil
    ) {
        self.configuration = configuration
        self.tccIntegration = tccIntegration ?? TCCRelayIntegration(configuration: configuration.tccConfig)
        self.amfiGating = amfiGating ?? AMFIRelayGating(configuration: configuration.amfiConfig)
        self.isolationValidator = isolationValidator ?? HorizontalIsolationValidator(configuration: configuration.isolationConfig)
        self.esfClient = esfClient
    }

    // MARK: - Public API

    /// Validates all security gates before relay startup
    /// Called by RelayManager.startRelay() wrapper
    public func validateRelayStartup(_ config: RelayConfiguration) async -> SecurityCheckResult {
        // Gate 1: TCC preflight
        let tccResult = await tccIntegration.preflightCheck()
        guard tccResult.canProceed && !tccResult.shouldBlockStartup else {
            let result = SecurityCheckResult.blocked(
                .tccPreflight,
                message: tccResult.errorMessage ?? "TCC check failed"
            )
            await logSecurityEvent(result, config: config)
            return result
        }

        // Gate 2: AMFI validation (for Phase 6 socat removal)
        let amfiResult = await amfiGating.validateForSocatRemoval()
        guard amfiResult.canRemoveSocat else {
            let result = SecurityCheckResult.blocked(
                .amfiValidation,
                message: amfiResult.errorMessage ?? "AMFI validation failed"
            )
            await logSecurityEvent(result, config: config)
            return result
        }

        // Gate 3: Horizontal isolation
        let isolationResult = await isolationValidator.validateRelayConfiguration(config)
        guard isolationResult else {
            let result = SecurityCheckResult.blocked(
                .horizontalIsolation,
                message: "Horizontal isolation violated"
            )
            await logSecurityEvent(result, config: config)
            return result
        }

        // All gates passed
        let result = SecurityCheckResult.passed
        await logSecurityEvent(result, config: config)
        return result
    }

    /// Validates container startup at ComposeUp level (global)
    /// Called once before container-compose up
    public func validateContainerStartup() async -> SecurityCheckResult {
        // Check TCC
        let tccError = await tccIntegration.preflightCheck()
        guard tccError.canProceed else {
            return SecurityCheckResult.blocked(
                .tccPreflight,
                message: tccError.errorMessage ?? "TCC authorization required"
            )
        }

        // Check AMFI
        let amfiResult = await amfiGating.validateForSocatRemoval()
        guard amfiResult.canRemoveSocat else {
            return SecurityCheckResult.blocked(
                .amfiValidation,
                message: amfiResult.errorMessage ?? "AMFI validation required"
            )
        }

        return SecurityCheckResult.passed
    }

    /// Validates CID-based communication for horizontal isolation
    /// Called when establishing vsock connections
    public func validateCIDCommunication(
        sourceCID: UInt32,
        targetCID: UInt32,
        port: UInt32
    ) async -> SecurityCheckResult {
        let result = await isolationValidator.validateContainerCommunication(
            sourceCID: sourceCID,
            targetCID: targetCID,
            port: port
        )

        if result.isIsolated {
            return SecurityCheckResult.passed
        } else {
            return SecurityCheckResult.blocked(
                .horizontalIsolation,
                message: result.errorMessage ?? "Direct container communication blocked"
            )
        }
    }

    /// Logs VM start event at ComposeUp level (global ESF logging)
    /// Called by ComposeUp when starting containers
    public func logVMStart(cid: UInt32, process: String) async {
        guard let esf = esfClient else { return }
        await esf.notifyVMStarted(cid: cid, process: process)
    }

    /// Logs relay start event
    public func logRelayStarted(port: UInt32, transport: String) async {
        guard let esf = esfClient else { return }
        await esf.logRelayStarted(port: port, transport: transport)
    }

    // MARK: - Status Queries

    /// Returns detailed security status for diagnostics
    public func securityStatus() async -> SecurityStatus {
        let tccStatus = await tccIntegration.detailedStatus()
        let amfiStatus = await amfiGating.detailedValidation()
        let isolationAudit = await isolationValidator.performIsolationAudit()

        return SecurityStatus(
            tccAuthorized: tccStatus.status == .authorized,
            amfiValidated: amfiStatus.isValid,
            isolationCompliant: isolationAudit.isIsolated,
            readyForPhase6: amfiStatus.isValid && amfiStatus.isSigned
        )
    }

    /// Returns true if ready for Phase 6 (socat removal)
    public func readyForPhase6() async -> Bool {
        let status = await securityStatus()
        return status.readyForPhase6
    }

    // MARK: - Private Methods

    private func logSecurityEvent(_ result: SecurityCheckResult, config: RelayConfiguration) async {
        guard configuration.logSecurityEvents,
              let esf = esfClient else { return }

        let event = ESFClient.LogEntry(
            timestamp: Date(),
            eventType: result.passed ? "SECURITY_GATE_PASSED" : "SECURITY_GATE_BLOCKED",
            cid: nil,
            process: "SecureRelayManager",
            details: "Gate: \(result.blockedBy?.description ?? "All"), Type: \(config.type), Passed: \(result.passed)"
        )

        _ = try? await esf.log(
            eventType: event.eventType,
            cid: event.cid,
            process: event.process,
            details: event.details
        )
    }
}

// MARK: - Supporting Types

public struct SecurityStatus: Sendable, Equatable {
    public let tccAuthorized: Bool
    public let amfiValidated: Bool
    public let isolationCompliant: Bool
    public let readyForPhase6: Bool

    public init(
        tccAuthorized: Bool,
        amfiValidated: Bool,
        isolationCompliant: Bool,
        readyForPhase6: Bool
    ) {
        self.tccAuthorized = tccAuthorized
        self.amfiValidated = amfiValidated
        self.isolationCompliant = isolationCompliant
        self.readyForPhase6 = readyForPhase6
    }
}

// MARK: - RelayManager Integration Helpers

public extension SecureRelayManager {
    /// Convenience method for RelayManager wrapper
    /// Usage:
    /// ```swift
    /// let secureManager = SecureRelayManager()
    /// guard await secureManager.canStartRelay(config) else { throw ... }
    /// return try await underlyingRelayManager.startRelay(config)
    /// ```
    func canStartRelay(_ config: RelayConfiguration) async -> Bool {
        let result = await validateRelayStartup(config)
        return result.passed
    }

    /// Returns formatted error message for last validation failure
    func lastSecurityError() async -> String? {
        // Could track last result if needed
        nil
    }
}
