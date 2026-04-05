import Foundation
import Virtualization

/// vsock listener for hardware-isolated IPC (Plan 77 Phase 2)
/// Uses Apple's Virtualization.framework for VM-to-host communication
final class VsockRelay: RelayProtocol {
    let tcpPort: UInt16
    let vsockCid: UInt32
    let vsockPort: UInt32
    let eventLog: RelayEventLog
    let targetPID: pid_t?
    
    private(set) var isRunning = false
    private var listener: VZVsockSocketListener?
    private var activeConnections: Set<VsockConnection> = []
    private let logger = Logger(subsystem: "com.container-compose.relay", category: "VsockRelay")
    
    var activeConnectionCount: Int { activeConnections.count }
    var unixSocketPath: String { "" } // vsock has no filesystem path
    var transportType: RelayTransport { .vsock(cid: vsockCid, port: vsockPort) }
    
    init(tcpPort: UInt16, vsockCid: UInt32, vsockPort: UInt32, eventLog: RelayEventLog, targetPID: pid_t? = nil) async throws {
        self.tcpPort = tcpPort
        self.vsockCid = vsockCid
        self.vsockPort = vsockPort
        self.eventLog = eventLog
        self.targetPID = targetPID
    }
    
    func start() async throws {
        guard !isRunning else { return }
        
        logger.info("Starting vsock relay: TCP:\(tcpPort) → VSOCK:\(vsockCid):\(vsockPort)")
        
        // Create vsock listener using Virtualization.framework
        // Note: This requires macOS 12+ and proper entitlements
        do {
            let listener = VZVsockSocketListener()
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            self.listener = listener
            isRunning = true
            
            await eventLog.record(.relayStarted(id: "vsock-\(vsockCid)-\(vsockPort)", port: tcpPort, path: "vsock:\(vsockCid):\(vsockPort)"))
            logger.info("Vsock relay started successfully")
        } catch {
            logger.error("Failed to start vsock listener: \(error.localizedDescription)")
            throw RelayError.vsockUnavailable("Failed to create vsock listener", error)
        }
    }
    
    func stop() async {
        guard isRunning else { return }
        
        logger.info("Stopping vsock relay")
        
        // Close all active connections
        for connection in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        
        // Stop listener
        listener = nil
        isRunning = false
        
        await eventLog.record(.relayStopped(id: "vsock-\(vsockCid)-\(vsockPort)"))
        logger.info("Vsock relay stopped")
    }
    
    private func handleNewConnection(_ vsockConnection: VZVsockSocket) {
        // TODO: Implement TCP bridge
        // For now, log the connection attempt
        logger.info("New vsock connection from CID: \(vsockConnection.destinationPort)")
        
        let connection = VsockConnection(vsock: vsockConnection, relay: self)
        activeConnections.insert(connection)
    }
}

/// Represents an active vsock connection
private final class VsockConnection: Hashable {
    let vsock: VZVsockSocket
    weak var relay: VsockRelay?
    
    init(vsock: VZVsockSocket, relay: VsockRelay) {
        self.vsock = vsock
        self.relay = relay
    }
    
    func cancel() {
        vsock.close()
    }
    
    // Hashable conformance
    static func == (lhs: VsockConnection, rhs: VsockConnection) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
