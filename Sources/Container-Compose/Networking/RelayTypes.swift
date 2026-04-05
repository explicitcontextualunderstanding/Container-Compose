import Foundation
import Virtualization

// MARK: - Relay Protocol and Types

/// Transport types for relay connections
/// Used by both relay implementations and YAML configuration
public enum RelayTransport: Hashable, Sendable, Codable {
    case unixSocket(path: String)
    case vsock(cid: UInt32, port: UInt32)
    case tcp(host: String, port: UInt16)
    
    /// Simple transport type for YAML configuration (no associated values)
    public enum TransportType: String, Codable, Hashable {
        case vsock
        case unix
        case tcp
    }
    
    /// Get the simple transport type
    public var transportType: TransportType {
        switch self {
        case .unixSocket: return .unix
        case .vsock: return .vsock
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
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TransportType.self, forKey: .type)
        
        switch type {
        case .unix:
            let path = try container.decode(String.self, forKey: .path)
            self = .unixSocket(path: path)
        case .vsock:
            let cid = try container.decode(UInt32.self, forKey: .cid)
            let port = try container.decode(UInt32.self, forKey: .port)
            self = .vsock(cid: cid, port: port)
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
        case .vsock(let cid, let port):
            try container.encode(cid, forKey: .cid)
            try container.encode(port, forKey: .port)
        case .tcp(let host, let port):
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        }
    }
}

/// Protocol for all relay implementations
protocol RelayProtocol: AnyObject, Sendable {
    var transportType: RelayTransport { get }
    
    func isRunning() async -> Bool
    func activeConnectionCount() async -> Int
    
    func start() async throws
    func stop() async
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
    func verify(cid: UInt32) -> Bool {
        allowedCIDs.contains(cid)
    }

    /// Special CID values per Linux vsock spec
    static let anyCID: UInt32 = 0xFFFFFFFF  // VMADDR_CID_ANY
    static let hypervisorCID: UInt32 = 0    // VMADDR_CID_HYPERVISOR
    static let hostCID: UInt32 = 0x2        // VMADDR_CID_HOST
    static let localCID: UInt32 = 0x1       // VMADDR_CID_LOCAL
}
