//===----------------------------------------------------------------------===//
// RelayTypes.swift
// Type re-exports for relay configuration
//
// Plan 88 Finding C-1: Use typealias re-export from SecurityHardening
// instead of duplicating the RelayTransport enum
//===----------------------------------------------------------------------===//

import Foundation
import SecurityHardening

// MARK: - Typealias Re-exports

/// Transport types for relay connections (re-export from SecurityHardening)
/// Used by both relay implementations and YAML configuration
///
/// Per Plan 88 Finding C-1: This is a typealias to SecurityHardening.RelayTransport
/// to avoid type duplication and circular dependencies.
public typealias RelayTransport = SecurityHardening.RelayTransport

/// Configuration for socket relays (re-export from SecurityHardening)
public typealias RelayConfiguration = SecurityHardening.RelayConfiguration

/// Relay type enumeration (re-export from SecurityHardening)
public typealias RelayType = SecurityHardening.RelayType

// MARK: - Relay Protocol

/// Protocol for relay implementations (SocketRelay, UDSVirtioFSRelay, etc.)
public protocol RelayProtocol: Actor {
    /// The transport type for this relay
    var transportType: RelayTransport { get }

    /// Whether the relay is currently running
    var isRunning: Bool { get }

    /// Number of active connections
    var activeConnectionCount: Int { get }

    /// Path to the Unix socket
    var unixSocketPath: String { get }

    /// TCP port (0 for UDS relays)
    var tcpPort: UInt16 { get }

    /// Start the relay
    func start() async throws

    /// Stop the relay
    func stop() async
}

// MARK: - UDS Types

/// Errors specific to UDS-over-Virtio-FS operations
public enum UDSError: Error, CustomStringConvertible {
    case socketPathTooLong(path: String, length: Int, limit: Int)
    case virtioFSNotAvailable
    case socketBindingFailed(String)
    case connectionFailed(String)
    // Plan 88: Additional error cases for UDSVirtioFSRelay
    case socketCreationFailed(errno: Int32, message: String)
    case socketBindFailed(errno: Int32, message: String)
    case socketListenFailed(errno: Int32, message: String)
    case socketTimeout(path: String)

    public var description: String {
        switch self {
        case .socketPathTooLong(let path, let length, let limit):
            return "Socket path too long: \(length) chars (limit: \(limit)). Path: \(path). Shorten the project or volume name."
        case .virtioFSNotAvailable:
            return "Virtio-FS mount not available: ~/.containers/Volumes not found"
        case .socketBindingFailed(let reason):
            return "Failed to bind UDS socket: \(reason)"
        case .connectionFailed(let reason):
            return "UDS connection failed: \(reason)"
        case .socketCreationFailed(let errno, let message):
            return "Socket creation failed: \(message) (errno: \(errno))"
        case .socketBindFailed(let errno, let message):
            return "Socket bind failed: \(message) (errno: \(errno))"
        case .socketListenFailed(let errno, let message):
            return "Socket listen failed: \(message) (errno: \(errno))"
        case .socketTimeout(let path):
            return "Timeout waiting for socket at: \(path)"
        }
    }
}

// MARK: - Vsock Types (Deprecated)

/// Represents a vsock address
/// @available(*, deprecated, message: "Use UDS over Virtio-FS — vSock blocked by Apple")
public struct VsockAddress: Hashable, Sendable {
    public let contextID: UInt32
    public let port: UInt32

    public var description: String { "vsock:\(contextID):\(port)" }
}

/// Errors specific to vsock operations
/// @available(*, deprecated, message: "Use UDS over Virtio-FS — vSock blocked by Apple")
public enum VsockError: Error, CustomStringConvertible {
    case invalidContextID(UInt32)
    case invalidPort(UInt32)
    case deviceUnavailable(String)
    case connectionRejected(cid: UInt32, reason: String)
    case virtualizationFrameworkUnavailable

    public var description: String {
        switch self {
        case .invalidContextID(let cid):
            return "Invalid vsock context ID: \(cid)"
        case .invalidPort(let port):
            return "Invalid vsock port: \(port)"
        case .deviceUnavailable(let reason):
            return "Vsock device unavailable: \(reason)"
        case .connectionRejected(let cid, let reason):
            return "Connection from CID \(cid) rejected: \(reason)"
        case .virtualizationFrameworkUnavailable:
            return "Virtualization.framework unavailable (requires macOS 12+)"
        }
    }
}

// MARK: - CID Verification (Deprecated)

/// Verifies CID-based connections for security
/// @available(*, deprecated, message: "Use PeerValidator with SO_PEERCRED — CID unavailable over UDS")
public struct CIDVerifier: Sendable {
    /// Allowed CIDs - only connections from these CIDs are accepted
    private let allowedCIDs: Set<UInt32>

    public init(allowedCIDs: [UInt32]) {
        self.allowedCIDs = Set(allowedCIDs)
    }

    /// Verify if a CID is authorized
    /// - Empty allowedCIDs allows all CIDs (permissive mode)
    /// - If anyCID (0xFFFFFFFF) is in allowedCIDs, allows all CIDs
    public func verify(cid: UInt32) -> Bool {
        // Empty set means allow all (permissive mode)
        if allowedCIDs.isEmpty { return true }
        // If anyCID is in the set, allow all CIDs
        if allowedCIDs.contains(CIDVerifier.anyCID) { return true }
        // Otherwise, check if cid is in allowed set
        return allowedCIDs.contains(cid)
    }

    /// Special CID values per Linux vsock spec
    public static let anyCID: UInt32 = 0xFFFFFFFF // VMADDR_CID_ANY
    public static let hypervisorCID: UInt32 = 0 // VMADDR_CID_HYPERVISOR
    public static let hostCID: UInt32 = 0x2 // VMADDR_CID_HOST
    public static let localCID: UInt32 = 0x1 // VMADDR_CID_LOCAL
}
