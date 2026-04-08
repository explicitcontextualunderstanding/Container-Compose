// EntitlementManifest.swift
// Component 1: Entitlement Manifest Design
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import Foundation

/// Represents strict vSock port entitlements per SECURITY_CONTAINER.md requirements
/// No wildcards allowed - exact port IDs only to minimize blast radius
public struct EntitlementManifest: Codable, Sendable {
    /// Hypervisor entitlement required for all vSock operations
    public let hypervisor: Bool

    /// Explicit vSock port entitlements (strict scoping - no wildcards)
    /// Maps port number to entitlement status
    public let vsockPorts: [UInt32: Bool]

    /// Creates an entitlement manifest with exact port specifications
    /// - Parameters:
    ///   - hypervisor: Whether hypervisor entitlement is granted
    ///   - vsockPorts: Dictionary of port -> entitlement status (only true values stored)
    public init(hypervisor: Bool, vsockPorts: [UInt32: Bool]) {
        self.hypervisor = hypervisor
        // Filter to only include explicitly granted ports
        self.vsockPorts = vsockPorts.filter { $0.value }
    }

    /// Default manifest with standard Honcho ports (5432, 8000)
    public static func standard() -> EntitlementManifest {
        EntitlementManifest(
            hypervisor: true,
            vsockPorts: [
                5432: true, // Database relay
                8000: true  // Hub API relay
            ]
        )
    }

    /// Checks if a specific port is entitled
    public func isPortEntitled(_ port: UInt32) -> Bool {
        guard hypervisor else { return false }
        return vsockPorts[port] ?? false
    }

    /// Returns list of all entitled ports
    public var entitledPorts: [UInt32] {
        Array(vsockPorts.keys).sorted()
    }
}

/// Errors that can occur during entitlement validation
public enum EntitlementError: Error, Sendable, Equatable {
    case hypervisorNotEntitled
    case portNotEntitled(port: UInt32)
    case wildcardNotAllowed
    case invalidPortRange(port: UInt32)
}

/// Validator for entitlement manifests
public struct EntitlementValidator: Sendable {
    public init() {}

    /// Validates that no wildcards are present (strict scoping)
    /// Throws EntitlementError.wildcardNotAllowed if wildcard detected
    public func validateNoWildcards(_ manifest: EntitlementManifest) throws {
        // Wildcard would be represented as port 0 or nil key
        if manifest.vsockPorts.keys.contains(0) {
            throw EntitlementError.wildcardNotAllowed
        }
    }

    /// Validates a specific port request against manifest
    public func validatePort(_ port: UInt32, against manifest: EntitlementManifest) throws {
        guard manifest.hypervisor else {
            throw EntitlementError.hypervisorNotEntitled
        }
        guard manifest.isPortEntitled(port) else {
            throw EntitlementError.portNotEntitled(port: port)
        }
        // Valid port range check (vsock ports are 32-bit unsigned)
        guard port > 0 && port <= UInt32.max else {
            throw EntitlementError.invalidPortRange(port: port)
        }
    }
}

// MARK: - Info.plist Integration

/// Helper for reading entitlements from Info.plist
public struct InfoPlistEntitlements: Sendable {
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Reads entitlements from the app's Info.plist
    /// Expected format:
    /// ```xml
    /// <key>com.apple.security.hypervisor</key>
    /// <true/>
    /// <key>com.apple.security.vsock.port.5432</key>
    /// <true/>
    /// ```
    public func readEntitlements() -> EntitlementManifest {
        let hypervisor = bundle.object(forInfoDictionaryKey: "com.apple.security.hypervisor") as? Bool ?? false

        // Scan for vsock port entitlements in standard format
        var ports: [UInt32: Bool] = [:]
        let infoDict = bundle.infoDictionary ?? [:]

        for (key, value) in infoDict {
            if key.hasPrefix("com.apple.security.vsock.port."),
               let portStr = key.split(separator: ".").last,
               let port = UInt32(portStr),
               let enabled = value as? Bool {
                ports[port] = enabled
            }
        }

        return EntitlementManifest(hypervisor: hypervisor, vsockPorts: ports)
    }

    /// Generates Info.plist XML snippet for entitlements
    public func generatePlistXML(for manifest: EntitlementManifest) -> String {
        var lines = ["<key>com.apple.security.hypervisor</key>"]
        lines.append(manifest.hypervisor ? "<true/>" : "<false/>")

        for port in manifest.entitledPorts {
            lines.append("<key>com.apple.security.vsock.port.\(port)</key>")
            lines.append("<true/>")
        }

        return lines.joined(separator: "\n")
    }
}
