import Foundation
import Network
import os.log

/// Manages socket relay bridges between TCP ports and Unix Domain Sockets
/// Enables container-to-container communication via host-mediated socket relay
actor RelayManager {
    private var relays: [String: SocketRelay] = [:]
    private let eventLog: RelayEventLog
    private let logger = Logger(subsystem: "com.container-compose.relay", category: "RelayManager")
    
    init(eventLog: RelayEventLog = RelayEventLog()) {
        self.eventLog = eventLog
    }
    
    /// Configuration for a socket relay
    struct RelayConfiguration {
        let id: String
        let tcpPort: UInt16
        let unixSocketPath: String
        let description: String
        
        init(id: String, tcpPort: UInt16, unixSocketPath: String, description: String) {
            self.id = id
            self.tcpPort = tcpPort
            self.unixSocketPath = unixSocketPath
            self.description = description
        }
    }
    
    /// Start a new relay with the given configuration
    /// - Throws: RelayError if the relay cannot be started
    func startRelay(_ config: RelayConfiguration) async throws {
        guard relays[config.id] == nil else {
            throw RelayError.alreadyRunning(config.id)
        }
        
        logger.info("Starting relay \(config.id): TCP:\(config.tcpPort) → UNIX:\(config.unixSocketPath)")
        
        let relay = try await SocketRelay(
            tcpPort: config.tcpPort,
            unixPath: config.unixSocketPath,
            eventLog: eventLog
        )
        
relays[config.id] = relay
try await relay.start()

await eventLog.record(.relayStarted(id: config.id, port: config.tcpPort, path: config.unixSocketPath))
logger.info("Relay \(config.id) started successfully")
    }
    
    /// Stop a specific relay by ID
    func stopRelay(id: String) async {
        guard let relay = relays[id] else {
            logger.warning("Attempted to stop non-existent relay: \(id)")
            return
        }
        
logger.info("Stopping relay \(id)")
await relay.stop()
relays.removeValue(forKey: id)
await eventLog.record(.relayStopped(id: id))
        
        // Clean up socket file
        if let relay = relays[id] {
            try? FileManager.default.removeItem(atPath: relay.unixSocketPath)
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
cleanupSocketFiles()
}
    
    /// Get status of all relays
    func status() -> [RelayStatus] {
        relays.map { (id, relay) in
            RelayStatus(
                id: id,
                isRunning: relay.isRunning,
                tcpPort: relay.tcpPort,
                unixSocketPath: relay.unixSocketPath,
                activeConnections: relay.activeConnectionCount
            )
        }
    }
    
    /// Wait for a Unix socket file to be created (e.g., by container --publish-socket)
    /// - Parameters:
    ///   - path: Path to the Unix socket file
    ///   - timeout: Maximum time to wait (default: 30 seconds)
    ///   - interval: Polling interval (default: 100ms)
    /// - Throws: RelayError.timeout if socket doesn't appear within timeout
    func waitForSocket(at path: String, timeout: TimeInterval = 30, interval: TimeInterval = 0.1) async throws {
        let startTime = Date()
        let fileManager = FileManager.default
        
        while Date().timeIntervalSince(startTime) < timeout {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
                // Check if it's a socket (not a directory or regular file)
                var statInfo = stat()
                if stat(path, &statInfo) == 0 {
                    if (statInfo.st_mode & S_IFMT) == S_IFSOCK {
                        logger.debug("Socket found at \(path)")
                        return
                    }
                }
            }
            
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        
        throw RelayError.timeout("Socket did not appear at \(path) within \(timeout)s")
    }
    
    /// Clean up orphaned socket files
    private func cleanupSocketFiles() {
        let socketPaths = relays.values.map { $0.unixSocketPath }
        for path in socketPaths {
            do {
                try FileManager.default.removeItem(atPath: path)
                logger.debug("Cleaned up socket file: \(path)")
            } catch {
                logger.warning("Failed to clean up socket file \(path): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - SocketRelay

/// Individual socket relay managing a single TCP↔UDS bridge
actor SocketRelay {
    private var listener: NWListener?
    private var activeConnections: Set<BridgeConnection> = []
    private let eventLog: RelayEventLog
    private let logger: Logger
    
    let tcpPort: UInt16
    let unixSocketPath: String
    let isRunning: Bool
    let activeConnectionCount: Int
    
    init(tcpPort: UInt16, unixPath: String, eventLog: RelayEventLog) async throws {
        self.tcpPort = tcpPort
        self.unixSocketPath = unixPath
        self.eventLog = eventLog
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
        
        self.isRunning = false
        self.activeConnectionCount = 0
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

let bridge = BridgeConnection(
tcpConnection: tcpConnection,
unixSocketPath: unixSocketPath,
eventLog: eventLog
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

// MARK: - BridgeConnection

/// Manages bidirectional data flow between TCP and Unix socket
actor BridgeConnection: Hashable {
    let id: UUID
    private let tcpConnection: NWConnection
    private let unixConnection: NWConnection
    private let eventLog: RelayEventLog
    private let logger: Logger
    
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    nonisolated static func == (lhs: BridgeConnection, rhs: BridgeConnection) -> Bool {
        lhs.id == rhs.id
    }
    
    init(tcpConnection: NWConnection, unixSocketPath: String, eventLog: RelayEventLog) {
        self.id = UUID()
        self.tcpConnection = tcpConnection
        self.unixConnection = NWConnection(to: .unix(path: unixSocketPath), using: .tcp)
        self.eventLog = eventLog
        self.logger = Logger(subsystem: "com.container-compose.relay", category: "Bridge-\(id.uuidString.prefix(8))")
    }
    
    func start(completion: @escaping () -> Void) async {
        tcpConnection.start(queue: .global())
        unixConnection.start(queue: .global())
        
        // Start bidirectional piping
        async let tcpToUnix: () = pipe(from: tcpConnection, to: unixConnection, label: "TCP→UDS")
        async let unixToTcp: () = pipe(from: unixConnection, to: tcpConnection, label: "UDS→TCP")
        
        // Wait for either direction to complete (connection closed)
        _ = await (tcpToUnix, unixToTcp)
        
        close()
        completion()
    }
    
    private func pipe(from source: NWConnection, to destination: NWConnection, label: String) async {
        while true {
            do {
                let data = try await receive(from: source)
                guard !data.isEmpty else {
                    logger.debug("\(label): Empty data, connection likely closing")
                    break
                }
                
                try await send(data: data, to: destination)
                
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
    
    private func receive(from connection: NWConnection) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    // No data yet, continue waiting (shouldn't happen with minimumIncompleteLength: 1)
                    continuation.resume(returning: Data())
                }
            }
        }
    }
    
  private func send(data: Data, to connection: NWConnection) async throws {
    return try await withCheckedThrowingContinuation { continuation in
      connection.send(content: data, completion: .contentProcessed { error in
        if let error = error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      })
    }
  }
    
  func close() {
    tcpConnection.cancel()
    unixConnection.cancel()
    logger.debug("Connection \(self.id.uuidString.prefix(8)) closed")
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
        case error(RelayError)
    }
    
    private var events: [Event] = []
    
    func record(_ event: Event) {
        events.append(event)
    }
    
    func recentEvents(limit: Int = 100) -> [Event] {
        Array(events.suffix(limit))
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
        }
    }
}
