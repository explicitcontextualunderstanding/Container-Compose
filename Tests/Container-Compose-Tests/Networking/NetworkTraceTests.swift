import XCTest
@testable import ContainerComposeCore

// MARK: - Network Trace Tests (Plan 77 Phase 3)

final class NetworkTraceTests: XCTestCase {
    
    var trace: NetworkTrace!
    
    override func setUp() {
        super.setUp()
        trace = NetworkTrace()
    }
    
    override func tearDown() {
        trace = nil
        super.tearDown()
    }
    
    // MARK: - Event Recording Tests
    
    func testRecordsConnectionAttempt() async {
        let event = TraceEvent.connectionAttempt(cid: 3, port: 5001, authorized: true)
        await trace.record(event)
        
        let events = await trace.getAllEvents()
        XCTAssertEqual(events.count, 1)
        
        if case .connectionAttempt(let cid, let port, let auth) = events[0] {
            XCTAssertEqual(cid, 3)
            XCTAssertEqual(port, 5001)
            XCTAssertTrue(auth)
        } else {
            XCTFail("Wrong event type")
        }
    }
    
    func testRecordsDataTransfer() async {
        let event = TraceEvent.dataTransfer(cid: 3, bytes: 1024, direction: .inbound)
        await trace.record(event)
        
        let events = await trace.getAllEvents()
        XCTAssertEqual(events.count, 1)
        
        if case .dataTransfer(let cid, let bytes, let dir) = events[0] {
            XCTAssertEqual(cid, 3)
            XCTAssertEqual(bytes, 1024)
            XCTAssertEqual(dir, .inbound)
        } else {
            XCTFail("Wrong event type")
        }
    }
    
    func testRecordsConnectionClosed() async {
        let event = TraceEvent.connectionClosed(cid: 3, reason: "Normal shutdown")
        await trace.record(event)
        
        let events = await trace.getAllEvents()
        XCTAssertEqual(events.count, 1)
        
        if case .connectionClosed(let cid, let reason) = events[0] {
            XCTAssertEqual(cid, 3)
            XCTAssertEqual(reason, "Normal shutdown")
        } else {
            XCTFail("Wrong event type")
        }
    }
    
    // MARK: - Filtering Tests
    
    func testFiltersByCID() async {
        // Record events from multiple CIDs
        await trace.record(.connectionAttempt(cid: 3, port: 5001, authorized: true))
        await trace.record(.connectionAttempt(cid: 5, port: 5002, authorized: false))
        await trace.record(.dataTransfer(cid: 3, bytes: 512, direction: .outbound))
        await trace.record(.connectionClosed(cid: 5, reason: "Timeout"))
        
        // Filter by CID 3
        let cid3Events = await trace.getEvents(forCID: 3)
        XCTAssertEqual(cid3Events.count, 2)
        
        // Verify all are from CID 3
        for event in cid3Events {
            switch event {
            case .connectionAttempt(let cid, _, _):
                XCTAssertEqual(cid, 3)
            case .dataTransfer(let cid, _, _):
                XCTAssertEqual(cid, 3)
            case .connectionClosed(let cid, _):
                XCTAssertEqual(cid, 3)
            }
        }
    }
    
    func testFiltersByPort() async {
        await trace.record(.connectionAttempt(cid: 3, port: 5001, authorized: true))
        await trace.record(.connectionAttempt(cid: 5, port: 5002, authorized: true))
        await trace.record(.dataTransfer(cid: 3, bytes: 256, direction: .inbound))
        
        let port5001Events = await trace.getEvents(forPort: 5001)
        XCTAssertEqual(port5001Events.count, 1)
    }
    
    // MARK: - JSON Export Tests
    
    func testExportsToJSON() async throws {
        await trace.record(.connectionAttempt(cid: 3, port: 5001, authorized: true))
        await trace.record(.dataTransfer(cid: 3, bytes: 1024, direction: .inbound))
        
        let jsonData = try await trace.exportJSON()
        let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
        
        XCTAssertNotNil(jsonObject)
        XCTAssertEqual(jsonObject?.count, 2)
    }
    
    func testJSONContainsRequiredFields() async throws {
        await trace.record(.connectionAttempt(cid: 3, port: 5001, authorized: true))
        
        let jsonData = try await trace.exportJSON()
        let jsonArray = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
        
        guard let event = jsonArray?.first else {
            XCTFail("No events exported")
            return
        }
        
        XCTAssertNotNil(event["type"])
        XCTAssertNotNil(event["timestamp"])
        XCTAssertNotNil(event["cid"])
    }
    
    // MARK: - Hex Dump Tests
    
    func testGeneratesHexDump() async {
        let data = Data([0x48, 0x65, 0x6c, 0x6c, 0x6f]) // "Hello"
        let hexDump = trace.hexDump(data)
        
        XCTAssertTrue(hexDump.contains("48 65 6c 6c 6f"))
        XCTAssertTrue(hexDump.contains("Hello"))
    }
    
    func testHexDumpHandlesEmptyData() {
        let hexDump = trace.hexDump(Data())
        XCTAssertEqual(hexDump, "(empty)")
    }
    
    // MARK: - Performance Tests
    
    func testHandlesHighVolumeEvents() async {
        // Record 1000 events
        for i in 0..<1000 {
            await trace.record(.dataTransfer(cid: 3, bytes: i * 100, direction: .inbound))
        }
        
        let events = await trace.getAllEvents()
        XCTAssertEqual(events.count, 1000)
    }
}
