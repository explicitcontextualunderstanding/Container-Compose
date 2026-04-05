import Foundation
import Darwin
import os.log

// MARK: - Vsock Constants

/// AF_VSOCK address family for hardware-isolated VM communication
private let AF_VSOCK: Int32 = 40  // AF_VSOCK on Linux/macOS

/// Vsock socket types
private let SOCK_STREAM: Int32 = 1
private let SOCK_DGRAM: Int32 = 2

/// VMADDR_CID_ANY - accepts connections from any CID
private let VMADDR_CID_ANY: UInt32 = 0xFFFFFFFF

/// VMADDR_PORT_ANY - binds to any available port
private let VMADDR_PORT_ANY: UInt32 = 0xFFFFFFFF

/// Socket address for vsock
private struct sockaddr_vm {
    var svm_family: sa_family_t
    var svm_reserved1: UInt16
    var svm_port: UInt32
    var svm_cid: UInt32
    var svm_zero: (UInt8, UInt8, UInt8, UInt8)

    init() {
        self.svm_family = sa_family_t(AF_VSOCK)
        self.svm_reserved1 = 0
        self.svm_port = 0
        self.svm_cid = 0
        self.svm_zero = (0, 0, 0, 0)
    }
}

/// Maximum path length for Unix sockets
private let SUNPATH_MAX = 104

// MARK: - Vsock Relay

/// vsock listener for hardware-isolated IPC (Plan 77 Phase 2)
/// Uses native vsock sockets for VM-to-host communication
///
/// Architecture:
/// - Host (macOS) creates an AF_VSOCK socket
/// - Guest VMs connect to the host using vsock protocol
/// - This relay bridges vsock connections to Unix sockets for container communication
final actor VsockRelay: RelayProtocol {
    let transportType: RelayTransport
    var isRunning: Bool { isRunningValue }
    var activeConnectionCount: Int { activeConnectionCountValue }

    private var isRunningValue = false
    private var activeConnectionCountValue = 0

    private let cid: UInt32
    private let port: UInt32
    private let unixSocketPath: String
    private let eventLog: RelayEventLog
    private let cidVerifier: CIDVerifier
    private let logger: Logger

    private var listenSocket: Int32 = -1
    private var activeConnections: Set<VsockConnection> = []
    private var acceptTask: Task<Void, Error>?

    /// Creates a new vsock relay
    /// - Parameters:
    ///   - cid: The context ID to listen on (use VMADDR_CID_ANY for any)
    ///   - port: The vsock port to listen on
    ///   - unixSocketPath: Path to bridge vsock connections to
    ///   - allowedCIDs: List of authorized CIDs (empty = accept any)
    ///   - eventLog: Event logging actor
    init(
        cid: UInt32,
        port: UInt32,
        unixSocketPath: String,
        allowedCIDs: [UInt32] = [],
        eventLog: RelayEventLog
    ) throws {
        guard port > 0 else {
            throw VsockError.invalidPort(port)
        }

        self.cid = cid == VMADDR_CID_ANY ? VMADDR_CID_ANY : cid
        self.port = port
        self.unixSocketPath = unixSocketPath
        self.eventLog = eventLog
        self.cidVerifier = CIDVerifier(allowedCIDs: allowedCIDs.isEmpty ? [VMADDR_CID_ANY] : allowedCIDs)
        self.transportType = .vsock(cid: cid, port: port)
        self.logger = Logger(subsystem: "com.container-compose.relay", category: "VsockRelay-\(port)")

        logger.info("Initialized vsock relay: CID \(cid), Port \(port) → UNIX:\(unixSocketPath)")
    }

/// Start listening for vsock connections
func start() async throws {
    guard !isRunningValue else {
        throw RelayError.alreadyRunning("vsock-\(port)")
    }

        // Create vsock socket
        let sock = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw VsockError.deviceUnavailable("Failed to create vsock socket: \(errno)")
        }

        // Set socket options
        var opt: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        // Bind to address
        var addr = sockaddr_vm()
        addr.svm_cid = cid
        addr.svm_port = port

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }

        guard bindResult == 0 else {
            Darwin.close(sock)
            throw VsockError.deviceUnavailable("Failed to bind vsock socket: \(errno)")
        }

        // Start listening
        guard listen(sock, 10) == 0 else {
            Darwin.close(sock)
            throw VsockError.deviceUnavailable("Failed to listen on vsock socket: \(errno)")
        }

self.listenSocket = sock
self.isRunningValue = true

        logger.info("Vsock relay started on port \(self.port)")

        await eventLog.record(.relayStarted(
            id: "vsock-\(port)",
            port: UInt16(port),
            path: unixSocketPath
        ))

        // Start accept loop
        acceptTask = Task {
            try await acceptLoop()
        }
    }

/// Stop the relay and clean up resources
func stop() async {
    guard isRunningValue else { return }

        logger.info("Stopping vsock relay on port \(self.port)")

        // Cancel accept task
        acceptTask?.cancel()
        acceptTask = nil

        // Close listening socket
        if listenSocket >= 0 {
            Darwin.close(listenSocket)
            listenSocket = -1
        }

        // Close all active connections
        for connection in activeConnections {
            await connection.close()
        }
activeConnections.removeAll()
activeConnectionCountValue = 0

isRunningValue = false

        await eventLog.record(.relayStopped(id: "vsock-\(port)"))
        logger.info("Vsock relay stopped")
    }

    /// Accept loop for incoming connections
    private func acceptLoop() async throws {
        while !Task.isCancelled {
            var addr = sockaddr_vm()
            var len = socklen_t(MemoryLayout<sockaddr_vm>.size)

            let clientSock = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    withUnsafeMutablePointer(to: &len) { lenPtr in
                        accept(listenSocket, sockaddrPtr, lenPtr)
                    }
                }
            }

            guard clientSock >= 0 else {
                if errno == EINTR || errno == EAGAIN {
                    try await Task.sleep(nanoseconds: 1_000_000) // 1ms
                    continue
                }
                throw VsockError.deviceUnavailable("Accept failed: \(errno)")
            }

            // Set non-blocking mode
            var flags = fcntl(clientSock, F_GETFL, 0)
            fcntl(clientSock, F_SETFL, flags | O_NONBLOCK)

            // Verify CID
            let sourceCID = addr.svm_cid
            guard cidVerifier.verify(cid: sourceCID) else {
                logger.warning("Rejected connection from unauthorized CID \(sourceCID)")
                await eventLog.record(.connectionRejected(
                    relayId: "vsock-\(port)",
                    attemptedPID: pid_t(sourceCID),
                    expectedPID: nil
                ))
                Darwin.close(clientSock)
                continue
            }

            logger.info("Accepted vsock connection from CID \(sourceCID) on port \(addr.svm_port)")

            // Create bridged connection
            let connection = VsockConnection(
                vsockSocket: clientSock,
                sourceCID: sourceCID,
                sourcePort: addr.svm_port,
                unixSocketPath: unixSocketPath,
                relayId: "vsock-\(port)",
                eventLog: eventLog
            )

activeConnections.insert(connection)
activeConnectionCountValue = activeConnections.count

            await eventLog.record(.connectionEstablished(
                relayId: "vsock-\(port)",
                connectionId: connection.id
            ))

            // Start bridging in background
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

private func removeConnection(_ connection: VsockConnection) async {
    activeConnections.remove(connection)
    activeConnectionCountValue = activeConnections.count

        await eventLog.record(.connectionClosed(
            relayId: "vsock-\(port)",
            connectionId: connection.id
        ))
    }
}

// MARK: - Vsock Connection

/// Represents an active bridged vsock connection
private final actor VsockConnection: Hashable {
    let id: UUID
    private let vsockSocket: Int32
    private let sourceCID: UInt32
    private let sourcePort: UInt32
    private let unixSocketPath: String
    private let relayId: String
    private let eventLog: RelayEventLog

    init(
        vsockSocket: Int32,
        sourceCID: UInt32,
        sourcePort: UInt32,
        unixSocketPath: String,
        relayId: String,
        eventLog: RelayEventLog
    ) {
        self.id = UUID()
        self.vsockSocket = vsockSocket
        self.sourceCID = sourceCID
        self.sourcePort = sourcePort
        self.unixSocketPath = unixSocketPath
        self.relayId = relayId
        self.eventLog = eventLog
    }

    func start(completion: @escaping @Sendable () -> Void) async {
        var unixSocketFD: Int32 = -1

        do {
            // Create and connect to Unix socket
            unixSocketFD = try createUnixSocketConnection(path: unixSocketPath)

            // Start bidirectional bridging
            async let vsockToUnix: () = bridgeVsockToUnix(vsockFD: vsockSocket, unixFD: unixSocketFD)
            async let unixToVsock: () = bridgeUnixToVsock(unixFD: unixSocketFD, vsockFD: vsockSocket)

            // Wait for either direction to complete
            _ = await (vsockToUnix, unixToVsock)
        } catch {
            // Log error
        }

        // Cleanup
        if unixSocketFD >= 0 {
            Darwin.close(unixSocketFD)
        }
        Darwin.close(vsockSocket)

        completion()
    }

    func close() async {
        Darwin.close(vsockSocket)
    }

    private func createUnixSocketConnection(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VsockError.deviceUnavailable("Failed to create Unix socket: \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cString in
            strncpy(&addr.sun_path.0, cString, Int(SUNPATH_MAX) - 1)
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            Darwin.close(fd)
            throw VsockError.deviceUnavailable("Failed to connect to \(path): \(errno)")
        }

        return fd
    }

    private func bridgeVsockToUnix(vsockFD: Int32, unixFD: Int32) async {
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return read(vsockFD, baseAddress, bufferSize)
            }

            guard bytesRead > 0 else {
                break // Connection closed or error
            }

            var totalWritten: Int = 0
            while totalWritten < bytesRead {
                let remaining = bytesRead - totalWritten
                let written = buffer.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                    return Darwin.write(unixFD, baseAddress.advanced(by: totalWritten), remaining)
                }

                guard written > 0 else {
                    return // Error writing
                }
                totalWritten += written
            }
        }
    }

    private func bridgeUnixToVsock(unixFD: Int32, vsockFD: Int32) async {
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return read(unixFD, baseAddress, bufferSize)
            }

            guard bytesRead > 0 else {
                break // Connection closed or error
            }

            var totalWritten: Int = 0
            while totalWritten < bytesRead {
                let remaining = bytesRead - totalWritten
                let written = buffer.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                    return Darwin.write(vsockFD, baseAddress.advanced(by: totalWritten), remaining)
                }

                guard written > 0 else {
                    return // Error writing
                }
                totalWritten += written
            }
        }
    }

    // MARK: - Hashable

    nonisolated static func == (lhs: VsockConnection, rhs: VsockConnection) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Extension

extension RelayError {
    static func vsockUnavailable(_ message: String, _ error: Error) -> RelayError {
        .networkError(VsockError.deviceUnavailable("\(message): \(error.localizedDescription)"))
    }
}
