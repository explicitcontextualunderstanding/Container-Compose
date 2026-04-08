// Shared Types for Relay Configuration
// Extracted from ContainerComposeCore to enable SecurityHardening module to compile
// Plan 85 - Type dependency resolution

import Foundation

/// Relay transport types supported by the system
public enum RelayTransport: Hashable, Sendable, Codable {
    case tcp(host: String, port: UInt16)
    case unixSocket(path: String)
    case vsock(cid: UInt32, port: UInt32, unixSocketPath: String)
    case vsockDb(socketPath: String)
}

/// Configuration for a socket relay (SecurityHardening compatible)
public struct RelayConfiguration: Sendable {
    public let id: String
    public let tcpPort: UInt16
    public let transport: RelayTransport
    public let description: String
    public let targetPID: pid_t?
    public let unixSocketPath: String

    public init(
        id: String,
        tcpPort: UInt16,
        unixSocketPath: String,
        description: String,
        targetPID: pid_t? = nil
    ) {
        self.id = id
        self.tcpPort = tcpPort
        self.unixSocketPath = unixSocketPath
        self.transport = .unixSocket(path: unixSocketPath)
        self.description = description
        self.targetPID = targetPID
    }

    public init(
        id: String,
        tcpPort: UInt16,
        transport: RelayTransport,
        description: String,
        targetPID: pid_t? = nil
    ) {
        self.id = id
        self.tcpPort = tcpPort
        self.transport = transport
        self.description = description
        self.targetPID = targetPID
        self.unixSocketPath = Self.extractUnixPath(from: transport)
    }

    private static func extractUnixPath(from transport: RelayTransport) -> String {
        switch transport {
        case .unixSocket(let path):
            return path
        case .vsock(_, _, let path):
            return path
        case .vsockDb(let socketPath):
            return socketPath
        case .tcp, .vsock:
            return ""
        }
    }
}

/// Relay type enumeration
public enum RelayType: Sendable, Codable, Hashable {
    case tcp
    case unixSocket
    case vsock
    case vsockDb

    public var description: String {
        switch self {
        case .tcp: return "tcp"
        case .unixSocket: return "unixSocket"
        case .vsock: return "vsock"
        case .vsockDb: return "vsockDb"
        }
    }
}

public extension RelayConfiguration {
    var type: RelayType {
        switch transport {
        case .tcp:
            return .tcp
        case .unixSocket:
            return .unixSocket
        case .vsock:
            return .vsock
        case .vsockDb:
            return .vsockDb
        }
    }
}
