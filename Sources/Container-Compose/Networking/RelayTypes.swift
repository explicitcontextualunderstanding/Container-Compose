import Foundation
import Virtualization

// MARK: - Relay Protocol and Types

/// Transport types for relay connections
/// Used by both relay implementations and YAML configuration
public enum RelayTransport: Hashable, Sendable, Codable {
    case unixSocket(path: String)
    case uds(path: String, virtioFSMount: String? = nil)
    case vsock(cid: UInt32, port: UInt32, unixSocketPath: String = "")
    case vsockDb(socketPath: String)
    case tcp(host: String, port: UInt16)

    /// Human-readable description
    public var description: String {
        switch self {
        case .unixSocket(let path): return "unix:\(path)"
        case .uds(let path, _): return "uds:\(path)"
        case .vsock(let cid, let port, let unixSocketPath):
            if unixSocketPath.isEmpty {
                return "vsock:\(cid):\(port)"
            }
            return "vsock:\(cid):\(port):\(unixSocketPath)"
        case .vsockDb(let socketPath): return "vsock-db:\(socketPath)"
        case .tcp(let host, let port): return "tcp:\(host):\(port)"
        }
    }

    /// Simple transport type for YAML configuration (no associated values)
    public enum TransportType: String, Codable, Hashable {
        case uds
        case vsock
        case vsockDb
        case unix
        case tcp
    }

    /// Get the simple transport type
    public var transportType: TransportType {
        switch self {
        case .unixSocket: return .unix
        case .uds: return .uds
        case .vsock: return .vsock
        case .vsockDb: return .vsockDb
        case .tcp: return .tcp
        }
    }

    /// Coding keys for Codable conformance
    enum CodingKeys: String, CodingKey {
        case type
        case path
        case cid
        case port
        case host
        case unixSocketPath
        case socketPath
        case virtioFSMount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TransportType.self, forKey: .type)

        switch type {
        case .unix:
            let path = try container.decode(String.self, forKey: .path)
            self = .unixSocket(path: path)
        case .uds:
            let path = try container.decode(String.self, forKey: .path)
            let mount = try container.decodeIfPresent(String.self, forKey: .virtioFSMount)
            self = .uds(path: path, virtioFSMount: mount)
        case .vsock:
            let cid = try container.decode(UInt32.self, forKey: .cid)
            let port = try container.decode(UInt32.self, forKey: .port)
            let unixSocketPath = try container.decodeIfPresent(String.self, forKey: .unixSocketPath) ?? ""
            self = .vsock(cid: cid, port: port, unixSocketPath: unixSocketPath)
        case .vsockDb:
            let socketPath = try container.decode(String.self, forKey: .socketPath)
            self = .vsockDb(socketPath: socketPath)
        case .tcp:
            let host = try container.decode(String.self, forKey: .host)
            let port = try container.decode(UInt16.self, forKey: .port)
            self = .tcp(host: host, port: port)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transportType, forKey: .type)

        switch self {
        case .unixSocket(let path):
            try container.encode(path, forKey: .path)
        case .uds(let path, let mount):
            try container.encode(path, forKey: .path)
            try? container.encodeIfPresent(mount, forKey: .virtioFSMount)
        case .vsock(let cid, let port, let unixSocketPath):
            try container.encode(cid, forKey: .cid)
            try container.encode(port, forKey: .port)
            if !unixSocketPath.isEmpty {
                try container.encode(unixSocketPath, forKey: .unixSocketPath)
            }
        case .vsockDb(let socketPath):
            try container.encode(socketPath, forKey: .socketPath)
        case .tcp(let host, let port):
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        }
    }
}

/// Protocol for all relay implementations
public protocol RelayProtocol: Actor {
    var transportType: RelayTransport { get }
    
    /// TCP port the relay listens on
    var tcpPort: UInt16 { get }
    
    /// Unix socket path (empty for vsock relays)
    var unixSocketPath: String { get }

    var isRunning: Bool { get }
    var activeConnectionCount: Int { get }

    func start() async throws
    func stop() async
}

// MARK: - UDS Types

/// Errors specific to UDS-over-Virtio-FS operations
enum UDSError: Error, CustomStringConvertible {
    case socketPathTooLong(path: String, length: Int, limit: Int)
    case virtioFSNotAvailable
    case socketBindingFailed(String)
    case connectionFailed(String)

    var description: String {
        switch self {
        case .socketPathTooLong(let path, let length, let limit):
            return "Socket path too long: \(length) chars (limit: \(limit)). Path: \(path). Shorten the project or volume name."
        case .virtioFSNotAvailable:
            return "Virtio-FS mount not available: ~/.containers/Volumes not found"
        case .socketBindingFailed(let reason):
            return "Failed to bind UDS socket: \(reason)"
        case .connectionFailed(let reason):
            return "UDS connection failed: \(reason)"
        }
    }
}

// MARK: - Vsock Types

/// Represents a vsock address
struct VsockAddress: Hashable, Sendable {
    let contextID: UInt32
    let port: UInt32

    var description: String { "vsock:\(contextID):\(port)" }
}

/// Errors specific to vsock operations
enum VsockError: Error, CustomStringConvertible {
    case invalidContextID(UInt32)
    case invalidPort(UInt32)
    case deviceUnavailable(String)
    case connectionRejected(cid: UInt32, reason: String)
    case virtualizationFrameworkUnavailable

    var description: String {
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

// MARK: - CID Verification

/// Verifies CID-based connections for security
struct CIDVerifier: Sendable {
    /// Allowed CIDs - only connections from these CIDs are accepted
    private let allowedCIDs: Set<UInt32>

    init(allowedCIDs: [UInt32]) {
        self.allowedCIDs = Set(allowedCIDs)
    }

  /// Verify if a CID is authorized
  /// - Empty allowedCIDs allows all CIDs (permissive mode)
  /// - If anyCID (0xFFFFFFFF) is in allowedCIDs, allows all CIDs
  func verify(cid: UInt32) -> Bool {
    // Empty set means allow all (permissive mode)
    if allowedCIDs.isEmpty { return true }
    // If anyCID is in the set, allow all CIDs
    if allowedCIDs.contains(CIDVerifier.anyCID) { return true }
    // Otherwise, check if cid is in allowed set
    return allowedCIDs.contains(cid)
  }

    /// Special CID values per Linux vsock spec
    static let anyCID: UInt32 = 0xFFFFFFFF  // VMADDR_CID_ANY
    static let hypervisorCID: UInt32 = 0    // VMADDR_CID_HYPERVISOR
    static let hostCID: UInt32 = 0x2        // VMADDR_CID_HOST
    static let localCID: UInt32 = 0x1       // VMADDR_CID_LOCAL
}
