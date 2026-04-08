// AMFIRelayGating.swift
// Component 6: AMFI Gating for Phase 6 (socat removal)
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import Foundation

/// AMFI gating for Plan 84 Phase 6 - controls socat removal
/// Validates code signature before allowing native relay activation
public actor AMFIRelayGating: Sendable {

    /// Gating configuration
    public struct Configuration: Sendable {
        public let enforceAMFIValidation: Bool
        public let requireHypervisorEntitlement: Bool
        public let allowAdHocSigning: Bool
        public let gateSocatRemoval: Bool

        public init(
            enforceAMFIValidation: Bool = true,
            requireHypervisorEntitlement: Bool = true,
            allowAdHocSigning: Bool = false,
            gateSocatRemoval: Bool = true
        ) {
            self.enforceAMFIValidation = enforceAMFIValidation
            self.requireHypervisorEntitlement = requireHypervisorEntitlement
            self.allowAdHocSigning = allowAdHocSigning
            self.gateSocatRemoval = gateSocatRemoval
        }

        /// Production configuration - strict validation
        public static var production: Configuration {
            Configuration(
                enforceAMFIValidation: true,
                requireHypervisorEntitlement: true,
                allowAdHocSigning: false,
                gateSocatRemoval: true
            )
        }

        /// Development configuration - relaxed for testing
        public static var development: Configuration {
            Configuration(
                enforceAMFIValidation: false,
                requireHypervisorEntitlement: false,
                allowAdHocSigning: true,
                gateSocatRemoval: false
            )
        }
    }

    /// Gating result for socat removal decision
    public struct GatingResult: Sendable, Equatable {
        public let canRemoveSocat: Bool
        public let isValidated: Bool
        public let validationIssues: [AMFIValidator.ValidationIssue]
        public let errorMessage: String?
        public let shouldUseNativeRelay: Bool

        public init(
            canRemoveSocat: Bool,
            isValidated: Bool,
            validationIssues: [AMFIValidator.ValidationIssue] = [],
            errorMessage: String? = nil,
            shouldUseNativeRelay: Bool = false
        ) {
            self.canRemoveSocat = canRemoveSocat
            self.isValidated = isValidated
            self.validationIssues = validationIssues
            self.errorMessage = errorMessage
            self.shouldUseNativeRelay = shouldUseNativeRelay
        }

        /// Success result - native relay validated, socat can be removed
        public static let validated = GatingResult(
            canRemoveSocat: true,
            isValidated: true,
            shouldUseNativeRelay: true
        )

        /// Failure result - must keep socat
        public static func failed(_ message: String, issues: [AMFIValidator.ValidationIssue] = []) -> GatingResult {
            GatingResult(
                canRemoveSocat: false,
                isValidated: false,
                validationIssues: issues,
                errorMessage: message,
                shouldUseNativeRelay: false
            )
        }
    }

    /// Errors that can occur during AMFI gating
    public enum AMFIGatingError: Error, Sendable, Equatable {
        case signatureInvalid
        case hypervisorEntitlementMissing
        case adHocSigningNotAllowed
        case validationFailed(String)
        case gatingDisabled

        public var description: String {
            switch self {
            case .signatureInvalid:
                return "Code signature is invalid"
            case .hypervisorEntitlementMissing:
                return "Hypervisor entitlement not found"
            case .adHocSigningNotAllowed:
                return "Ad-hoc signing not allowed in production"
            case .validationFailed(let reason):
                return "Validation failed: \(reason)"
            case .gatingDisabled:
                return "AMFI gating is disabled"
            }
        }
    }

    private let configuration: Configuration
    private let amfiValidator: AMFIValidator
    private var lastGatingResult: GatingResult?

    public init(
        configuration: Configuration = .production,
        amfiValidator: AMFIValidator = AMFIValidator()
    ) {
        self.configuration = configuration
        self.amfiValidator = amfiValidator
    }

    // MARK: - Public API

    /// Validates binary for Phase 6 socat removal
    /// Called before allowing native relay to replace socat
    /// - Parameter binaryPath: Path to container-compose binary
    /// - Returns: GatingResult indicating if socat can be removed
    public func validateForSocatRemoval(binaryPath: String = "/usr/local/bin/container-compose") async -> GatingResult {
        // Skip if gating is disabled
        guard configuration.enforceAMFIValidation else {
            let result = GatingResult(
                canRemoveSocat: true,
                isValidated: false,
                errorMessage: "AMFI validation disabled",
                shouldUseNativeRelay: true
            )
            lastGatingResult = result
            return result
        }

        // Validate signature
        let signatureResult = await amfiValidator.verifySignature(at: binaryPath)

        guard signatureResult.isSigned else {
            let result = GatingResult.failed(
                "Binary is not code signed: \(binaryPath)",
                issues: signatureResult.issues
            )
            lastGatingResult = result
            return result
        }

        // Check ad-hoc signing
        if signatureResult.isAdHocSigned && !configuration.allowAdHocSigning {
            let result = GatingResult.failed(
                "Ad-hoc signing not allowed in production configuration",
                issues: [.adHocSigned]
            )
            lastGatingResult = result
            return result
        }

        // Validate hypervisor entitlement if required
        if configuration.requireHypervisorEntitlement {
            let entitlementResult = await amfiValidator.verifyEntitlement(
                "com.apple.security.hypervisor",
                at: binaryPath
            )

            guard entitlementResult.isValid else {
                var issues = entitlementResult.issues
                if !issues.contains(where: { issue in
                    if case .entitlementMissing = issue { return true }
                    return false
                }) {
                    issues.append(.entitlementMissing("com.apple.security.hypervisor"))
                }

                let result = GatingResult.failed(
                    "Hypervisor entitlement required for native relay",
                    issues: issues
                )
                lastGatingResult = result
                return result
            }
        }

        // All validations passed
        let result = GatingResult.validated
        lastGatingResult = result
        return result
    }

    /// Validates before starting native relay (Plan 84 Phase 6 gate)
    /// Called by RelayManager.startRelay() at line 224
    /// - Parameter binaryPath: Path to container-compose binary
    /// - Returns: true if native relay can start, false if must use socat
    public func validateBeforeRelayStart(binaryPath: String = "/usr/local/bin/container-compose") async -> Bool {
        let result = await validateForSocatRemoval(binaryPath: binaryPath)
        return result.shouldUseNativeRelay
    }

    /// Gate check for socat removal decision
    /// Used by orchestrator to decide whether to install/remove socat
    /// - Returns: true if socat can be removed, false if must keep
    public func canRemoveSocat() async -> Bool {
        let result = await validateForSocatRemoval()
        return result.canRemoveSocat
    }

    /// Returns the last gating result (for diagnostics)
    public func lastGating() async -> GatingResult? {
        lastGatingResult
    }

    /// Returns detailed validation status
    public func detailedValidation(binaryPath: String = "/usr/local/bin/container-compose") async -> AMFIValidator.ValidationResult {
        await amfiValidator.verifySignature(at: binaryPath)
    }

    // MARK: - Convenience Methods

    /// Quick check if binary is signed and entitled
    public func isSecurityValidated(binaryPath: String = "/usr/local/bin/container-compose") async -> Bool {
        let result = await validateForSocatRemoval(binaryPath: binaryPath)
        return result.isValidated && result.canRemoveSocat
    }

    /// Returns error message for last validation failure
    public func lastErrorMessage() async -> String? {
        lastGatingResult?.errorMessage
    }
}

// MARK: - RelayManager Integration

public extension AMFIRelayGating {
    /// Integration helper for RelayManager
    /// Usage: In RelayManager.startRelay() at line 224:
    ///   guard await amfiGating.validateBeforeRelayStart() else {
    ///       // Fall back to socat
    ///       return try await startSocatRelay(config)
    ///   }
    func gatingPassed(binaryPath: String = "/usr/local/bin/container-compose") async -> Bool {
        await validateBeforeRelayStart(binaryPath: binaryPath)
    }

    /// Format error for RelayManager logging
    func formattedError() async -> String {
        guard let result = lastGatingResult,
              let message = result.errorMessage else {
            return "AMFI validation failed (unknown reason)"
        }
        return "Security gating: \(message)"
    }
}

// MARK: - Phase 6 Orchestrator Integration

public extension AMFIRelayGating {
    /// Used by Phase 6 orchestrator to decide socat fate
    /// - Returns: (canRemove: Bool, error: String?)
    func phase6Decision(binaryPath: String = "/usr/local/bin/container-compose") async -> (canRemove: Bool, error: String?) {
        let result = await validateForSocatRemoval(binaryPath: binaryPath)
        return (result.canRemoveSocat, result.errorMessage)
    }
}
