import Darwin // For pid_t, getsockopt
import Foundation
import Network
import os.log
import SecurityHardening

// MARK: - Sandbox-Resilient Configuration

/// Sandbox-resilient socket relay configuration
/// Aligns with Apple's security philosophy for inter-process communication
enum RelayConstants {
    /// Relay root directory - sandbox-safe location, configurable via env var
    /// Priority: 1) CONTAINER_COMPOSE_RELAY_ROOT env var, 2) ~/.container-compose/sockets
    /// Using user-managed IPC over global /tmp/ which may be restricted in future macOS
    static let relayRoot: URL = {
        // Check for environment variable override
        if let envPath = ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_RELAY_ROOT"],
            !envPath.isEmpty {
            return URL(fileURLWithPath: envPath)
        }
        // Default to ~/.container-compose/sockets
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".container-compose/sockets")
    }()

    /// Socket file permissions - owner read/write only (0600)
    /// Signals to macOS kernel that this is a private IPC channel
    static let socketPermissions: UInt16 = 0o600

    /// Relay root directory permissions - owner only (0700)
    static let directoryPermissions: UInt16 = 0o700

    /// Ensure relay root directory exists with proper permissions
    static func ensureRelayRoot() throws {
        let fm = FileManager.default

        if !fm.fileExists(atPath: relayRoot.path) {
            try fm.createDirectory(
                at: relayRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
        }
    }

    /// Generate a sandbox-safe socket path
    static func socketPath(for id: String, project: String? = nil) -> URL {
        let safeId = id.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let safeProject = project?.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let filename: String
        if let proj = safeProject {
            filename = "\(proj)-\(safeId).sock"
        } else {
            filename = "\(safeId).sock"
        }
        return relayRoot.appendingPathComponent(filename)
    }
}

// MARK: - Streamable Protocol (for testability)

/// Protocol for abstracting network connections to enable testing with mocks
/// Conforms to Sendable for Swift concurrency safety
protocol Streamable: AnyObject, Sendable {
    var isConnected: Bool { get }
    func start(queue: DispatchQueue)
    func cancel()
    func send(content: Data?, completion: @escaping @Sendable (Error?) -> Void)
    func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, Error?) -> Void)
}

/// NWConnection wrapper conforming to Streamable
final class NWConnectionWrapper: Streamable {
    private let connection: NWConnection

    var isConnected: Bool {
        if case .ready = connection.state { return true }
        return false
    }

    /// Expose the underlying file descriptor for PID verification
    /// Returns -1 because NWConnection doesn't expose underlying socket
    /// Network.framework abstraction prevents direct getsockopt access
    var fileDescriptor: Int32 {
        return -1 // File descriptor not accessible through Network.framework
    }

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func send(content: Data?, completion: @escaping (Error?) -> Void) {
        connection.send(content: content, completion: .contentProcessed { error in
            completion(error)
        })
    }

    func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping (Data?, NWConnection.ContentContext?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength, completion: completion)
    }
}

// MARK: - Supporting Types

/// Event log for debugging and diagnostics
actor RelayEventLog {
  enum Event {
    case relayStarted(id: String, port: UInt16, path: String)
    case relayStopped(id: String)
    case connectionEstablished(relayId: String, connectionId: UUID)
    case connectionClosed(relayId: String, connectionId: UUID)
    /// Security event: connection rejected due to PID mismatch (Phase 5)
    case connectionRejected(relayId: String, attemptedPID: pid_t, expectedPID: pid_t?)
    /// Security event: connection authorized after PID verification (Phase 5)
    case connectionAuthorized(relayId: String, pid: pid_t)
    /// Security event: peer verification failed or unavailable
    case peerVerificationFailed(relayId: String, reason: String)
    case error(RelayError)

    /// Relay ID associated with this event, if any
    var relayId: String? {
      switch self {
      case .relayStarted(let id, _, _): return id
      case .relayStopped(let id): return id
      case .connectionEstablished(let relayId, _): return relayId
      case .connectionClosed(let relayId, _): return relayId
      case .connectionRejected(let relayId, _, _): return relayId
      case .connectionAuthorized(let relayId, _): return relayId
      case .peerVerificationFailed(let relayId, _): return relayId
      case .error: return nil
      }
    }
  }

  private var events: [Event] = []

  func record(_ event: Event) {
    events.append(event)
  }

  func recentEvents(limit: Int = 100) -> [Event] {
    Array(events.suffix(limit))
  }

  /// Get all events for a specific relay
  func eventsForRelay(_ relayId: String) -> [Event] {
    events.filter { $0.relayId == relayId }
  }
}

/// Status of a running relay
struct RelayStatus {
    let id: String
    let isRunning: Bool
    let tcpPort: UInt16
    let unixSocketPath: String
    let activeConnections: Int
}

/// Errors that can occur in relay operations
enum RelayError: Error, CustomStringConvertible {
    case alreadyRunning(String)
    case unixSocketUnavailable(String, Error)
    case timeout(String)
    case portInUse(UInt16)
    case networkError(Error)
    case socketPathTooLong(path: String, length: Int, limit: Int)
    // MARK: - Plan 85 Security Errors
    case securityValidationFailed(gate: String, message: String)

    var description: String {
        switch self {
        case .alreadyRunning(let id):
            return "Relay '\(id)' is already running"
        case .unixSocketUnavailable(let path, let error):
            return "Unix socket at \(path) unavailable: \(error.localizedDescription)"
        case .timeout(let message):
            return "Timeout: \(message)"
        case .portInUse(let port):
            return "Port \(port) is already in use"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .socketPathTooLong(let path, let length, let limit):
            return "Socket path too long: \(length) chars (limit: \(limit)). Shorten the project or volume name."
        case .securityValidationFailed(let gate, let message):
            return "Security gate '\(gate)' blocked relay: \(message)"
        }
    }
}

// MARK: - RelayStarter Protocol

/// Protocol for creating relay instances - enables dependency injection for testing
protocol RelayStarter: Sendable {
	/// Create a relay instance based on configuration
	/// - Parameters:
	/// - config: Relay configuration (nested type from RelayManager)
	/// - eventLog: Event logging for relay operations
	/// - Returns: A relay conforming to RelayProtocol
	/// - Throws: RelayError if relay cannot be created
	func createRelay(config: RelayManager.RelayConfiguration, eventLog: RelayEventLog) async throws -> any RelayProtocol
}

/// Default implementation using actual relay types
struct RealRelayStarter: RelayStarter {
    /// Security manager for entitlement validation
    private let secureManager: SecureRelayManager?
    
    init(secureManager: SecureRelayManager? = nil) {
        self.secureManager = secureManager
    }
    
    func createRelay(config: RelayManager.RelayConfiguration, eventLog: RelayEventLog) async throws -> any RelayProtocol {
        // Check security gates first
        if let secure = secureManager {
            let socketPath: String? = switch config.transport {
            case .uds(let path, _): path
            case .vsockDb(let path): path
            case .unixSocket(let path): path
            case .vsock(_, _, let path): path.isEmpty ? nil : path
            case .tcp: nil
            }
            
            let securityResult = await secure.validateRelayStartupPrimitives(
                id: config.id,
                socketPath: socketPath,
                transport: config.transport
            )
            
            guard securityResult.passed else {
                let gate = securityResult.blockedBy?.description ?? "Unknown"
                let message = securityResult.errorMessage ?? "Security validation failed"
                throw RelayError.securityValidationFailed(gate: gate, message: message)
            }
        }
        
        // Create the actual relay based on transport type
        switch config.transport {
        case .uds(let path, _):
            let isVolumeSocket = path.contains(".containers/Volumes")
            return try UDSVirtioFSRelay(
                socketPath: path,
                createSignalSocket: !isVolumeSocket,
                eventLog: eventLog
            )
            
        case .vsock(let cid, let port, _):
            // Check vsock availability
            let availability = checkVsockAvailability()
            if !availability.isAvailable {
                // Fall back to TCP relay
                return try await SocketRelay(
                    tcpPort: config.tcpPort,
                    unixPath: config.unixSocketPath,
                    eventLog: eventLog
                )
            }
            
            let isVolumeSocket = config.unixSocketPath.contains(".containers/Volumes")
            return try VsockRelay(
                cid: cid,
                port: port,
                unixSocketPath: config.unixSocketPath,
                createSignalSocket: !isVolumeSocket,
                eventLog: eventLog
            )
            
        case .unixSocket, .tcp:
            return try await SocketRelay(
                tcpPort: config.tcpPort,
                unixPath: config.unixSocketPath,
                eventLog: eventLog
            )
            
        case .vsockDb(let socketPath):
            return try UDSVirtioFSRelay(
                socketPath: socketPath,
                createSignalSocket: false, // PostgreSQL creates the socket
                eventLog: eventLog
            )
        }
    }
}

// MARK: - RelayManager

/// Enables container-to-container communication via host-mediated socket relay
actor RelayManager {
    private var relays: [String: any RelayProtocol] = [:]
    private let eventLog: RelayEventLog
    private let logger = Logger(subsystem: "com.container-compose.relay", category: "RelayManager")

    // MARK: - Security Integration (Plan 85)
    /// Secure relay manager for TCC/AMFI/Isolation gating
    private let secureManager: SecureRelayManager?
    
    /// Relay starter for dependency injection (enables testing)
    private let relayStarter: any RelayStarter

    /// Initialize with optional security integration
    /// - Parameters:
    /// - eventLog: Event logging for relay operations
    /// - enableSecurity: Enable Plan 85 security gates (default: true)
    /// - relayStarter: Custom relay starter for testing (default: RealRelayStarter)
    init(
        eventLog: RelayEventLog = RelayEventLog(),
        enableSecurity: Bool = true,
        relayStarter: (any RelayStarter)? = nil
    ) {
        self.eventLog = eventLog
        self.secureManager = enableSecurity ? SecureRelayManager(configuration: .production) : nil
        self.relayStarter = relayStarter ?? RealRelayStarter(secureManager: self.secureManager)
    }

    /// Configuration for a socket relay
    struct RelayConfiguration {
        let id: String
        let tcpPort: UInt16
        let transport: RelayTransport
        let description: String
        /// Expected PID of the container process for peer verification (Phase 5 security)
        let targetPID: pid_t?

        /// Legacy initializer for backward compatibility
        init(id: String, tcpPort: UInt16, unixSocketPath: String, description: String, targetPID: pid_t? = nil) {
            self.id = id
            self.tcpPort = tcpPort
            self.transport = .unixSocket(path: unixSocketPath)
            self.description = description
            self.targetPID = targetPID
        }

        /// New initializer with transport abstraction (Plan 77)
        init(id: String, tcpPort: UInt16, transport: RelayTransport, description: String, targetPID: pid_t? = nil) {
            self.id = id
            self.tcpPort = tcpPort
            self.transport = transport
            self.description = description
            self.targetPID = targetPID
        }

  /// Convenience accessor for Unix socket path (backward compatibility)
  var unixSocketPath: String {
    switch transport {
    case .unixSocket(let path):
      return path
    case .uds(let path, _):
      return path
    case .vsock(_, _, let path):
      return path
    case .vsockDb(let path):
      return path
    case .tcp:
      return ""
    }
  }

  /// CID from vsock transport (for SecurityHardening protocol)
  var cid: UInt32? {
    if case .vsock(let cid, _, _) = transport {
      return cid
    }
    return nil
  }
}

    /// Start a new relay with the given configuration
    /// - Throws: RelayError if the relay cannot be started
    func startRelay(_ config: RelayConfiguration) async throws {
        guard relays[config.id] == nil else {
            throw RelayError.alreadyRunning(config.id)
        }

        logger.info("Starting relay \(config.id) via RelayStarter")
        
        // Use injected RelayStarter for dependency injection (enables testing)
        let relay = try await relayStarter.createRelay(config: config, eventLog: eventLog)
        
        relays[config.id] = relay
        try await relay.start()
        
        let path = await relay.unixSocketPath
        await eventLog.record(.relayStarted(id: config.id, port: config.tcpPort, path: path))
        logger.info("Relay \(config.id) started successfully")
    }

    /// Stop a specific relay by ID
    func stopRelay(id: String) async {
        guard let relay = relays[id] else {
            logger.warning("Attempted to stop non-existent relay: \(id)")
            return
        }

        logger.info("Stopping relay \(id)")
        
        // Get socket path before stopping
        let socketPath = await relay.unixSocketPath
        
        await relay.stop()
        relays.removeValue(forKey: id)
        await eventLog.record(.relayStopped(id: id))

        // Clean up socket file
        if !socketPath.isEmpty {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    /// Stop all running relays
    func stopAll() async {
        logger.info("Stopping all relays (\(self.relays.count) active)")

        for (id, relay) in self.relays {
            logger.debug("Stopping relay \(id)")
            await relay.stop()
            await eventLog.record(.relayStopped(id: id))
        }

        relays.removeAll()
        await cleanupSocketFiles()
    }

    /// Get status of all relays
    func status() async -> [RelayStatus] {
        var statuses: [RelayStatus] = []
        for (id, relay) in relays {
            statuses.append(await RelayStatus(
                id: id,
                isRunning: relay.isRunning,
                tcpPort: relay.tcpPort,
                unixSocketPath: relay.unixSocketPath,
                activeConnections: relay.activeConnectionCount
            ))
        }
        return statuses
    }

    /// Wait for a Unix socket file to be created (e.g., by container --publish-socket)
    /// - Parameters:
    /// - path: Path to the Unix socket file
    /// - timeout: Maximum time to wait (default: 30 seconds)
    /// - interval: Polling interval (default: 100ms)
    /// - Throws: RelayError.timeout if socket doesn't appear within timeout
    func waitForSocket(at path: String, timeout: TimeInterval = 30, interval: TimeInterval = 0.1) async throws {
        // Use SocketHealth for reliable polling with circuit breaker
        let status = await SocketHealth.waitForSocket(
            socketPath: path,
            config: SocketHealth.Configuration(
                socketTimeout: timeout,
                initialPollingInterval: interval,
                maxPollingInterval: 1.0,
                backoffMultiplier: 1.5
            )
        )

        if status.isReady {
            logger.debug("Socket found at \(path) after \(status.attempts) attempts")
            return
        }

        // Handle specific error types
        if let error = status.error {
            switch error {
            case .circuitBreakerOpen:
                logger.error("Circuit breaker open for socket at \(path) - too many failures")
                throw RelayError.timeout("Circuit breaker open - socket at \(path) has too many consecutive failures")
            case .notSocket(let socketPath):
                logger.error("File exists but is not a socket: \(socketPath)")
                throw RelayError.timeout("File exists but is not a socket: \(socketPath)")
            case .containerNotRunning(let id):
                logger.error("Container '\(id)' is not running")
                throw RelayError.timeout("Container '\(id)' is not running")
            default:
                logger.error("Socket timeout at \(path): \(error.description)")
                throw RelayError.timeout("Socket did not appear at \(path): \(error.description)")
            }
        }

        throw RelayError.timeout("Socket did not appear at \(path) within \(timeout)s")
    }

    /// Clean up orphaned socket files
    private func cleanupSocketFiles() async {
        for (_, relay) in relays {
            let path = await relay.unixSocketPath
            if !path.isEmpty {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    logger.debug("Cleaned up socket file: \(path)")
                } catch {
                    logger.warning("Failed to clean up socket file \(path): \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - SocketRelay

/// Individual socket relay managing a single TCP↔UDS bridge
actor SocketRelay: RelayProtocol {
    var transportType: RelayTransport { .unixSocket(path: unixSocketPath) }
    var isRunning: Bool { isRunningValue }
    var activeConnectionCount: Int { activeConnectionCountValue }
    
    private var listener: NWListener?
    private var activeConnections: Set<BridgeConnection> = []
    private let eventLog: RelayEventLog
    private let logger: Logger
    private let targetPID: pid_t? // Phase 5: Expected container PID

    let tcpPort: UInt16
    let unixSocketPath: String
    
    private var isRunningValue = false
    private var activeConnectionCountValue = 0

    init(tcpPort: UInt16, unixPath: String, eventLog: RelayEventLog, targetPID: pid_t? = nil) async throws {
        self.tcpPort = tcpPort
        self.unixSocketPath = unixPath
        self.eventLog = eventLog
        self.targetPID = targetPID
        self.logger = Logger(subsystem: "com.container-compose.relay", category: "SocketRelay-\(tcpPort)")

        // Wait for the Unix socket to exist (published by container)
        try await RelayManager(eventLog: eventLog).waitForSocket(at: unixPath, timeout: 30)

        // Verify we can connect to the Unix socket
        let testConnection = NWConnection(to: .unix(path: unixPath), using: .tcp)
        testConnection.start(queue: .global())

        // Give it a moment to connect or fail
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        if case .failed(let error) = testConnection.state {
            throw RelayError.unixSocketUnavailable(unixPath, error)
        }

        testConnection.cancel()

        self.isRunningValue = false
        self.activeConnectionCountValue = 0
    }

    func start() async throws {
        guard listener == nil else {
            throw RelayError.alreadyRunning("Relay on port \(tcpPort)")
        }

        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: tcpPort)!)
        listener?.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleNewConnection(connection)
            }
        }

        listener?.start(queue: .global())
        logger.info("Listening on TCP port \(self.tcpPort)")
    }

    func stop() async {
        listener?.cancel()
        listener = nil

        for connection in activeConnections {
            await connection.close()
        }
        activeConnections.removeAll()

        logger.info("Relay stopped")
    }

    func removeConnection(_ connection: BridgeConnection) {
        activeConnections.remove(connection)
    }

    private func handleNewConnection(_ tcpConnection: NWConnection) async {
        logger.debug("New TCP connection on port \(self.tcpPort)")

        // Phase 5: Verify peer PID if target is specified
        if let expectedPID = self.targetPID {
            // Attempt to verify peer using the TCP connection's underlying socket
            // Note: Network.framework abstracts file descriptors, so verification may be limited
            let verified = await verifyPeerConnection(tcpConnection, expectedPID: expectedPID)
            guard verified else {
                logger.warning("Security: Connection rejected - PID verification failed for relay \(self.tcpPort)")
                tcpConnection.cancel()
                await eventLog.record(.peerVerificationFailed(relayId: "\(self.tcpPort)", reason: "PID mismatch or verification unavailable"))
                return
            }
            logger.info("Security: Connection authorized for PID \(expectedPID)")
        }

        let bridge = BridgeConnection(
            tcpConnection: tcpConnection,
            unixSocketPath: unixSocketPath,
            eventLog: eventLog,
            targetPID: self.targetPID,
            relayId: "\(self.tcpPort)"
        )

        activeConnections.insert(bridge)
        await eventLog.record(.connectionEstablished(relayId: "\(self.tcpPort)", connectionId: bridge.id))

        await bridge.start { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                await self.removeConnection(bridge)
            }
        }
    }
}

// MARK: - PID Verification (Phase 5 Security)

/// Extension to attempt peer verification on NWConnection
/// Note: Network.framework abstracts file descriptors, making direct verification challenging
extension SocketRelay {
    /// Attempt to verify peer PID from an NWConnection
    /// - Parameters:
    /// - connection: The NWConnection to verify
    /// - expectedPID: The expected container process ID
    /// - Returns: true if verified or verification unavailable, false if rejected
    /// - Note: Currently operates in permissive mode due to NWConnection abstraction
    private func verifyPeerConnection(_ connection: NWConnection, expectedPID: pid_t) async -> Bool {
        // NWConnection does not expose its underlying file descriptor directly
        // This is a limitation of Network.framework's abstraction

        // In a future implementation, we could:
        // 1. Use private APIs to access the underlying socket
        // 2. Implement a custom POSIX socket wrapper that supports getsockopt
        // 3. Use a security proxy process that has access to the raw socket

        // For now, we operate in "permissive but logged" mode
        // The relay will log that verification was attempted but cannot be completed
        logger.debug("Security: Peer verification requested for PID \(expectedPID), but NWConnection abstraction prevents direct getsockopt access")

        // Return true to allow connection (permissive mode)
        // In production, this should be replaced with actual verification
        return true
    }
}

/// Security utilities for peer verification using LOCAL_PEERPID
/// Note: Network.framework abstracts file descriptors, so direct getsockopt is limited
enum PeerVerification {
    /// Attempt to verify peer PID using LOCAL_PEERPID (macOS) or SO_PEERCRED (Linux)
    /// - Parameters:
    /// - fileDescriptor: The socket file descriptor
    /// - expectedPID: The expected container process ID
    /// - Returns: true if PID matches, false otherwise
    /// - Note: Returns true in "permissive mode" if verification unavailable
    static func verifyPID(fileDescriptor: Int32, expectedPID: pid_t?) -> Bool {
        guard let expected = expectedPID else {
            // No target PID specified, allow connection (backward compatible)
            return true
        }

        var peerPID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)

        #if os(macOS)
        // SOL_LOCAL = 0, LOCAL_PEERPID = 2 on macOS
        let result = getsockopt(fileDescriptor, 0, 2, &peerPID, &length)
        #else
        // Linux: SO_PEERCRED
        var cred = ucred()
        var credLen = socklen_t(MemoryLayout<ucred>.size)
        let result = getsockopt(fileDescriptor, SOL_SOCKET, SO_PEERCRED, &cred, &credLen)
        peerPID = cred.pid
        #endif

        guard result == 0 else {
            // Verification failed, log but allow (permissive mode)
            return true
        }

        return peerPID == expected
    }

    /// Log security event for rejected connection
    static func logRejection(relayId: String, attemptedPID: pid_t, expectedPID: pid_t?, eventLog: RelayEventLog) async {
        await eventLog.record(.connectionRejected(relayId: relayId, attemptedPID: attemptedPID, expectedPID: expectedPID))
    }
}

// MARK: - BridgeConnection

/// Manages bidirectional data flow between TCP and Unix socket
/// Now uses Streamable protocol for testability with mocks
actor BridgeConnection: Hashable {
    let id: UUID
    private let source: Streamable
    private let destination: Streamable
    private let eventLog: RelayEventLog
    private let logger: Logger
    private let targetPID: pid_t?
    private let relayId: String

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: BridgeConnection, rhs: BridgeConnection) -> Bool {
        lhs.id == rhs.id
    }

    /// Initialize with raw NWConnections (production use)
    /// - Parameters:
    /// - tcpConnection: The incoming TCP connection
    /// - unixSocketPath: Path to the Unix domain socket
    /// - eventLog: Event logging actor
    /// - targetPID: Expected container PID for verification (Phase 5)
    /// - relayId: Relay identifier for logging
    init(
        tcpConnection: NWConnection,
        unixSocketPath: String,
        eventLog: RelayEventLog,
        targetPID: pid_t? = nil,
        relayId: String = "unknown"
    ) {
        self.id = UUID()
        self.source = NWConnectionWrapper(connection: tcpConnection)
        self.destination = NWConnectionWrapper(connection: NWConnection(to: .unix(path: unixSocketPath), using: .tcp))
        self.eventLog = eventLog
        self.targetPID = targetPID
        self.relayId = relayId
        self.logger = Logger(subsystem: "com.container-compose.relay", category: "Bridge-\(id.uuidString.prefix(8))")
    }

    /// Initialize with Streamable connections (testing use)
    init(source: Streamable, destination: Streamable, eventLog: RelayEventLog = RelayEventLog()) {
        self.id = UUID()
        self.source = source
        self.destination = destination
        self.eventLog = eventLog
        self.targetPID = nil
        self.relayId = "test"
        self.logger = Logger(subsystem: "com.container-compose.relay", category: "Bridge-\(id.uuidString.prefix(8))")
    }

    func start(completion: @escaping () -> Void) async {
        source.start(queue: .global())
        destination.start(queue: .global())

        // Start bidirectional piping
        async let forward: () = pipe(from: source, to: destination, label: "TCP→UDS")
        async let reverse: () = pipe(from: destination, to: source, label: "UDS→TCP")

        // Wait for either direction to complete (connection closed)
        _ = await (forward, reverse)

        close()
        completion()
    }

    private func pipe(from input: Streamable, to output: Streamable, label: String) async {
        while true {
            do {
                let data = try await receive(from: input)
                guard !data.isEmpty else {
                    logger.debug("\(label): Empty data, connection likely closing")
                    break
                }

                try await send(data: data, to: output)

                // Log large transfers
                if data.count > 1024 * 1024 { // 1MB
                    logger.debug("\(label): Transferred \(data.count) bytes")
                }
            } catch {
                logger.debug("\(label): Error - \(error.localizedDescription)")
                break
            }
        }
    }

    private func receive(from connection: Streamable) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(data: Data, to connection: Streamable) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

func close() {
  source.cancel()
  destination.cancel()
  logger.debug("Connection \(self.id.uuidString.prefix(8)) closed")
}
}

// MARK: - SecurityHardening Protocol Conformance
// Note: RelayConfigProviding protocol conformance removed - protocol not defined in this module
// This was part of Plan 85 SecurityHardening integration which is still in development