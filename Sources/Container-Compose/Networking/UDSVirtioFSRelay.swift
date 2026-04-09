import Foundation
import Darwin
import os.log

// MARK: - UDS-over-Virtio-FS Relay

/// UDS relay for Apple Container IPC via Virtio-FS shared volumes (Plan 88)
/// Replaces VsockRelay — uses AF_UNIX sockets shared via Virtio-FS mounts.
/// No CID dependency; peer identity via SO_PEERCRED (A-1 resolved).
public final actor UDSVirtioFSRelay: RelayProtocol {
    public let transportType: RelayTransport
    public var isRunning: Bool { isRunningValue }
    public var activeConnectionCount: Int { activeConnectionCountValue }
    public var unixSocketPath: String { socketPath }
    public var tcpPort: UInt16 { 0 }

    private var isRunningValue = false
    private var activeConnectionCountValue = 0
    private let socketPath: String
    private let createSignalSocket: Bool
    private let eventLog: RelayEventLog
    private let peerValidator: PeerValidator
    private let logger: Logger
    private let virtioFSMount: String?
    private var listenSocket: Int32 = -1
    private var activeConnections: Set<UDSConnection> = []
    private var acceptTask: Task<Void, Error>?

    /// AF_UNIX path length limit
    private static let sunPathMax = 104

    /// Creates a new UDS-over-Virtio-FS relay.
    /// - Parameters:
    ///   - socketPath: Path to the Unix domain socket
    ///   - virtioFSMountPath: Optional Virtio-FS mount path (for detection)
    ///   - expectedPeerUID: Optional UID to validate connecting peers (A-1: SO_PEERCRED)
    ///   - createSignalSocket: If true, creates the signal socket. Set false for DB sockets (Decision 6)
    ///   - eventLog: Event logging actor
    init(
        socketPath: String,
        virtioFSMountPath: String? = nil,
        expectedPeerUID: UInt32? = nil,
        createSignalSocket: Bool = true,
        eventLog: RelayEventLog
    ) throws {
        // Plan 88 Decision 5: Hard-error on paths >= 104 chars
        guard socketPath.count < Self.sunPathMax else {
            throw UDSError.socketPathTooLong(
                path: socketPath,
                length: socketPath.count,
                limit: Self.sunPathMax
            )
        }

        self.socketPath = socketPath
        self.virtioFSMount = virtioFSMountPath ?? Self.detectVirtioFSMount()
        self.createSignalSocket = createSignalSocket
        self.eventLog = eventLog
        self.peerValidator = PeerValidator(expectedUID: expectedPeerUID)
        self.transportType = .uds(path: socketPath, virtioFSMount: self.virtioFSMount)
        self.logger = Logger(subsystem: "com.container-compose.relay", category: "UDSVirtioFS-\(socketPath.suffix(30))")

        logger.info("Initialized UDS relay: path=\(socketPath), createSignalSocket=\(createSignalSocket)")
    }

    /// Start listening for UDS connections
    public func start() async throws {
        guard !isRunningValue else {
            throw RelayError.alreadyRunning("uds-\(socketPath)")
        }

        if createSignalSocket {
            try createUnixSocketListener()
        } else {
            // Wait for external socket (e.g., PostgreSQL in Virtio-FS volume)
            logger.info("Waiting for external socket at \(self.socketPath)")
            let startTime = Date()
            while Date().timeIntervalSince(startTime) < 60 {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: socketPath, isDirectory: &isDir) {
                    var statBuf = stat()
                    if stat(socketPath, &statBuf) == 0 && (statBuf.st_mode & S_IFMT) == S_IFSOCK {
                        logger.info("External socket found at \(self.socketPath)")
                        break
                    }
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // Create listening socket for accepting connections
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw UDSError.socketBindingFailed("Failed to create socket: \(errno)")
        }

        var opt: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cString in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                strncpy(ptr, cString, Int(Self.sunPathMax) - 1)
            }
        }

        // Unlink stale socket
        Darwin.unlink(socketPath)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            Darwin.close(sock)
            throw UDSError.socketBindingFailed("bind failed: \(errno)")
        }

        guard Darwin.listen(sock, 10) == 0 else {
            Darwin.close(sock)
            throw UDSError.socketBindingFailed("listen failed: \(errno)")
        }

        // Set permissions for shared access
        Darwin.chmod(socketPath, 0o777)

        self.listenSocket = sock
        self.isRunningValue = true

        logger.info("UDS relay started: path=\(self.socketPath)")

        await eventLog.record(.relayStarted(
            id: "uds-\(socketPath.suffix(20))",
            port: 0,
            path: socketPath
        ))

        acceptTask = Task {
            try await acceptLoop()
        }
    }

    /// Stop the relay and clean up resources
    public func stop() async {
        guard isRunningValue else { return }

        logger.info("Stopping UDS relay at \(self.socketPath)")

        acceptTask?.cancel()
        acceptTask = nil

        if listenSocket >= 0 {
            Darwin.close(listenSocket)
            listenSocket = -1
        }

        for connection in activeConnections {
            await connection.close()
        }
        activeConnections.removeAll()
        activeConnectionCountValue = 0

        isRunningValue = false

        await eventLog.record(.relayStopped(id: "uds-\(socketPath.suffix(20))"))
        logger.info("UDS relay stopped")
    }

    // MARK: - Private

    /// Creates the Unix socket listener (signal socket for orchestrator)
    private func createUnixSocketListener() throws {
        let parentDir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        Darwin.unlink(socketPath)

        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw UDSError.socketBindingFailed("Failed to create signal socket: \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cString in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                strncpy(ptr, cString, Int(Self.sunPathMax) - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            Darwin.close(sock)
            throw UDSError.socketBindingFailed("Failed to bind signal socket at \(socketPath): \(errno)")
        }

        Darwin.chmod(socketPath, 0o777)
        Darwin.close(sock)

        logger.info("Signal socket created at \(self.socketPath)")
    }

    /// Accept loop for incoming UDS connections
    private func acceptLoop() async throws {
        while !Task.isCancelled {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSock = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    withUnsafeMutablePointer(to: &len) { lenPtr in
                        accept(listenSocket, sockaddrPtr, lenPtr)
                    }
                }
            }

            guard clientSock >= 0 else {
                if errno == EINTR || errno == EAGAIN {
                    try await Task.sleep(nanoseconds: 1_000_000)
                    continue
                }
                throw UDSError.connectionFailed("Accept failed: \(errno)")
            }

            // A-1: Validate peer via SO_PEERCRED
            let validation = await peerValidator.validatePeer(socket_fd: clientSock)
            if case .failed(let reason) = validation {
                logger.warning("Rejected UDS connection: \(reason)")
                Darwin.close(clientSock)
                continue
            }

            let connection = UDSConnection(
                socket: clientSock,
                socketPath: socketPath,
                relayId: "uds-\(socketPath.suffix(20))",
                eventLog: eventLog
            )

            activeConnections.insert(connection)
            activeConnectionCountValue = activeConnections.count

            await eventLog.record(.connectionEstablished(
                relayId: "uds-\(socketPath.suffix(20))",
                connectionId: connection.id
            ))

            Task {
                await connection.start { [weak self] in
                    guard let self = self else { return }
                    Task {
                        await self.removeConnection(connection)
                    }
                }
            }
        }
    }

    private func removeConnection(_ connection: UDSConnection) async {
        activeConnections.remove(connection)
        activeConnectionCountValue = activeConnections.count

        await eventLog.record(.connectionClosed(
            relayId: "uds-\(socketPath.suffix(20))",
            connectionId: connection.id
        ))
    }

    /// Detect Virtio-FS mount availability
    private static func detectVirtioFSMount() -> String? {
        if FileManager.default.fileExists(atPath: "/run/virtiofs/ipc_enabled") {
            return "/run/virtiofs"
        }
        let volumesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".containers/Volumes")
        if FileManager.default.fileExists(atPath: volumesDir.path) {
            return volumesDir.path
        }
        return nil
    }
}

// MARK: - Peer Validator (A-1: SO_PEERCRED, no CID)

/// Validates peer identity via kernel-provided SO_PEERCRED credentials.
/// TCC already gates the Virtio-FS mount — this is defense-in-depth.
public actor PeerValidator {
    private let expectedUID: uid_t?

    init(expectedUID: uid_t? = nil) {
        self.expectedUID = expectedUID
    }

    /// Validate peer credentials on an accepted connection
    func validatePeer(socket_fd: Int32) -> PeerValidationResult {
        var uid = UInt32(0)
        var gid = UInt32(0)
        var pid = Int32(0)
        var credLen = socklen_t(MemoryLayout<(UInt32, UInt32, Int32)>.size)
        withUnsafeMutablePointer(to: &uid) { uidPtr in
            withUnsafeMutablePointer(to: &gid) { gidPtr in
                withUnsafeMutablePointer(to: &pid) { pidPtr in
                    let result = getsockopt(socket_fd, SOL_LOCAL, LOCAL_PEERCRED, uidPtr, &credLen)
                    guard result == 0 else {
                        return .failed("Cannot read peer credentials: \(errno)")
                    }
                }
            }
        }
        if let expected = expectedUID, uid != expected {
            return .failed("UID mismatch: expected \(expected), got \(uid)")
        }
        return .passed(peerUID: uid, peerGID: gid, peerPID: pid)
    }
}

/// Result of peer validation
public enum PeerValidationResult: Sendable {
    case passed(peerUID: UInt32, peerGID: UInt32, peerPID: Int32)
    case failed(String)
}

// MARK: - UDS Connection

/// Represents an active UDS connection
private final actor UDSConnection: Hashable {
    let id: UUID
    private let socket: Int32
    private let socketPath: String
    private let relayId: String
    private let eventLog: RelayEventLog

    init(socket: Int32, socketPath: String, relayId: String, eventLog: RelayEventLog) {
        self.id = UUID()
        self.socket = socket
        self.socketPath = socketPath
        self.relayId = relayId
        self.eventLog = eventLog
    }

    func start(completion: @escaping @Sendable () -> Void) async {
        // Simple keep-alive — the real bridging happens in VsockConnection
        // For UDS-over-Virtio-FS, the socket is the communication channel
        defer {
            Darwin.close(socket)
            completion()
        }

        // Wait for connection to close or task cancellation
        while !Task.isCancelled {
            var buffer = [UInt8](repeating: 0, count: 1)
            let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr in
                read(socket, ptr.baseAddress!, 1)
            }
            if bytesRead <= 0 {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func close() async {
        Darwin.close(socket)
    }

    nonisolated static func == (lhs: UDSConnection, rhs: UDSConnection) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
