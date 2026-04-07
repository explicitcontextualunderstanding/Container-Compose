import XCTest
@testable import ContainerComposeCore

// MARK: - Network Trace Tests (Plan 77 Phase 3)

final class NetworkTraceTests: XCTestCase {

  var trace: NetworkTrace!
  let testRelayId = "test-relay"
  let testConnectionId = UUID()

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

    let events = await trace.recentEvents(limit: 100)
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
    let event = TraceEvent.dataTransfer(
      relayId: testRelayId,
      connectionId: testConnectionId,
      bytes: 1024,
      direction: .inbound,
      timestamp: Date()
    )
    await trace.record(event)

    let events = await trace.recentEvents(limit: 100)
    XCTAssertEqual(events.count, 1)

    if case .dataTransfer(let relayId, _, let bytes, let dir, _) = events[0] {
      XCTAssertEqual(relayId, testRelayId)
      XCTAssertEqual(bytes, 1024)
      XCTAssertEqual(dir, .inbound)
    } else {
      XCTFail("Wrong event type")
    }
  }

  func testRecordsConnectionEstablished() async {
    let event = TraceEvent.connectionEstablished(
      relayId: testRelayId,
      connectionId: testConnectionId,
      transport: .vsock(cid: 3, port: 5001)
    )
    await trace.record(event)

    let events = await trace.eventsForRelay(testRelayId)
    XCTAssertEqual(events.count, 1)
  }

  func testRecordsConnectionClosed() async {
    let event = TraceEvent.connectionClosed(
      relayId: testRelayId,
      connectionId: testConnectionId,
      reason: "normal"
    )
    await trace.record(event)

    let events = await trace.eventsForRelay(testRelayId)
    XCTAssertEqual(events.count, 1)
  }

  // MARK: - Event Filtering Tests

  func testFiltersEventsByRelay() async {
    // Record events for different relays
    let relay1 = "relay-1"
    let relay2 = "relay-2"

    await trace.record(.connectionEstablished(
      relayId: relay1,
      connectionId: UUID(),
      transport: .vsock(cid: 3, port: 5001)
    ))
    await trace.record(.dataTransfer(
      relayId: relay2,
      connectionId: UUID(),
      bytes: 512,
      direction: .outbound,
      timestamp: Date()
    ))

    let relay1Events = await trace.eventsForRelay(relay1)
    XCTAssertEqual(relay1Events.count, 1)

    let relay2Events = await trace.eventsForRelay(relay2)
    XCTAssertEqual(relay2Events.count, 1)
  }

  func testFiltersSecurityEvents() async {
    await trace.record(.securityEvent(relayId: testRelayId, event: .unauthorizedConnection))
    await trace.record(.connectionAttempt(cid: 3, port: 5001, authorized: false))
    await trace.record(.connectionEstablished(
      relayId: testRelayId,
      connectionId: testConnectionId,
      transport: .vsock(cid: 3, port: 5001)
    ))

    let securityEvents = await trace.securityEvents()
    XCTAssertEqual(securityEvents.count, 2) // securityEvent + unauthorized attempt
  }

  func testRecentEventsLimitsResults() async {
    // Record 10 events
    for i in 0..<10 {
      await trace.record(.connectionAttempt(cid: UInt32(i), port: 5000 + UInt32(i), authorized: true))
    }

    let recent = await trace.recentEvents(limit: 5)
    XCTAssertEqual(recent.count, 5)
  }

  // MARK: - Event Trimming Tests

  func testTrimsOldEventsWhenLimitExceeded() async {
    let smallTrace = NetworkTrace(maxEvents: 5)

    // Record 10 events
    for i in 0..<10 {
      await smallTrace.record(.connectionAttempt(cid: UInt32(i), port: 5000, authorized: true))
    }

    let events = await smallTrace.recentEvents(limit: 100)
    XCTAssertEqual(events.count, 5)

    // Verify we kept the most recent events
    if case .connectionAttempt(let cid, _, _) = events.last! {
      XCTAssertEqual(cid, 9)
    } else {
      XCTFail("Wrong event type")
    }
  }

  // MARK: - JSON Export Tests

  func testExportsJSON() async throws {
    await trace.record(.connectionAttempt(cid: 3, port: 5001, authorized: true))
    await trace.record(.dataTransfer(
      relayId: testRelayId,
      connectionId: testConnectionId,
      bytes: 1024,
      direction: .inbound,
      timestamp: Date()
    ))

    let jsonData = try await trace.exportJSON()
    let json = try JSONSerialization.jsonObject(with: jsonData) as! [[String: Any]]

    XCTAssertEqual(json.count, 2)
    XCTAssertEqual(json[0]["type"] as? String, "connectionAttempt")
    XCTAssertEqual(json[1]["type"] as? String, "dataTransfer")
  }

  // MARK: - Hex Dump Tests

func testGeneratesHexDump() async {
    let data = Data([0x48, 0x65, 0x6c, 0x6c, 0x6f]) // "Hello"
    let hexDump = NetworkTrace.hexDump(data)

    XCTAssertTrue(hexDump.contains("48 65 6c 6c 6f"))
}

  func testHexDumpHandlesEmptyData() {
    let hexDump = NetworkTrace.hexDump(Data())
    XCTAssertEqual(hexDump, "(empty)")
  }

  // MARK: - Performance Tests

  func testHandlesHighVolumeEvents() async {
    // Record 1000 events
    for i in 0..<1000 {
      await trace.record(.dataTransfer(
        relayId: testRelayId,
        connectionId: UUID(),
        bytes: i * 100,
        direction: .inbound,
        timestamp: Date()
      ))
    }

    let events = await trace.recentEvents(limit: 1000)
    XCTAssertEqual(events.count, 1000)
  }
}
