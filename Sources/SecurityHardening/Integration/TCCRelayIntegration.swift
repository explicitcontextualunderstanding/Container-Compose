// TCCRelayIntegration.swift
// Component 5: TCC Integration in RelayManager
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import Foundation

/// TCC integration for RelayManager security preflight checks
/// Adds TCC permission validation before container/relay startup
public actor TCCRelayIntegration: Sendable {

    /// Integration configuration
    public struct Configuration: Sendable {
        public let enforceTCCAuthorization: Bool
        public let preflightTimeout: TimeInterval
        public let allowPromptIfNotDetermined: Bool

        public init(
            enforceTCCAuthorization: Bool = true,
            preflightTimeout: TimeInterval = 30.0,
            allowPromptIfNotDetermined: Bool = false
        ) {
            self.enforceTCCAuthorization = enforceTCCAuthorization
            self.preflightTimeout = preflightTimeout
            self.allowPromptIfNotDetermined = allowPromptIfNotDetermined
        }

        /// Production configuration - strict TCC enforcement
        public static var production: Configuration {
            Configuration(
                enforceTCCAuthorization: true,
                preflightTimeout: 30.0,
                allowPromptIfNotDetermined: false
            )
        }

        /// Development configuration - allows notDetermined status
        public static var development: Configuration {
            Configuration(
                enforceTCCAuthorization: false,
                preflightTimeout: 10.0,
                allowPromptIfNotDetermined: true
            )
        }
    }

    /// Preflight check result
    public struct PreflightResult: Sendable, Equatable {
        public let canProceed: Bool
        public let status: TCCChecker.AuthorizationStatus
        public let errorMessage: String?
        public let shouldBlockStartup: Bool

        public init(
            canProceed: Bool,
            status: TCCChecker.AuthorizationStatus,
            errorMessage: String? = nil,
            shouldBlockStartup: Bool = false
        ) {
            self.canProceed = canProceed
            self.status = status
            self.errorMessage = errorMessage
            self.shouldBlockStartup = shouldBlockStartup
        }

        public static let authorized = PreflightResult(
            canProceed: true,
            status: .authorized
        )
    }

    /// Errors that can occur during TCC integration
    public enum TCCIntegrationError: Error, Sendable, Equatable {
        case tccDenied
        case tccNotDetermined
        case tccUnknown
        case preflightTimeout
        case integrationDisabled

        public var description: String {
            switch self {
            case .tccDenied:
                return "TCC permission denied for hypervisor"
            case .tccNotDetermined:
                return "TCC permission not determined"
            case .tccUnknown:
                return "TCC status unknown"
            case .preflightTimeout:
                return "TCC preflight check timed out"
            case .integrationDisabled:
                return "TCC integration is disabled"
            }
        }
    }

    private let configuration: Configuration
    private let tccChecker: TCCChecker
    private var lastPreflightResult: PreflightResult?

    public init(
        configuration: Configuration = .production,
        tccChecker: TCCChecker = TCCChecker()
    ) {
        self.configuration = configuration
        self.tccChecker = tccChecker
    }

    // MARK: - Public API

    /// Performs preflight check before relay/container startup
    /// This is the main entry point for RelayManager integration
    /// - Returns: PreflightResult indicating if startup should proceed
    public func preflightCheck() async -> PreflightResult {
        // Skip if TCC enforcement is disabled
        guard configuration.enforceTCCAuthorization else {
            let result = PreflightResult(
                canProceed: true,
                status: .unknown,
                errorMessage: "TCC enforcement disabled",
                shouldBlockStartup: false
            )
            lastPreflightResult = result
            return result
        }

        // Perform TCC check with timeout
        let status: TCCChecker.AuthorizationStatus
        do {
            status = try await withTimeout(seconds: configuration.preflightTimeout) {
                await tccChecker.checkHypervisorAuthorization()
            }
        } catch {
            let result = PreflightResult(
                canProceed: false,
                status: .unknown,
                errorMessage: TCCIntegrationError.preflightTimeout.description,
                shouldBlockStartup: true
            )
            lastPreflightResult = result
            return result
        }

        // Evaluate status and determine if we can proceed
        let result = evaluateStatus(status)
        lastPreflightResult = result
        return result
    }

    /// Validates TCC status before starting a specific relay
    /// Called by RelayManager.startRelay() for each relay
    /// - Parameter relayType: The type of relay being started
    /// - Returns: true if relay can start, false if blocked
    public func validateRelayStartup(relayType: String) async -> Bool {
        let result = await preflightCheck()

        guard result.canProceed else {
            // Log the security block
            await logSecurityBlock(
                relayType: relayType,
                reason: result.errorMessage ?? "TCC check failed"
            )
            return false
        }

        return true
    }

    /// Validates TCC before container startup (Plan 84 Phase 5)
    /// Called before container-compose up
    /// - Returns: Error message if startup should be blocked, nil if OK
    public func validateContainerStartup() async -> String? {
        let result = await preflightCheck()

        if result.shouldBlockStartup {
            return result.errorMessage ?? "Container startup blocked by TCC check"
        }

        if !result.canProceed {
            return result.errorMessage ?? "TCC authorization required"
        }

        return nil
    }

    /// Returns the last preflight result (for diagnostics)
    public func lastPreflight() async -> PreflightResult? {
        lastPreflightResult
    }

    /// Returns detailed TCC status for logging
    public func detailedStatus() async -> TCCChecker.PermissionResult {
        await tccChecker.queryTCCDatabase(for: "com.apple.security.hypervisor")
    }

    // MARK: - Private Methods

    private func evaluateStatus(_ status: TCCChecker.AuthorizationStatus) -> PreflightResult {
        switch status {
        case .authorized:
            return .authorized

        case .denied:
            return PreflightResult(
                canProceed: false,
                status: .denied,
                errorMessage: "TCC permission denied. Grant 'Developer Tools' permission in System Settings > Privacy & Security > Developer Tools",
                shouldBlockStartup: true
            )

        case .notDetermined:
            if configuration.allowPromptIfNotDetermined {
                return PreflightResult(
                    canProceed: true,
                    status: .notDetermined,
                    errorMessage: "TCC permission not determined - user prompt may appear",
                    shouldBlockStartup: false
                )
            } else {
                return PreflightResult(
                    canProceed: false,
                    status: .notDetermined,
                    errorMessage: "TCC permission not determined. Run 'tccutil reset All' and retry",
                    shouldBlockStartup: true
                )
            }

        case .unknown:
            return PreflightResult(
                canProceed: false,
                status: .unknown,
                errorMessage: "Unable to determine TCC status",
                shouldBlockStartup: true
            )
        }
    }

    private func logSecurityBlock(relayType: String, reason: String) async {
        // Log to ESF if available
        // This would integrate with ESFClient from Component 2
        print("[SECURITY] Relay startup blocked: type=\(relayType), reason=\(reason)")
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add the actual operation
            group.addTask {
                await operation()
            }

            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TCCIntegrationError.preflightTimeout
            }

            // Return first result, cancel the other
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - RelayManager Integration Helpers

public extension TCCRelayIntegration {
    /// Convenience method for RelayManager to check before starting any relay
    /// Usage: In RelayManager.startRelay(), add at beginning:
    ///   guard await tccIntegration.preflightCheckPassed() else { return }
    func preflightCheckPassed() async -> Bool {
        let result = await preflightCheck()
        return result.canProceed && !result.shouldBlockStartup
    }

    /// Returns a formatted error message for RelayManager to display
    func lastErrorMessage() async -> String? {
        guard let result = lastPreflightResult else {
            return nil
        }
        return result.errorMessage
    }
}
