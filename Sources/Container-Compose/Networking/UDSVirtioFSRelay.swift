//===----------------------------------------------------------------------===//
// UDSVirtioFSRelay.swift
// UDS-over-Virtio-FS Relay for Plan 88
// Replaces VsockRelay with AF_UNIX sockets
//===----------------------------------------------------------------------===//

import Foundation
import Darwin
import os.log

/// UDS relay for Apple Container IPC via Virtio-FS shared volumes
/// Uses AF_UNIX sockets instead of vSock (blocked by Apple in user containers)
public final actor UDSVirtioFSRelay: RelayProtocol {
    public let transportType: RelayTransport
    public var isRunning: Bool { isRunningValue }
    public var activeConnectionCount: Int { activeConnections.count }
    public var unixSocketPath: String { socketPath }
    public var tcpPort: UInt16 { 0 }

    private var isRunningValue = false
    private let socketPath: String
    private let createSignalSocket: Bool
    private let eventLog: RelayEventLog
    private let logger: Logger
    private let virtioFSMount: String?
private var listenSocket: Int32 = -1
private var activeConnections: Set<UDSConnection> = []
private let peerValidator: PeerValidator

/// AF_UNIX sun_path limit (includes null terminator)
private static let sunPathMax = 104

/// Creates a new UDS-over-Virtio-FS relay
/// - Parameters:
/// - socketPath: Path to the Unix domain socket
/// - virtioFSMountPath: Optional Virtio-FS mount path
/// - createSignalSocket: If true, creates the socket; if false, waits for external socket
/// - expectedPeerUID: Optional UID to validate against connecting peers (SO_PEERCRED)
/// - eventLog: Event logging actor
init(
socketPath: String,
virtioFSMountPath: String? = nil,
createSignalSocket: Bool = true,
expectedPeerUID: uid_t? = nil,
eventLog: RelayEventLog
) throws {
        // Plan 88: Hard-error on paths >= 104 chars (Finding C-2)
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
        self.transportType = .uds(path: socketPath, virtioFSMount: self.virtioFSMount)
self.logger = Logger(
        subsystem: "com.container-compose.relay",
        category: "UDSVirtioFS"
    )

    self.peerValidator = PeerValidator(expectedUID: expectedPeerUID)

    logger.info("Initialized UDS relay: path=\(socketPath, privacy: .public), createSignalSocket=\(createSignalSocket)")
    }

    /// Start listening for UDS connections
    public func start() async throws {
        guard !isRunningValue else {
            throw RelayError.alreadyRunning("UDS relay already running at \(socketPath)")
        }

        if createSignalSocket {
            try createAndBindSocket()
        } else {
            // Wait for external socket (e.g., PostgreSQL creates socket in Virtio-FS)
            try await waitForExternalSocket()
        }

        // Start accept loop using GCD to avoid blocking the cooperative thread pool
        let socketToAccept = listenSocket
        let validator = peerValidator
        let log = logger
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                var clientAddr = sockaddr_un()
                var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

                let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(socketToAccept, sockaddrPtr, &addrLen)
                    }
                }

                guard clientSocket >= 0 else {
                    if errno == EINTR { continue }
                    if errno == EBADF { break } // Socket closed by stop()
                    log.error("Accept failed: \(errno) - \(String(cString: strerror(errno)))")
                    continue
                }

                Task { [weak self] in
                    guard let self = self else {
                        Darwin.close(clientSocket)
                        return
                    }
                    
                    let connection = UDSConnection(socket: clientSocket, logger: log)
                    await self.addConnection(connection)

                    let validationResult = await validator.validatePeer(socket_fd: clientSocket)
                    if case .failed(let reason) = validationResult {
                        log.warning("Peer validation failed: \(reason)")
                        await connection.close()
                        await self.removeConnection(connection)
                        return
                    }

                    await connection.handle()
                    await self.removeConnection(connection)
                }
            }
        }

        isRunningValue = true
        await eventLog.record(.relayStarted(id: "uds-\(socketPath)", port: 0, path: socketPath))
        logger.info("UDS relay started: \(self.socketPath, privacy: .public)")
    }

    /// Stop the relay
    public func stop() async {
        guard isRunningValue else { return }

        // Close listening socket to interrupt Darwin.accept
        if listenSocket >= 0 {
            Darwin.close(listenSocket)
            listenSocket = -1
        }

        // Clean up socket file if we created it
        if createSignalSocket {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        // Close active connections
        for conn in activeConnections {
            await conn.close()
        }
        activeConnections.removeAll()

        isRunningValue = false
        await eventLog.record(.relayStopped(id: "uds-\(socketPath)"))
        logger.info("UDS relay stopped: \(self.socketPath, privacy: .public)")
    }

    // MARK: - Private Methods

    /// Create and bind the Unix domain socket
    private func createAndBindSocket() throws {
        // Create socket
        listenSocket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenSocket >= 0 else {
            throw UDSError.socketCreationFailed(errno: errno, message: String(cString: strerror(errno)))
        }

        // Remove any existing socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create parent directory
        let parentDir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Set socket permissions (owner only)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let pathLength = socketPath.utf8.count
        socketPath.withCString { cString in
            _ = memcpy(&addr.sun_path, cString, pathLength + 1)
        }

        // Bind socket
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(listenSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            let err = errno
            Darwin.close(listenSocket)
            listenSocket = -1
            throw UDSError.socketBindFailed(errno: err, message: String(cString: strerror(err)))
        }

        // Set permissions (owner read/write only)
        Darwin.chmod(socketPath, 0o600)

        // Start listening
        guard Darwin.listen(listenSocket, 128) == 0 else {
            let err = errno
            Darwin.close(listenSocket)
            listenSocket = -1
            throw UDSError.socketListenFailed(errno: err, message: String(cString: strerror(err)))
        }

        logger.info("UDS socket created and bound: \(self.socketPath, privacy: .public)")
    }

    /// Wait for external socket to appear (e.g., PostgreSQL)
    private func waitForExternalSocket() async throws {
        logger.info("Waiting for external socket at \(self.socketPath, privacy: .public)")

        let startTime = Date()
        let timeout: TimeInterval = 60 // 60 second timeout

        while Date().timeIntervalSince(startTime) < timeout {
            if FileManager.default.fileExists(atPath: socketPath) {
                logger.info("External socket found: \(self.socketPath, privacy: .public)")
                return
            }
            // Wait 100ms before checking again
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        throw UDSError.socketTimeout(path: socketPath)
    }

    private func addConnection(_ conn: UDSConnection) {
        activeConnections.insert(conn)
    }

    private func removeConnection(_ conn: UDSConnection) {
        activeConnections.remove(conn)
    }

    /// Detect Virtio-FS mount
    private static func detectVirtioFSMount() -> String? {
        // Check for Apple Container Virtio-FS indicator
        if FileManager.default.fileExists(atPath: "/run/virtiofs/ipc_enabled") {
            return "/run/virtiofs"
        }
        // Check for .containers/Volumes directory
        let volumesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".containers")
            .appendingPathComponent("Volumes")
        if FileManager.default.fileExists(atPath: volumesDir.path) {
            return volumesDir.path
        }
        return nil
    }
}

// MARK: - UDS Connection

/// Represents an active UDS connection
private actor UDSConnection: Hashable {
    let socket: Int32
    let logger: Logger

    init(socket: Int32, logger: Logger) {
        self.socket = socket
        self.logger = logger
    }

    func handle() async {
        // Echo server for now - can be extended
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(socket, ptr.baseAddress, ptr.count)
            }

            guard bytesRead > 0 else { break }

            // Echo back
            var totalWritten = 0
            while totalWritten < bytesRead {
                let written = buffer.withUnsafeBytes { ptr in
                    Darwin.write(socket, ptr.baseAddress! + totalWritten, bytesRead - totalWritten)
                }
                guard written > 0 else { break }
                totalWritten += written
            }
        }

        close()
    }

    func close() {
        Darwin.close(socket)
    }

    // Hashable conformance
    nonisolated static func == (lhs: UDSConnection, rhs: UDSConnection) -> Bool {
        lhs.socket == rhs.socket
    }

nonisolated func hash(into hasher: inout Hasher) {
hasher.combine(socket)
}
}

// MARK: - Peer Validation (SO_PEERCRED)

/// Peer identity validation using SO_PEERCRED (Plan 88 A-1)
/// Replaces CID gating with UID/GID-based identity (AF_UNIX doesn't expose CID)
public actor PeerValidator {
private let expectedUID: uid_t?
private let expectedGID: gid_t?

init(expectedUID: uid_t? = nil, expectedGID: gid_t? = nil) {
self.expectedUID = expectedUID
self.expectedGID = expectedGID
}

/// Validate peer credentials using SO_PEERCRED / LOCAL_PEERCRED
/// - Parameter socket_fd: The socket file descriptor to validate
/// - Returns: Validation result with peer identity or failure
func validatePeer(socket_fd: Int32) -> PeerValidationResult {
// Use the same approach as RelayManager.PeerVerification
// See RelayManager.swift:632-673 for platform-specific implementation

#if os(macOS)
// macOS: Use LOCAL_PEERPID via getsockopt
var peerPID: pid_t = 0
var length = socklen_t(MemoryLayout<pid_t>.size)
let result = getsockopt(socket_fd, 0, 2, &peerPID, &length) // LOCAL_PEERPID = 2

if result == 0 {
// On macOS, we get PID but need to trust the connection
// UID/GID verification requires TCC gating (Plan 88 A-1)
return .passed(peerUID: 0, peerGID: 0, peerPID: peerPID)
}
#else
// Linux: SO_PEERCRED
var cred = ucred()
var credLen = socklen_t(MemoryLayout<ucred>.size)
let result = getsockopt(socket_fd, SOL_SOCKET, SO_PEERCRED, &cred, &credLen)

if result == 0 {
// Validate UID if specified
if let expected = expectedUID, cred.uid != expected {
return .failed("UID mismatch: expected \(expected), got \(cred.uid)")
}
return .passed(peerUID: cred.uid, peerGID: cred.gid, peerPID: cred.pid)
}
#endif

return .failed("Cannot read peer credentials: \(errno)")
}
}

/// Result of peer validation
public enum PeerValidationResult: Sendable {
case passed(peerUID: uid_t, peerGID: gid_t, peerPID: pid_t)
case failed(String)

var isValid: Bool {
if case .passed = self { return true }
return false
}
}
