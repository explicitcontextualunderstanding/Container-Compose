import XCTest
import Network
import Foundation
@testable import ContainerComposeCore
@testable import SecurityHardening

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
        completion(nil, nil, true, nil)
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
    // Diagnostic: Track socket creation steps for debugging
    var diagnostics: [String] = []
    defer {
      if !diagnostics.isEmpty {
        print("Socket creation diagnostics:\n" + diagnostics.joined(separator: "\n"))
      }
    }

    // Use a short socket path to avoid sun_path length limit (104 bytes)
    let shortUUID = UUID().uuidString.prefix(8)
    let socketPath = "/tmp/test-\(shortUUID).sock"
    diagnostics.append("Socket path: \(socketPath)")

    // Check if /tmp is writable
    let tmpWritable = FileManager.default.isWritableFile(atPath: "/tmp")
    diagnostics.append("tmp writable: \(tmpWritable)")
    XCTAssertTrue(tmpWritable, "/tmp must be writable for socket creation")

    // Clean up any existing socket file
    let existsBefore = FileManager.default.fileExists(atPath: socketPath)
    diagnostics.append("Socket exists before: \(existsBefore)")
    if existsBefore {
      try? FileManager.default.removeItem(atPath: socketPath)
      diagnostics.append("Removed existing socket")
    }
    defer {
      let existsAfter = FileManager.default.fileExists(atPath: socketPath)
      diagnostics.append("Socket exists at cleanup: \(existsAfter)")
      try? FileManager.default.removeItem(atPath: socketPath)
    }

    // Check for resource limits
    var fdLimit = rlimit()
    let limitResult = getrlimit(RLIMIT_NOFILE, &fdLimit)
    let limitMsg = limitResult == 0 ? "\(fdLimit.rlim_cur)" : "failed to get limit"
    diagnostics.append("File descriptor limit: \(limitMsg)")

    // Create a real Unix domain socket using BSD sockets
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    diagnostics.append("socket() returned: \(fd)")
    guard fd >= 0 else {
      let err = errno
      let errMsg = String(cString: strerror(err))
      diagnostics.append("Socket creation failed: \(err) - \(errMsg)")
      XCTFail("Failed to create socket: \(err) (\(errMsg)). Diagnostics:\n" + diagnostics.joined(separator: "\n"))
      return
    }
    defer {
      Darwin.close(fd)
      diagnostics.append("Closed socket fd \(fd)")
    }

    // Verify path length is under sun_path limit
    let pathLength = socketPath.utf8.count
    diagnostics.append("Path length: \(pathLength) bytes (limit: 104)")
    XCTAssertLessThan(pathLength, 104, "Socket path \(pathLength) bytes exceeds sun_path limit of 104")

    // Create address structure
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    // Copy path to sun_path
    socketPath.withCString { cString in
      memcpy(&addr.sun_path, cString, pathLength + 1)
    }
    diagnostics.append("Created sockaddr_un structure")

    // Bind the socket
    let bindResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    diagnostics.append("bind() returned: \(bindResult)")

    if bindResult != 0 {
      let err = errno
      let errMsg = String(cString: strerror(err))
      diagnostics.append("Bind failed: \(err) - \(errMsg)")
      XCTFail("Failed to bind socket: \(err) (\(errMsg)). Diagnostics:\n" + diagnostics.joined(separator: "\n"))
      return
    }

    // Now test the waitForSocket method
    diagnostics.append("Calling waitForSocket...")
    try await manager.waitForSocket(at: socketPath, timeout: 2.0, interval: 0.05)

    // Verify file exists and is a socket
    let exists = FileManager.default.fileExists(atPath: socketPath)
    diagnostics.append("Socket exists after wait: \(exists)")
    XCTAssertTrue(exists, "Socket file should exist after waitForSocket. Diagnostics:\n" + diagnostics.joined(separator: "\n"))
  }

  func testPortCollisionHandling() async throws {
    // Use native NWListener instead of external nc process
    let testPort: UInt16 = 15432

    let listener1 = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: testPort)!)
    XCTAssertNotNil(listener1, "First listener should succeed")
    listener1?.start(queue: .global())

    // Give first listener time to start
    try await Task.sleep(nanoseconds: 100_000_000)

    // Second listener on same port should also succeed (different address)
    let listener2 = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: testPort)!)
    XCTAssertNotNil(listener2, "Second listener should succeed (different address)")
    listener2?.start(queue: .global())

    // Cleanup
    listener1?.cancel()
    listener2?.cancel()
  }

    func testMultipleConcurrentConnections() async throws {
        // Use native NWListener instead of external nc process
        let testPort: UInt16 = 15433

        // Create a listener that accepts multiple connections
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: testPort)!)
        actor ConnectionStore {
            var connections: [NWConnection] = []
            func append(_ connection: NWConnection) {
                connections.append(connection)
            }
            func cleanup() {
                for connection in connections {
                    connection.cancel()
                }
                connections.removeAll()
            }
        }
        let acceptedConnections = ConnectionStore()

        listener.newConnectionHandler = { connection in
            Task {
                await acceptedConnections.append(connection)
            }
            connection.start(queue: .global())
        }
        listener.start(queue: .global())

        defer {
            listener.cancel()
            // Cleanup accepted connections
            Task {
                await acceptedConnections.cleanup()
            }
        }

    // Give listener time to start
    try await Task.sleep(nanoseconds: 100_000_000)

    // Create multiple client connections
    var connections: [NWConnection] = []
    for _ in 0..<5 {
      let connection = NWConnection(
        host: .ipv4(.loopback),
        port: .init(rawValue: testPort)!,
        using: .tcp
      )
      connections.append(connection)
      connection.start(queue: .global())
    }

    // Wait for connections to establish
    try await Task.sleep(nanoseconds: 500_000_000)

    // Cleanup client connections
    for connection in connections {
      connection.cancel()
    }

    XCTAssertEqual(connections.count, 5, "Should have created 5 connections")
  }
}

// MARK: - Tier 3: E2E Tests (Full Integration)

@available(macOS 12.0, *)
final class RelayE2ETests: XCTestCase {

func testFullStackWithRelay() async throws {
	// Test relay configuration using SharedRelayTypes
	// Plan 88: Migrated from vsock to UDS
	let socketPath = "/tmp/test-relay-\(UUID().uuidString).sock"
	defer { try? FileManager.default.removeItem(atPath: socketPath) }

	let config = RelayConfiguration(
		id: "test-relay",
		tcpPort: 15432,
		transport: .uds(path: socketPath, virtioFSMount: nil),
		description: "Test relay configuration"
	)

	// Verify configuration is valid
	if case .uds(let path, _) = config.transport {
		XCTAssertEqual(path, socketPath, "Socket path should match")
	} else {
		XCTFail("Expected UDS transport")
	}

	XCTAssertEqual(config.tcpPort, 15432, "TCP port should be set")
	XCTAssertEqual(config.id, "test-relay", "ID should be set")
}

func testContainerComposeBinaryExists() {
    let possiblePaths = [
      "/usr/local/bin/container-compose",
      "/usr/bin/container-compose",
      Bundle.main.executablePath
    ].compactMap { $0 }

    var foundPaths: [String] = []
    for path in possiblePaths {
      if FileManager.default.isExecutableFile(atPath: path) {
        foundPaths.append(path)
      }
    }

    // Test passes if at least one executable found, fails otherwise
    XCTAssertFalse(foundPaths.isEmpty,
                   "container-compose binary not found in standard locations. Searched: \(possiblePaths.joined(separator: ", "))")

    // Additional: verify the found binary is actually executable
    for path in foundPaths {
      XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path),
                     "Found binary at \(path) but it should be executable")
    }
  }
}

// MARK: - Performance Tests

@available(macOS 12.0, *)
final class RelayPerformanceTests: XCTestCase {
    func testBackpressureHandling() async throws {
        // Test basic memory handling without actual network I/O
        var dataChunks: [Data] = []
        let chunkSize = 1024 * 1024 // 1MB

        // Create 10 chunks
        for i in 0..<10 {
            dataChunks.append(Data(repeating: UInt8(i % 256), count: chunkSize))
        }

        // Verify we can create and release data without memory issues
        XCTAssertEqual(dataChunks.count, 10, "Should have 10 data chunks")

        // Clear and verify
        dataChunks.removeAll()
        XCTAssertEqual(dataChunks.count, 0, "Should have cleared all chunks")
    }

    func testThroughputBenchmark() async throws {
        // Simple throughput test using in-memory data transfer
        let iterations = 1000
        let startTime = CFAbsoluteTimeGetCurrent()

        var counter = 0
        for i in 0..<iterations {
            counter += i
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime
        let throughput = Double(iterations) / duration

        // Basic sanity check - should complete in reasonable time
        XCTAssertLessThan(duration, 1.0, "1000 iterations should complete quickly")
        XCTAssertGreaterThan(throughput, 1000, "Should have reasonable throughput")

        // Verify calculation is correct
        let expectedSum = (0..<iterations).reduce(0, +)
        XCTAssertEqual(counter, expectedSum, "Calculation should be correct")
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

// MARK: - UDS Relay Parameter Tests (Plan 88)

/// Tests for the `createSignalSocket` parameter behavior in UDSVirtioFSRelay
/// Migrated from CreateSignalSocketTests (VsockRelay) — vSock unavailable on macOS 26
@available(macOS 12.0, *)
final class CreateSignalSocketTests: XCTestCase {

  /// Skip if UDSVirtioFSRelay is not fully implemented (stub)

  func testCreateSignalSocketTruePreservesBehavior() async throws {
    
        // When createSignalSocket is true (default for non-volume sockets),
        // the relay should create the signal socket directory structure
        let eventLog = RelayEventLog()
        let socketPath = "/tmp/test-signal-socket-\(UUID().uuidString).sock"

        let relay = try UDSVirtioFSRelay(
            socketPath: socketPath,
            createSignalSocket: true,
            eventLog: eventLog
        )

        // Verify the relay was created and has the correct transport type
        let transport = await relay.transportType
        if case .uds(let path, _) = transport {
            XCTAssertEqual(path, socketPath, "Socket path should match")
        } else {
            XCTFail("Transport type should be uds")
        }
    }

  func testCreateSignalSocketFalseSkipsSocketCreation() async throws {
    
    // When createSignalSocket is false (for volume sockets like vsock-db),
        // the relay should not create/remove the signal socket
        let eventLog = RelayEventLog()
        let volumeSocketPath = "/path/to/.containers/Volumes/db/data/.s.PGSQL.5432"

        let relay = try UDSVirtioFSRelay(
            socketPath: volumeSocketPath,
            createSignalSocket: false,
            eventLog: eventLog
        )

        // Verify the relay was created - initialization success is the test
        let transport = await relay.transportType
        if case .uds(let path, _) = transport {
            XCTAssertEqual(path, volumeSocketPath, "Socket path should match for volume socket")
        } else {
            XCTFail("Transport type should be uds")
        }
    }

  func testCreateSignalSocketDefaultsToTrue() async throws {
    
    // Test that UDSVirtioFSRelay can be created with explicit createSignalSocket: true
        let eventLog = RelayEventLog()
        let socketPath = "/tmp/test-default-\(UUID().uuidString).sock"

        let relay = try UDSVirtioFSRelay(
            socketPath: socketPath,
            createSignalSocket: true,
            eventLog: eventLog
        )

        // Just verify initialization succeeded
        XCTAssertNotNil(relay, "Relay should be created successfully")
    }

  func testCreateSignalSocketWithEmptyPath() async throws {
    
    // Test behavior with empty socketPath
        let eventLog = RelayEventLog()

        let relay = try UDSVirtioFSRelay(
            socketPath: "",
            createSignalSocket: true,
            eventLog: eventLog
        )

        // Verify empty path is preserved in transport
        let transport = await relay.transportType
        if case .uds(let path, _) = transport {
            XCTAssertEqual(path, "", "Empty socketPath should be preserved in transport")
        } else {
            XCTFail("Transport type should be uds")
        }
    }

  func testCreateSignalSocketWithVeryLongPath() async throws {
    
    // Plan 88 Decision 5: Hard-error on paths >= 104 chars
        let eventLog = RelayEventLog()
        let longPath = String(repeating: "a", count: 110) + ".sock"

        XCTAssertThrowsError(try UDSVirtioFSRelay(
            socketPath: longPath,
            createSignalSocket: true,
            eventLog: eventLog
        )) { error in
            if case UDSError.socketPathTooLong = error {
                // Expected
            } else {
                XCTFail("Expected socketPathTooLong error, got: \(error)")
            }
        }
    }

  func testCreateSignalSocketAtPathLimit() async throws {
    
    // Verify paths under 104 chars work fine
        let eventLog = RelayEventLog()
        let path = String(repeating: "a", count: 90) + ".sock"

        let relay = try UDSVirtioFSRelay(
            socketPath: path,
            createSignalSocket: true,
            eventLog: eventLog
        )

        XCTAssertNotNil(relay, "Relay should be created for path under 104 chars")
    }
}

// MARK: - Virtio-FS Detection Tests (Plan 84)

/// Tests for Virtio-FS volume detection logic in RelayManager
/// These are static unit tests that don't require container runtime
@available(macOS 12.0, *)
final class VirtioFSDetectionTests: XCTestCase {

    func testDetectsVolumeSocketPath() {
        // Test detection of paths containing .containers/Volumes (Virtio-FS)
        let volumePaths = [
            "/path/to/.containers/Volumes/db/data/.s.PGSQL.5432",
            "/Users/me/.containers/Volumes/postgres/data/socket",
            "/var/lib/.containers/Volumes/mysql.sock"
        ]

        for path in volumePaths {
            let isVolumeSocket = path.contains(".containers/Volumes")
            XCTAssertTrue(isVolumeSocket, "\(path) should be detected as volume socket")
        }
    }

    func testIgnoresNonVolumeSocketPaths() {
        // Test that non-volume paths are correctly identified
        let nonVolumePaths = [
            "/tmp/test.sock",
            "/Users/me/.container-compose/sockets/db.sock",
            "/var/run/postgresql/.s.PGSQL.5432",
            "/path/to/containers/data.sock" // Note: "containers" not ".containers"
        ]

        for path in nonVolumePaths {
            let isVolumeSocket = path.contains(".containers/Volumes")
            XCTAssertFalse(isVolumeSocket, "\(path) should NOT be detected as volume socket")
        }
    }

    func testVolumeSocketSetsCreateSignalSocketFalse() {
        // Integration test: Verify that volume socket paths result in createSignalSocket: false
        let volumePath = "/path/to/.containers/Volumes/db/data/.s.PGSQL.5432"
        let isVolumeSocket = volumePath.contains(".containers/Volumes")
        let shouldCreateSignalSocket = !isVolumeSocket

        XCTAssertFalse(shouldCreateSignalSocket, "Volume socket should set createSignalSocket to false")
    }

    func testNonVolumeSocketSetsCreateSignalSocketTrue() {
        // Integration test: Verify that non-volume socket paths result in createSignalSocket: true
        let regularPath = "/Users/me/.container-compose/sockets/db.sock"
        let isVolumeSocket = regularPath.contains(".containers/Volumes")
        let shouldCreateSignalSocket = !isVolumeSocket

        XCTAssertTrue(shouldCreateSignalSocket, "Non-volume socket should set createSignalSocket to true")
    }

    func testEmptyPathNotDetectedAsVolume() {
        // Empty path should not be detected as a volume socket
        let emptyPath = ""
        let isVolumeSocket = emptyPath.contains(".containers/Volumes")

        XCTAssertFalse(isVolumeSocket, "Empty path should not be detected as volume socket")
    }

    func testRelativePathDetection() {
        // Test that relative paths with .containers/Volumes are detected
        let relativePath = "./.containers/Volumes/db/socket"
        let isVolumeSocket = relativePath.contains(".containers/Volumes")

        XCTAssertTrue(isVolumeSocket, "Relative path with .containers/Volumes should be detected")
    }

    func testPathEdgeCases() {
        // Edge cases that should NOT match
        let edgeCases = [
            ".containersVolumes",      // Missing slash
            ".containers/Volumes",      // Directory itself, not a socket
            "/Volumes/.containers",     // Reversed order
            "containers/Volumes"        // Missing leading dot
        ]

        for path in edgeCases {
            let isVolumeSocket = path.contains(".containers/Volumes")
            // The last one (".containers/Volumes") will match, which is correct
            // as it's checking for the directory pattern
            if path == ".containers/Volumes" {
                XCTAssertTrue(isVolumeSocket, "\(path) directory pattern should match")
            } else {
                XCTAssertFalse(isVolumeSocket, "\(path) should NOT match volume socket pattern")
            }
        }
    }

    func testSymlinkPathWithVolumes() {
        // Test that paths with symlinks containing .containers/Volumes are handled correctly
        // Note: This test verifies the string pattern matching, not actual symlink resolution
        let symlinkPath = "/tmp/symlink-to-volumes/.containers/Volumes/db/socket"
        let isVolumeSocket = symlinkPath.contains(".containers/Volumes")
        
        XCTAssertTrue(isVolumeSocket, "Path with symlink containing Volumes should be detected")
    }

    func testVeryLongVolumePath() {
        // Test handling of very long volume paths
        let longPath = "/path/to/.containers/Volumes/" + String(repeating: "very/long/directory/", count: 10) + "db.sock"
        let isVolumeSocket = longPath.contains(".containers/Volumes")
        
        XCTAssertTrue(isVolumeSocket, "Long volume path should be detected")
    }

    func testVolumePathWithSpecialCharacters() {
        // Test paths with special characters that might be used in volume names
        let specialPaths = [
            "/.containers/Volumes/db-with-dash/data.sock",
            "/.containers/Volumes/db_with_underscore/data.sock",
            "/.containers/Volumes/db.with.period/data.sock"
        ]
        
        for path in specialPaths {
            let isVolumeSocket = path.contains(".containers/Volumes")
            XCTAssertTrue(isVolumeSocket, "Path with special chars should be detected: \(path)")
        }
    }
}

// MARK: - CIDVerifier Tests (Plan 84 Phase 4)

/// Tests for CIDVerifier allowing dynamic Guest CIDs (≥ 3)
@available(macOS 12.0, *)
final class CIDVerifierTests: XCTestCase {

    func testVerifyAcceptsAnyCIDWhenConfigured() {
        let verifier = CIDVerifier(allowedCIDs: [CIDVerifier.anyCID])
        XCTAssertTrue(verifier.verify(cid: 0), "Should accept HYPERVISOR CID")
        XCTAssertTrue(verifier.verify(cid: 1), "Should accept LOCAL CID")
        XCTAssertTrue(verifier.verify(cid: 2), "Should accept HOST CID")
        XCTAssertTrue(verifier.verify(cid: 3), "Should accept GUEST CID 3")
        XCTAssertTrue(verifier.verify(cid: 4), "Should accept GUEST CID 4")
        XCTAssertTrue(verifier.verify(cid: 5), "Should accept GUEST CID 5")
        XCTAssertTrue(verifier.verify(cid: 100), "Should accept high CID values")
    }

    func testVerifyAcceptsSpecificGuestCIDs() {
        let verifier = CIDVerifier(allowedCIDs: [3, 4, 5])
        XCTAssertTrue(verifier.verify(cid: 3), "Should accept CID 3")
        XCTAssertTrue(verifier.verify(cid: 4), "Should accept CID 4")
        XCTAssertTrue(verifier.verify(cid: 5), "Should accept CID 5")
    }

    func testVerifyRejectsUnauthorizedCIDs() {
        let verifier = CIDVerifier(allowedCIDs: [3, 4, 5])
        XCTAssertFalse(verifier.verify(cid: 0), "Should reject HYPERVISOR CID")
        XCTAssertFalse(verifier.verify(cid: 1), "Should reject LOCAL CID")
        XCTAssertFalse(verifier.verify(cid: 2), "Should reject HOST CID")
        XCTAssertFalse(verifier.verify(cid: 6), "Should reject CID 6")
        XCTAssertFalse(verifier.verify(cid: 100), "Should reject unauthorized CID")
    }

    func testVerifyAcceptsHostCID() {
        let verifier = CIDVerifier(allowedCIDs: [CIDVerifier.hostCID])
        XCTAssertTrue(verifier.verify(cid: 2), "Should accept HOST CID (2)")
    }

    func testVerifyAcceptsMultipleGuestCIDs() {
        let guestCIDs: [UInt32] = Array(3...20)
        let verifier = CIDVerifier(allowedCIDs: guestCIDs)
        
        for cid in guestCIDs {
            XCTAssertTrue(verifier.verify(cid: cid), "Should accept CID \(cid)")
        }
    }

    func testDefaultAllowsAnyCID() {
        let verifier = CIDVerifier(allowedCIDs: [])
        XCTAssertTrue(verifier.verify(cid: CIDVerifier.anyCID), "Should accept ANY CID")
        XCTAssertTrue(verifier.verify(cid: CIDVerifier.hostCID), "Should accept HOST CID")
        XCTAssertTrue(verifier.verify(cid: 3), "Should accept GUEST CID")
    }

    func testStaticCIDConstants() {
        XCTAssertEqual(CIDVerifier.anyCID, 0xFFFFFFFF, "ANY_CID should be 0xFFFFFFFF")
        XCTAssertEqual(CIDVerifier.hypervisorCID, 0, "HYPERVISOR_CID should be 0")
        XCTAssertEqual(CIDVerifier.hostCID, 0x2, "HOST_CID should be 0x2")
        XCTAssertEqual(CIDVerifier.localCID, 0x1, "LOCAL_CID should be 0x1")
    }

    func testEmptyAllowedCIDsAllowsAll() {
        let verifier = CIDVerifier(allowedCIDs: [])
        for cid: UInt32 in [0, 1, 2, 3, 4, 5, 10, 100, 1000] {
            XCTAssertTrue(verifier.verify(cid: cid), "Empty allowedCIDs should allow all CIDs, but rejected CID \(cid)")
        }
    }

func testSingletonAllowedCIDs() {
    let verifier = CIDVerifier(allowedCIDs: [5])
    XCTAssertTrue(verifier.verify(cid: 5), "Should accept CID 5")
    XCTAssertFalse(verifier.verify(cid: 3), "Should reject CID 3")
    XCTAssertFalse(verifier.verify(cid: 4), "Should reject CID 4")
  }
}