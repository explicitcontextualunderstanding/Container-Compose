// TCCChecker.swift
// Component 4: TCC Permission Check Functions
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import Foundation

/// TCC (Transparency, Consent, and Control) permission checker
/// Queries TCC database for hypervisor and other security entitlements
public actor TCCChecker: Sendable {

    /// TCC authorization status
    public enum AuthorizationStatus: String, Sendable, Equatable, CustomStringConvertible {
        case authorized = "authorized"
        case denied = "denied"
        case notDetermined = "notDetermined"
        case unknown = "unknown"

        public var description: String {
            rawValue
        }

        public var isAuthorized: Bool {
            self == .authorized
        }
    }

    /// TCC permission request result
    public struct PermissionResult: Sendable, Equatable {
        public let service: String
        public let status: AuthorizationStatus
        public let lastModified: Date?
        public let error: String?

        public init(
            service: String,
            status: AuthorizationStatus,
            lastModified: Date? = nil,
            error: String? = nil
        ) {
            self.service = service
            self.status = status
            self.lastModified = lastModified
            self.error = error
        }
    }

    /// Configuration for TCC checking
    public struct Configuration: Sendable {
        public let timeout: TimeInterval
        public let usePrompt: Bool

        public init(
            timeout: TimeInterval = 30.0,
            usePrompt: Bool = true
        ) {
            self.timeout = timeout
            self.usePrompt = usePrompt
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Checks TCC authorization status for hypervisor entitlement
    /// - Returns: AuthorizationStatus indicating permission state
    public func checkHypervisorAuthorization() async -> AuthorizationStatus {
        // Query TCC database for hypervisor permission
        // This queries the TCC.db directly (read-only)

        let result = await queryTCCDatabase(for: "com.apple.security.hypervisor")

        return result.status
    }

    /// Queries TCC database for a specific service
    /// - Parameter service: The TCC service identifier
    /// - Returns: PermissionResult with status and metadata
    public func queryTCCDatabase(for service: String) async -> PermissionResult {
        // TCC database location: ~/Library/Application Support/com.apple.TCC/TCC.db
        // This is a read-only query to check current status

        let dbPath = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return PermissionResult(
                service: service,
                status: .unknown,
                error: "TCC database not found"
            )
        }

        // Use tccutil or sqlite3 to query (read-only)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [
            "-readonly",
            dbPath,
            "SELECT service, client, auth_value, last_modified FROM access WHERE service='\(service)';"
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            return parseTCCOutput(output, service: service)
        } catch {
            return PermissionResult(
                service: service,
                status: .unknown,
                error: error.localizedDescription
            )
        }
    }

    /// Pre-flight check before container startup
    /// Verifies TCC authorization and returns error if not authorized
    /// - Returns: nil if authorized, error message if not
    public func preflightCheck() async -> String? {
        let status = await checkHypervisorAuthorization()

        switch status {
        case .authorized:
            return nil // All good
        case .denied:
            return "TCC permission denied for hypervisor. Grant permission in System Preferences > Security & Privacy > Privacy > Developer Tools"
        case .notDetermined:
            return "TCC permission not determined. Run 'tccutil reset All' and retry"
        case .unknown:
            return "Unable to determine TCC status. Check TCC database access"
        }
    }

    /// Requests TCC authorization (triggers system prompt if needed)
    /// Note: This may block waiting for user interaction
    public func requestAuthorization(for service: String) async -> AuthorizationStatus {
        // This would trigger the TCC prompt
        // Implementation depends on service type

        // For hypervisor, we can't directly prompt - user must grant via System Preferences
        // Return current status
        return await queryTCCDatabase(for: service).status
    }

    // MARK: - Private Methods

    private func parseTCCOutput(_ output: String, service: String) -> PermissionResult {
        // Parse sqlite3 output format: service|client|auth_value|last_modified
        let lines = output.split(separator: "\n")

        guard !lines.isEmpty, !output.isEmpty else {
            return PermissionResult(
                service: service,
                status: .notDetermined
            )
        }

        let parts = lines[0].split(separator: "|")
        guard parts.count >= 3 else {
            return PermissionResult(
                service: service,
                status: .unknown,
                error: "Invalid TCC database output format"
            )
        }

        // auth_value: 0=denied, 1=unknown, 2=allowed, 3=limited
        let authValue = Int(parts[2]) ?? 1

        let status: AuthorizationStatus
        switch authValue {
        case 0:
            status = .denied
        case 2:
            status = .authorized
        case 3:
            status = .authorized // limited is still authorized
        default:
            status = .notDetermined
        }

        // Parse last modified date if available
        var lastModified: Date?
        if parts.count >= 4 {
            let timestamp = Double(parts[3]) ?? 0
            if timestamp > 0 {
                lastModified = Date(timeIntervalSince1970: timestamp)
            }
        }

        return PermissionResult(
            service: service,
            status: status,
            lastModified: lastModified
        )
    }
}

// MARK: - Convenience Extensions

public extension TCCChecker {
    /// Quick check if hypervisor is authorized
    func isHypervisorAuthorized() async -> Bool {
        await checkHypervisorAuthorization() == .authorized
    }

    /// Check if TCC prompt would be needed
    func wouldNeedPrompt() async -> Bool {
        await checkHypervisorAuthorization() == .notDetermined
    }
}
