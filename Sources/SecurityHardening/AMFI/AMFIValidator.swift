// AMFIValidator.swift
// Component 3: AMFI Validation Utilities
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import Foundation

/// AMFI (Apple Mobile File Integrity) validation utilities
/// Verifies code signatures and entitlements for security gating
public actor AMFIValidator: Sendable {

    /// Validation result with detailed status
    public struct ValidationResult: Sendable, Equatable {
        public let isValid: Bool
        public let isSigned: Bool
        public let isAdHocSigned: Bool
        public let teamIdentifier: String?
        public let issues: [ValidationIssue]

        public init(
            isValid: Bool,
            isSigned: Bool,
            isAdHocSigned: Bool = false,
            teamIdentifier: String? = nil,
            issues: [ValidationIssue] = []
        ) {
            self.isValid = isValid
            self.isSigned = isSigned
            self.isAdHocSigned = isAdHocSigned
            self.teamIdentifier = teamIdentifier
            self.issues = issues
        }

        public static let invalid = ValidationResult(
            isValid: false,
            isSigned: false,
            issues: [.unsigned]
        )
    }

    /// Validation issues that can occur
    public enum ValidationIssue: Error, Sendable, Equatable, CustomStringConvertible {
        case unsigned
        case adHocSigned
        case signatureInvalid
        case entitlementMissing(String)
        case verificationFailed(String)

        public var description: String {
            switch self {
            case .unsigned:
                return "Binary is not code signed"
            case .adHocSigned:
                return "Binary is ad-hoc signed (no Team ID)"
            case .signatureInvalid:
                return "Code signature is invalid"
            case .entitlementMissing(let key):
                return "Required entitlement missing: \(key)"
            case .verificationFailed(let reason):
                return "Verification failed: \(reason)"
            }
        }
    }

    /// Configuration for validation
    public struct Configuration: Sendable {
        public let requiredTeamIdentifier: String?
        public let requiredEntitlements: [String]
        public let allowAdHocSigning: Bool

        public init(
            requiredTeamIdentifier: String? = nil,
            requiredEntitlements: [String] = [],
            allowAdHocSigning: Bool = false
        ) {
            self.requiredTeamIdentifier = requiredTeamIdentifier
            self.requiredEntitlements = requiredEntitlements
            self.allowAdHocSigning = allowAdHocSigning
        }

        /// Standard configuration for production
        public static var standard: Configuration {
            Configuration(
                requiredEntitlements: [
                    "com.apple.security.hypervisor"
                ],
                allowAdHocSigning: false
            )
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Verifies code signature of a binary at the given path
    public func verifySignature(at path: String) async -> ValidationResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return ValidationResult(
                isValid: false,
                isSigned: false,
                issues: [.verificationFailed("File not found: \(path)")]
            )
        }

        // Use codesign command for verification
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-v", path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                return ValidationResult(
                    isValid: true,
                    isSigned: true
                )
            } else {
                return ValidationResult(
                    isValid: false,
                    isSigned: false,
                    issues: [.signatureInvalid]
                )
            }
        } catch {
            return ValidationResult(
                isValid: false,
                isSigned: false,
                issues: [.verificationFailed(error.localizedDescription)]
            )
        }
    }

    /// Verifies specific entitlement is present
    public func verifyEntitlement(_ entitlement: String, at path: String) async -> ValidationResult {
        let baseResult = await verifySignature(at: path)

        guard baseResult.isSigned else {
            return baseResult
        }

        // Use codesign to dump entitlements
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "--entitlements", "-", path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            // Check if entitlement exists in plist
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               plist[entitlement] != nil {
                return baseResult
            } else {
                var issues = baseResult.issues
                issues.append(.entitlementMissing(entitlement))
                return ValidationResult(
                    isValid: false,
                    isSigned: baseResult.isSigned,
                    teamIdentifier: baseResult.teamIdentifier,
                    issues: issues
                )
            }
        } catch {
            var issues = baseResult.issues
            issues.append(.verificationFailed(error.localizedDescription))
            return ValidationResult(
                isValid: false,
                isSigned: baseResult.isSigned,
                teamIdentifier: baseResult.teamIdentifier,
                issues: issues
            )
        }
    }

    /// Validates binary for security gating
    public func validateForSecurityGating(at path: String) async -> Bool {
        for entitlement in configuration.requiredEntitlements {
            let result = await verifyEntitlement(entitlement, at: path)
            guard result.isValid else { return false }
        }
        return true
    }
}

// MARK: - Convenience Extensions

public extension AMFIValidator {
    /// Quick check if binary is code signed
    func isCodeSigned(at path: String) async -> Bool {
        let result = await verifySignature(at: path)
        return result.isSigned
    }

    /// Quick check if binary has hypervisor entitlement
    func hasHypervisorEntitlement(at path: String) async -> Bool {
        let result = await verifyEntitlement("com.apple.security.hypervisor", at: path)
        return result.isValid
    }
}
