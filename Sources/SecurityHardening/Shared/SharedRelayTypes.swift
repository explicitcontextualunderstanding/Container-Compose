// Shared Types for Relay Configuration
// Extracted from ContainerComposeCore to enable SecurityHardening module to compile
// Plan 85 - Type dependency resolution

import Foundation

/// Relay transport types supported by the system
public enum RelayTransport: Hashable, Sendable, Codable {
    case tcp(host: String, port: UInt16)
    case unixSocket(path: String)
    case uds(path: String, virtioFSMount: String? = nil)
    @available(*, deprecated, message: "Use .uds(path:) — vSock blocked by Apple")
    case vsock(cid: UInt32, port: UInt32, unixSocketPath: String)
    @available(*, deprecated, message: "Use .uds(path:) — vSock blocked by Apple")
    case vsockDb(socketPath: String)

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
        case .uds(let path, _):
            return path
        case .vsock(_, _, let path):
            return path
        case .vsockDb(let socketPath):
            return socketPath
        case .tcp:
            return ""
        }
    }
}

/// Relay type enumeration
public enum RelayType: Sendable, Codable, Hashable {
    case tcp
    case unixSocket
    case uds
    @available(*, deprecated, message: "Use .uds — vSock blocked by Apple")
    case vsock
    @available(*, deprecated, message: "Use .uds — vSock blocked by Apple")
    case vsockDb

    public var description: String {
        switch self {
        case .tcp: return "tcp"
        case .unixSocket: return "unixSocket"
        case .uds: return "uds"
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
        case .uds:
            return .uds
        case .vsock:
            return .vsock
        case .vsockDb:
            return .vsockDb
        }
    }
    
    var typeString: String {
        type.description
    }
}
