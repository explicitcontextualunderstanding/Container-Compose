import Foundation
import os.log

// MARK: - Network Trace Observability (Plan 77 Phase 3)

/// Network trace event types for vsock and UDS channels
public enum TraceEvent: Sendable {
    case connectionAttempt(cid: UInt32, port: UInt32, authorized: Bool)
    case connectionEstablished(relayId: String, connectionId: UUID, transport: RelayTransport)
    case dataTransfer(relayId: String, connectionId: UUID, bytes: Int, direction: DataDirection, timestamp: Date)
    case connectionClosed(relayId: String, connectionId: UUID, reason: String)
    case unauthorizedAttempt(relayId: String, attemptedCID: UInt32, expectedCID: UInt32?)
    case securityEvent(relayId: String, event: SecurityEvent)
    
    public enum DataDirection: String, Sendable {
        case inbound = "IN"
        case outbound = "OUT"
    }
    
    public enum SecurityEvent: String, Sendable {
        case cidMismatch
        case pidVerificationFailed
        case unauthorizedConnection
        case malformedPacket
    }
}

/// Real-time network trace for monitoring vsock channels
public actor NetworkTrace {
    private var events: [TraceEvent] = []
    private let maxEvents: Int
    private let logger = Logger(subsystem: "com.container-compose.trace", category: "NetworkTrace")
    
    public init(maxEvents: Int = 10000) {
        self.maxEvents = maxEvents
    }
    
    /// Record a trace event
    public func record(_ event: TraceEvent) {
        events.append(event)
        
        // Trim old events if over limit
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        
        // Log to system
        logEvent(event)
    }
    
    /// Get recent events with optional filtering
    func recentEvents(limit: Int = 100, filter: ((TraceEvent) -> Bool)? = nil) -> [TraceEvent] {
        let filtered = filter.map { events.filter($0) } ?? events
        return Array(filtered.suffix(limit))
    }
    
    /// Get events for a specific relay
    func eventsForRelay(_ relayId: String) -> [TraceEvent] {
        events.filter { event in
            switch event {
            case .connectionEstablished(let id, _, _): return id == relayId
            case .dataTransfer(let id, _, _, _, _): return id == relayId
            case .connectionClosed(let id, _, _): return id == relayId
            case .unauthorizedAttempt(let id, _, _): return id == relayId
            case .securityEvent(let id, _): return id == relayId
            default: return false
            }
        }
    }
    
    /// Get security-related events only
    func securityEvents() -> [TraceEvent] {
        events.filter { event in
            switch event {
            case .unauthorizedAttempt, .securityEvent:
                return true
            case .connectionAttempt(_, _, let authorized):
                return !authorized
            default:
                return false
            }
        }
    }
    
    /// Export trace as JSON for external analysis
    func exportJSON() throws -> Data {
        let traceData = events.map { event -> [String: Any] in
            switch event {
            case .connectionAttempt(let cid, let port, let authorized):
                return [
                    "type": "connectionAttempt",
                    "cid": cid,
                    "port": port,
                    "authorized": authorized,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            case .connectionEstablished(let relayId, let connectionId, let transport):
                return [
                    "type": "connectionEstablished",
                    "relayId": relayId,
                    "connectionId": connectionId.uuidString,
                    "transport": transport.description,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            case .dataTransfer(let relayId, let connectionId, let bytes, let direction, let timestamp):
                return [
                    "type": "dataTransfer",
                    "relayId": relayId,
                    "connectionId": connectionId.uuidString,
                    "bytes": bytes,
                    "direction": direction.rawValue,
                    "timestamp": ISO8601DateFormatter().string(from: timestamp)
                ]
            case .connectionClosed(let relayId, let connectionId, let reason):
                return [
                    "type": "connectionClosed",
                    "relayId": relayId,
                    "connectionId": connectionId.uuidString,
                    "reason": reason,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            case .unauthorizedAttempt(let relayId, let attemptedCID, let expectedCID):
                return [
                    "type": "unauthorizedAttempt",
                    "relayId": relayId,
                    "attemptedCID": attemptedCID,
                    "expectedCID": expectedCID ?? 0,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            case .securityEvent(let relayId, let event):
                return [
                    "type": "securityEvent",
                    "relayId": relayId,
                    "event": event.rawValue,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            }
        }
        
        return try JSONSerialization.data(withJSONObject: traceData, options: .prettyPrinted)
    }
    
    // MARK: - Private
    
    private func logEvent(_ event: TraceEvent) {
        switch event {
        case .connectionAttempt(let cid, let port, let authorized):
            logger.info("TRACE: Connection attempt - CID:\(cid), Port:\(port), Authorized:\(authorized)")
            
        case .connectionEstablished(let relayId, let connectionId, let transport):
            logger.info("TRACE: Connection established - Relay:\(relayId), ID:\(connectionId), Transport:\(transport.description)")
            
        case .dataTransfer(let relayId, _, let bytes, let direction, _):
            logger.debug("TRACE: Data transfer - Relay:\(relayId), Bytes:\(bytes), Dir:\(direction.rawValue)")
            
        case .connectionClosed(let relayId, _, let reason):
            logger.info("TRACE: Connection closed - Relay:\(relayId), Reason:\(reason)")
            
        case .unauthorizedAttempt(let relayId, let attemptedCID, let expectedCID):
            logger.warning("TRACE: Unauthorized attempt - Relay:\(relayId), CID:\(attemptedCID), Expected:\(expectedCID ?? 0)")
            
        case .securityEvent(let relayId, let event):
            logger.error("TRACE: Security event - Relay:\(relayId), Event:\(event.rawValue)")
        }
    }
}

// MARK: - Hex Dump Utility

extension NetworkTrace {
    /// Generate hex dump of data for debugging
    static func hexDump(_ data: Data, prefix: String = "") -> String {
        var output = prefix.isEmpty ? "" : "\(prefix)\n"
        
        let bytes = data.map { String(format: "%02x", $0) }
        for (index, chunk) in bytes.chunked(into: 16).enumerated() {
            let offset = String(format: "%08x", index * 16)
            output += "\(offset)  \(chunk.joined(separator: " "))\n"
        }
        
        return output
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
