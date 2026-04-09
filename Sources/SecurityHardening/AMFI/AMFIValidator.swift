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
        public let signingTimestamp: Date?
        public let usesHardenedRuntime: Bool
        public let gatekeeperStatus: GatekeeperStatus
        public let requirements: String?

        public init(
            isValid: Bool,
            isSigned: Bool,
            isAdHocSigned: Bool = false,
            teamIdentifier: String? = nil,
            issues: [ValidationIssue] = [],
            signingTimestamp: Date? = nil,
            usesHardenedRuntime: Bool = false,
            gatekeeperStatus: GatekeeperStatus = .unknown,
            requirements: String? = nil
        ) {
            self.isValid = isValid
            self.isSigned = isSigned
            self.isAdHocSigned = isAdHocSigned
            self.teamIdentifier = teamIdentifier
            self.issues = issues
            self.signingTimestamp = signingTimestamp
            self.usesHardenedRuntime = usesHardenedRuntime
            self.gatekeeperStatus = gatekeeperStatus
            self.requirements = requirements
        }

        public static let invalid = ValidationResult(
            isValid: false,
            isSigned: false,
            issues: [.unsigned],
            gatekeeperStatus: .unsigned
        )
    }

    /// Gatekeeper assessment status
    public enum GatekeeperStatus: String, Sendable, Equatable {
        case approved
        case denied
        case unknown
        case developerID
        case adHoc
        case unsigned

        public var description: String {
            switch self {
            case .approved: return "Approved by Gatekeeper"
            case .denied: return "Blocked by Gatekeeper"
            case .unknown: return "Unknown status"
            case .developerID: return "Signed with Developer ID"
            case .adHoc: return "Ad-hoc signed (no Team ID)"
            case .unsigned: return "Not signed"
            }
        }
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

    /// Comprehensive validation using spctl (Gatekeeper), timestamp, and hardened runtime
    /// This works WITHOUT a paid Developer ID - validates what's possible locally
    public func verifySignature(at path: String) async -> ValidationResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return ValidationResult(
                isValid: false,
                isSigned: false,
                issues: [.verificationFailed("File not found: \(path)")],
                gatekeeperStatus: .unsigned
            )
        }

        // Step 1: Basic codesign verification
        let basicResult = await runCodesignVerification(at: path)

        // Step 2: Check spctl (Gatekeeper) - works with ad-hoc signing locally
        let gatekeeperStatus = await runSpctlAssessment(at: path)

        // Step 3: Check for hardened runtime
        let usesHardenedRuntime = await checkHardenedRuntime(at: path)

        // Step 4: Extract signing timestamp if available
        let signingTimestamp = await extractSigningTimestamp(at: path)

        // Step 5: Extract requirements for audit
        let requirements = await extractRequirements(at: path)

        // Determine if ad-hoc signed
        let isAdHoc = teamIdentifier(from: basicResult) == nil && basicResult.isSigned

        return ValidationResult(
            isValid: basicResult.isValid,
            isSigned: basicResult.isSigned,
            isAdHocSigned: isAdHoc,
            teamIdentifier: teamIdentifier(from: basicResult),
            issues: basicResult.issues,
            signingTimestamp: signingTimestamp,
            usesHardenedRuntime: usesHardenedRuntime,
            gatekeeperStatus: gatekeeperStatus,
            requirements: requirements
        )
    }

    private func runCodesignVerification(at path: String) async -> ValidationResult {
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

    private func runSpctlAssessment(at path: String) async -> GatekeeperStatus {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/spctl")
        task.arguments = ["--assess", "--type", "exec", "--verbose", "2", path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if output.contains("accepted") || output.contains("origin=no") {
                return .approved
            } else if output.contains("origin=developer") {
                return .developerID
            } else if output.contains("origin=-") {
                return .adHoc
            } else if task.terminationStatus != 0 {
                return .denied
            }
            return .unknown
        } catch {
            return .unknown
        }
    }

    private func checkHardenedRuntime(at path: String) async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("runtime")
        } catch {
            return false
        }
    }

    private func extractSigningTimestamp(at path: String) async -> Date? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "-r-", path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Try to extract timestamp from requirements
            // Format: anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.2.1] exists
            if let match = output.range(of: #"timestamp=#([^]]+)"#, options: .regularExpression) {
                let timestampStr = String(output[match]).replacingOccurrences(of: "timestamp=", with: "")
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
                return formatter.date(from: String(timestampStr))
            }
            return nil
        } catch {
            return nil
        }
    }

    private func extractRequirements(at path: String) async -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "-r-", path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func teamIdentifier(from result: ValidationResult) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "-v", "/dev/null"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if let range = output.range(of: "TeamIdentifier=") {
                let remaining = output[range.upperBound...]
                if let end = remaining.firstIndex(of: "\n") ?? remaining.firstIndex(of: " ") {
                    return String(remaining[..<end])
                }
            }
            return nil
        } catch {
            return nil
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
