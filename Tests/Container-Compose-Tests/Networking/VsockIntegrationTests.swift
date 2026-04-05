import XCTest
@testable import Container_Compose

final class VsockIntegrationTests: XCTestCase {
    
    // MARK: - VsockRelay Tests
    
    func testVsockRelayInitialization() async throws {
        let eventLog = RelayEventLog()
        let relay = try await VsockRelay(
            tcpPort: 5432,
            vsockCid: 3,
            vsockPort: 5432,
            eventLog: eventLog
        )
        
        XCTAssertEqual(relay.tcpPort, 5432)
        XCTAssertEqual(relay.vsockCid, 3)
        XCTAssertEqual(relay.vsockPort, 5432)
        XCTAssertFalse(relay.isRunning)
        XCTAssertEqual(relay.unixSocketPath, "")
    }
    
    func testVsockTransportType() async throws {
        let eventLog = RelayEventLog()
        let relay = try await VsockRelay(
            tcpPort: 9000,
            vsockCid: 10,
            vsockPort: 9000,
            eventLog: eventLog
        )
        
        if case .vsock(let cid, let port) = relay.transportType {
            XCTAssertEqual(cid, 10)
            XCTAssertEqual(port, 9000)
        } else {
            XCTFail("Expected vsock transport type")
        }
    }
    
    // MARK: - NetworkTrace Tests
    
    func testNetworkTraceEventRecording() async {
        let trace = NetworkTrace()
        
        let event = TraceEvent.connectionAttempt(cid: 3, port: 5432, authorized: true)
        await trace.record(event)
        
        let events = await trace.recentEvents(limit: 10)
        XCTAssertEqual(events.count, 1)
    }
    
    func testNetworkTraceSecurityEvents() async {
        let trace = NetworkTrace()
        
        // Record security events
        await trace.record(.unauthorizedAttempt(relayId: "test", attemptedCID: 5, expectedCID: 3))
        await trace.record(.securityEvent(relayId: "test", event: .cidMismatch))
        await trace.record(.connectionAttempt(cid: 3, port: 5432, authorized: true))
        
        let securityEvents = await trace.securityEvents()
        XCTAssertEqual(securityEvents.count, 2)
    }
    
    func testNetworkTraceJSONExport() async throws {
        let trace = NetworkTrace()
        
        await trace.record(.connectionEstablished(
            relayId: "test-relay",
            connectionId: UUID(),
            transport: .vsock(cid: 3, port: 5432)
        ))
        
        let jsonData = try await trace.exportJSON()
        XCTAssertTrue(jsonData.count > 0)
        
        let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
        XCTAssertNotNil(jsonObject)
        XCTAssertEqual(jsonObject?.count, 1)
    }
    
    func testNetworkTraceHexDump() {
        let data = Data([0x48, 0x65, 0x6c, 0x6c, 0x6f]) // "Hello"
        let hexDump = NetworkTrace.hexDump(data, prefix: "Test")
        
        XCTAssertTrue(hexDump.contains("Test"))
        XCTAssertTrue(hexDump.contains("48 65 6c 6c 6f"))
    }
    
    // MARK: - Integration Tests
    
    func testRelayManagerWithVsockTransport() async throws {
        let manager = RelayManager()
        
        let config = RelayConfiguration(
            id: "test-vsock",
            tcpPort: 5432,
            transport: .vsock(cid: 3, port: 5432),
            description: "Test vsock relay"
        )
        
        // Note: This will fail without actual Virtualization.framework support
        // but we're testing the configuration path
        do {
            try await manager.startRelay(config)
            // If we get here, vsock is supported
            let status = await manager.getRelayStatus(id: "test-vsock")
            XCTAssertNotNil(status)
        } catch {
            // Expected on systems without vsock support
            XCTAssertTrue(error is RelayError)
        }
    }
}
