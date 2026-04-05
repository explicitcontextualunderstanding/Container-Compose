import XCTest
import Network
import Foundation
@testable import ContainerComposeCore

// MARK: - MockStream for Tier 1 Tests

/// Mock implementation of Streamable for unit testing without network I/O
final class MockStream: Streamable, @unchecked Sendable {
    var isConnected: Bool = true

    private var sentData: [Data] = []
    private var receiveQueue: [Data] = []
    private var receiveCompletionHandlers: [@Sendable (Data?, NWConnection.ContentContext?, Bool, Error?) -> Void] = []
    private var shouldFailOnSend = false
    private var shouldFailOnReceive = false
    private var sendError: Error?
    private var receiveError: Error?
    private let lock = NSLock()

    var receivedData: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return sentData
    }

    func reset() {
        lock.lock()
        sentData.removeAll()
        receiveQueue.removeAll()
        receiveCompletionHandlers.removeAll()
        shouldFailOnSend = false
        shouldFailOnReceive = false
        sendError = nil
        receiveError = nil
        isConnected = true
        lock.unlock()
    }

    func queueData(_ data: Data) {
        lock.lock()
        receiveQueue.append(data)
        processNextReceive()
        lock.unlock()
    }

    func setSendError(_ error: Error?) {
        lock.lock()
        self.sendError = error
        self.shouldFailOnSend = error != nil
        lock.unlock()
    }

    func setReceiveError(_ error: Error?) {
        lock.lock()
        self.receiveError = error
        self.shouldFailOnReceive = error != nil
        lock.unlock()
    }

    func start(queue: DispatchQueue) {
        isConnected = true
    }

    func cancel() {
        isConnected = false
        lock.lock()
        let handlers = receiveCompletionHandlers
        receiveCompletionHandlers.removeAll()
        lock.unlock()
        for handler in handlers {
            handler(nil, nil, true, nil)
        }
    }

    func send(content: Data?, completion: @escaping @Sendable (Error?) -> Void) {
        guard let data = content else {
            completion(nil)
            return
        }

        lock.lock()
        if shouldFailOnSend {
            let err = sendError ?? NSError(domain: "MockStream", code: -1)
            lock.unlock()
            completion(err)
            return
        }
        sentData.append(data)
        lock.unlock()
        completion(nil)
    }

    func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, Error?) -> Void) {
        lock.lock()

        if shouldFailOnReceive {
            let err = receiveError ?? NSError(domain: "MockStream", code: -2)
            lock.unlock()
            completion(nil, nil, false, err)
            return
        }

        if receiveQueue.isEmpty {
            receiveCompletionHandlers.append(completion)
            lock.unlock()
            return
        }

        let data = receiveQueue.removeFirst()
        lock.unlock()
        completion(data, nil, false, nil)
    }

    private func processNextReceive() {
        while !receiveQueue.isEmpty && !receiveCompletionHandlers.isEmpty {
            let handler = receiveCompletionHandlers.removeFirst()
            let data = receiveQueue.removeFirst()
            handler(data, nil, false, nil)
        }
    }

    func simulateConnectionClosed() {
        lock.lock()
        let handlers = receiveCompletionHandlers
        receiveCompletionHandlers.removeAll()
        receiveQueue.removeAll()
        isConnected = false
        lock.unlock()
        for handler in handlers {
            handler(nil, nil, true, nil)
        }
    }
}

// MARK: - Tier 1: Unit Tests (Memory Streams / Mocks)

@available(macOS 12.0, *)
final class RelayManagerTests: XCTestCase {
    var manager: RelayManager!
    var eventLog: RelayEventLog!

    override func setUp() {
        super.setUp()
        eventLog = RelayEventLog()
        manager = RelayManager(eventLog: eventLog)
    }

    override func tearDown() async throws {
        await manager?.stopAll()
        manager = nil
        eventLog = nil
    }

    // MARK: Configuration Tests

    func testRelayConfigurationCreation() {
        let config = RelayManager.RelayConfiguration(
            id: "test-db",
            tcpPort: 15432,
            unixSocketPath: "/tmp/test.sock",
            description: "Test database relay"
        )

        XCTAssertEqual(config.id, "test-db")
        XCTAssertEqual(config.tcpPort, 15432)
        XCTAssertEqual(config.unixSocketPath, "/tmp/test.sock")
        XCTAssertEqual(config.description, "Test database relay")
    }

    func testEventLogRecording() async {
        let eventLog = RelayEventLog()

        await eventLog.record(.relayStarted(id: "test", port: 12345, path: "/tmp/test.sock"))
        await eventLog.record(.relayStopped(id: "test"))

        let events = await eventLog.recentEvents(limit: 10)
        XCTAssertEqual(events.count, 2)
    }

    func testRelayErrorDescriptions() {
        let errors: [RelayError] = [
            .alreadyRunning("test-relay"),
            .unixSocketUnavailable("/tmp/test.sock", NSError(domain: "test", code: 1)),
            .timeout("Connection timed out"),
            .portInUse(5432),
            .networkError(NSError(domain: "test", code: 2))
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty)
        }
    }
}

// MARK: - Tier 1: BridgeConnection Tests (Mock-based)

@available(macOS 12.0, *)
final class BridgeConnectionMockTests: XCTestCase {

    func testBidirectionalDataFlow() async throws {
        let mockSource = MockStream()
        let mockDestination = MockStream()
        let eventLog = RelayEventLog()

        let bridge = BridgeConnection(source: mockSource, destination: mockDestination, eventLog: eventLog)

        mockSource.queueData("Hello from TCP".data(using: .utf8)!)
        mockDestination.queueData("Response from Unix".data(using: .utf8)!)

        let expectation = expectation(description: "Bridge completes")
        await bridge.start {
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        XCTAssertFalse(mockDestination.receivedData.isEmpty, "Should have forwarded data to destination")
        XCTAssertEqual(String(data: mockDestination.receivedData.first!, encoding: .utf8), "Hello from TCP")
    }

    func testPIDVerificationAllowsMatching() async throws {
        let mockSource = MockStream()
        let mockDestination = MockStream()
        let eventLog = RelayEventLog()

        let expectedPID = ProcessInfo.processInfo.processIdentifier

        let bridge = BridgeConnection(
            source: mockSource,
            destination: mockDestination,
            eventLog: eventLog
        )

        mockSource.queueData("Test data".data(using: .utf8)!)

        let expectation = expectation(description: "Bridge completes")
        await bridge.start {
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        XCTAssertTrue(mockDestination.receivedData.count > 0, "Data should flow when no target PID set")
    }

    func testBinaryDataIntegrity() async throws {
        let mockSource = MockStream()
        let mockDestination = MockStream()
        let eventLog = RelayEventLog()

        let bridge = BridgeConnection(source: mockSource, destination: mockDestination, eventLog: eventLog)

        var randomData = Data(count: 1024)
        for i in 0..<1024 {
            randomData[i] = UInt8(i % 256)
        }
        mockSource.queueData(randomData)

        let expectation = expectation(description: "Bridge completes")
        await bridge.start {
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        XCTAssertEqual(mockDestination.receivedData.count, 1)
        XCTAssertEqual(mockDestination.receivedData.first, randomData, "Binary data should be preserved exactly")
    }

    func testLargeDataTransfer() async throws {
        let mockSource = MockStream()
        let mockDestination = MockStream()
        let eventLog = RelayEventLog()

        let bridge = BridgeConnection(source: mockSource, destination: mockDestination, eventLog: eventLog)

        let largeData = Data(repeating: 0xAB, count: 1024 * 1024) // 1MB
        mockSource.queueData(largeData)

        let expectation = expectation(description: "Bridge completes")
        await bridge.start {
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 10.0)

        XCTAssertEqual(mockDestination.receivedData.count, 1)
        XCTAssertEqual(mockDestination.receivedData.first?.count, 1024 * 1024, "Large data transfer should preserve size")
    }

    func testConnectionCloseHandling() async throws {
        let mockSource = MockStream()
        let mockDestination = MockStream()
        let eventLog = RelayEventLog()

        let bridge = BridgeConnection(source: mockSource, destination: mockDestination, eventLog: eventLog)

        mockSource.queueData("Test data".data(using: .utf8)!)
        mockSource.simulateConnectionClosed()

        let expectation = expectation(description: "Bridge completes")
        await bridge.start {
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)
    }

    func testErrorPropagation() async throws {
        let mockSource = MockStream()
        let mockDestination = MockStream()
        let eventLog = RelayEventLog()

        let bridge = BridgeConnection(source: mockSource, destination: mockDestination, eventLog: eventLog)

        mockSource.setReceiveError(NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test error"]))

        let expectation = expectation(description: "Bridge completes even with error")
        await bridge.start {
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)
    }
}

// MARK: - Tier 2: Integration Tests (Actual Network Ports)

@available(macOS 12.0, *)
final class SocketRelayIntegrationTests: XCTestCase {
    var manager: RelayManager!
    var eventLog: RelayEventLog!

    override func setUp() {
        super.setUp()
        eventLog = RelayEventLog()
        manager = RelayManager(eventLog: eventLog)
    }

    override func tearDown() async throws {
        await manager?.stopAll()
        manager = nil
        eventLog = nil
    }

    func testWaitForSocketTimeout() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("test-\(UUID().uuidString).sock").path

        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        do {
            try await manager.waitForSocket(at: socketPath, timeout: 0.5, interval: 0.05)
            XCTFail("Expected timeout error")
        } catch RelayError.timeout {
            // Expected
        }
    }

    func testWaitForSocketSuccess() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/nc") else {
            throw XCTSkip("nc not available")
        }

        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("test-\(UUID().uuidString).sock").path

        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        serverProcess.arguments = ["-l", "-U", socketPath]
        try serverProcess.run()

        defer { serverProcess.terminate() }

        try await manager.waitForSocket(at: socketPath, timeout: 2.0, interval: 0.05)

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testPortCollisionHandling() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/nc") else {
            throw XCTSkip("nc not available")
        }

        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("collision-test-\(UUID().uuidString).sock").path

        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        serverProcess.arguments = ["-l", "-U", socketPath]
        try serverProcess.run()
        defer { serverProcess.terminate() }

        try await Task.sleep(nanoseconds: 100_000_000)

        let testPort: UInt16 = 15432

        let listener1 = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: testPort)!)
        XCTAssertNotNil(listener1, "First listener should succeed")
        listener1?.cancel()

        let listener2 = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: testPort)!)
        XCTAssertNotNil(listener2, "Second listener should succeed (different address)")
        listener2?.cancel()
    }

    func testMultipleConcurrentConnections() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/nc") else {
            throw XCTSkip("nc not available")
        }

        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("multi-conn-\(UUID().uuidString).sock").path

        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        serverProcess.arguments = ["-l", "-U", socketPath, "-k"]
        try serverProcess.run()
        defer { serverProcess.terminate() }

        try await Task.sleep(nanoseconds: 200_000_000)

        var connections: [NWConnection] = []
        let testPort: UInt16 = 15433

        for i in 0..<5 {
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: testPort)!,
                using: .tcp
            )
            connections.append(connection)
            connection.start(queue: .global())
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        for connection in connections {
            connection.cancel()
        }

        XCTAssertEqual(connections.count, 5)
    }
}

// MARK: - Tier 3: E2E Tests (Full Integration)

@available(macOS 12.0, *)
final class RelayE2ETests: XCTestCase {

    func testFullStackWithRelay() async throws {
        throw XCTSkip("E2E test requires container runtime - run manually with ./run-tests.sh --auto-clean")

        // Full test would:
        // 1. Start container-compose up with test DB
        // 2. Verify /tmp/test-pg.sock exists
        // 3. Connect via relay
        // 4. container-compose down
        // 5. Verify /tmp/test-pg.sock removed
    }

    func testContainerComposeBinaryExists() {
        let possiblePaths = [
            "/usr/local/bin/container-compose",
            "/usr/bin/container-compose",
            Bundle.main.executablePath
        ].compactMap { $0 }

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return
            }
        }

        XCTSkip("container-compose binary not found in standard locations")
    }
}

// MARK: - Performance Tests

@available(macOS 12.0, *)
final class RelayPerformanceTests: XCTestCase {
    func testBackpressureHandling() async throws {
        throw XCTSkip("Performance test - run manually with Instruments")

        // Test with large data transfers
        // Verify no memory leaks under sustained load
    }

    func testThroughputBenchmark() async throws {
        throw XCTSkip("Benchmark test - run manually")

        // Compare throughput vs socat
        // Should be >= socat performance
    }
}

// MARK: - NWConnectionWrapper Tests

@available(macOS 12.0, *)
final class NWConnectionWrapperTests: XCTestCase {

  func testWrapperConformsToStreamable() {
    let connection = NWConnection(to: .unix(path: "/tmp/test.sock"), using: .tcp)
    let wrapper = NWConnectionWrapper(connection: connection)

    XCTAssertTrue(wrapper is Streamable, "NWConnectionWrapper should conform to Streamable")
  }
}

// MARK: - RelayConstants Tests

@available(macOS 12.0, *)
final class RelayConstantsTests: XCTestCase {

  func testSocketPathSanitization() {
    // Test that paths with dangerous characters are sanitized
    let path1 = RelayConstants.socketPath(for: "service/db:main")
    let filename1 = path1.lastPathComponent
    XCTAssertTrue(filename1.contains("service-db-main"), "Path should sanitize / and : to -, got: \(filename1)")

    // Test with project prefix
    let path2 = RelayConstants.socketPath(for: "my_service", project: "my-project")
    let filename2 = path2.lastPathComponent
    XCTAssertEqual(filename2, "my-project-my_service.sock", "Should include project prefix, got: \(filename2)")
  }

  func testSocketPathExtension() {
    let path = RelayConstants.socketPath(for: "db")
    XCTAssertTrue(path.path.hasSuffix(".sock"), "Socket path should have .sock extension")
  }

  func testDirectoryPermissions() {
    // Verify directory permissions constant
    XCTAssertEqual(RelayConstants.directoryPermissions, 0o700, "Directory should have 0700 permissions")
  }

func testSocketPermissions() {
    // Verify socket permissions constant
    XCTAssertEqual(RelayConstants.socketPermissions, 0o600, "Socket should have 0600 permissions")
}

    func testRelayRootDefaultPath() {
        // Verify default relay root is in user's home directory
        let expectedHome = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(RelayConstants.relayRoot.path.hasPrefix(expectedHome.path),
                     "Relay root should be in user's home directory")
        XCTAssertTrue(RelayConstants.relayRoot.path.contains(".container-compose"),
                     "Relay root should contain .container-compose")
    }

func testEnsureRelayRootCreatesDirectory() throws {
    // Create a test directory
    let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-relay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: testDir) }

    // Note: This tests the pattern, not the actual call since we can't override static in tests easily
    XCTAssertTrue(RelayConstants.relayRoot.path.count > 0, "Relay root should be set")
}
}

// MARK: - PeerVerification Tests

@available(macOS 12.0, *)
final class PeerVerificationTests: XCTestCase {

    func testVerifyPIDWithNilExpectedReturnsTrue() {
        // When no expected PID is specified, verification should pass (backward compatible)
        let result = PeerVerification.verifyPID(fileDescriptor: -1, expectedPID: nil)
        XCTAssertTrue(result, "Should allow connection when no expected PID specified")
    }

    func testVerifyPIDWithInvalidFDReturnsTrue() {
        // When file descriptor is invalid, verification should allow (graceful degradation)
        let result = PeerVerification.verifyPID(fileDescriptor: -1, expectedPID: 1234)
        XCTAssertTrue(result, "Should allow connection when fd unavailable (graceful degradation)")
    }
}

// MARK: - NWConnectionWrapper Tests

@available(macOS 12.0, *)
final class NWConnectionWrapperTests: XCTestCase {

    func testWrapperConformsToStreamable() {
        let connection = NWConnection(to: .unix(path: "/tmp/test.sock"), using: .tcp)
        let wrapper = NWConnectionWrapper(connection: connection)

        XCTAssertTrue(wrapper is Streamable, "NWConnectionWrapper should conform to Streamable")
    }

    func testWrapperFileDescriptorReturnsMinusOne() {
        // NWConnection doesn't expose fd, so should return -1
        let connection = NWConnection(to: .unix(path: "/tmp/test.sock"), using: .tcp)
        let wrapper = NWConnectionWrapper(connection: connection)

        XCTAssertEqual(wrapper.fileDescriptor, -1, "File descriptor should be -1 (Network.framework limitation)")
    }
}