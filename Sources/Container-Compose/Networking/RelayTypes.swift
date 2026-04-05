import Foundation
import Virtualization

// MARK: - Relay Protocol and Types

/// Transport types for relay connections
enum RelayTransport: Hashable, Sendable {
    case unixSocket(path: String)
    case vsock(cid: UInt32, port: UInt32)
    case tcp(host: String, port: UInt16)
}

/// Protocol for all relay implementations
protocol RelayProtocol: AnyObject, Sendable {
    var transportType: RelayTransport { get }
    var isRunning: Bool { get }
    var activeConnectionCount: Int { get }

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
