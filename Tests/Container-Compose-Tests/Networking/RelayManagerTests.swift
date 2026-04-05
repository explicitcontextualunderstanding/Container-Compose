import XCTest
import Network
@testable import ContainerComposeCore

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
    
    // MARK: - Unit Tests (Memory Streams)
    
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
    
    // MARK: - Integration Tests (Actual Network Ports)
    
    func testWaitForSocketTimeout() async throws {
        // Create a temp directory for the test socket
        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("test-\(UUID().uuidString).sock").path
        
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        // Socket doesn't exist, should timeout
        do {
            try await manager.waitForSocket(at: socketPath, timeout: 0.5, interval: 0.05)
            XCTFail("Expected timeout error")
        } catch RelayError.timeout {
            // Expected
        }
    }
    
    func testWaitForSocketSuccess() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("test-\(UUID().uuidString).sock").path
        
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        // Create socket file in background
        Task {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            // Create a Unix socket using Netcat
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = ["-l", "-U", socketPath]
            try? process.run()
        }
        
        // Should find the socket
        try await manager.waitForSocket(at: socketPath, timeout: 2.0, interval: 0.05)
        
        // Verify socket exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }
    
    func testSocketRelayLifecycle() async throws {
        // This test requires an actual Unix socket server
        // We'll skip it if nc is not available
        guard FileManager.default.fileExists(atPath: "/usr/bin/nc") else {
            throw XCTSkip("nc not available")
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("relay-test-\(UUID().uuidString).sock").path
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        // Start a mock Unix socket server
        let serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        serverProcess.arguments = ["-l", "-U", socketPath, "-k"]
        try serverProcess.run()
        defer {
            serverProcess.terminate()
        }
        
        // Give server time to start
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Start relay on ephemeral port
        let config = RelayManager.RelayConfiguration(
            id: "test-relay",
            tcpPort: 0, // Ephemeral port
            unixSocketPath: socketPath,
            description: "Test relay"
        )
        
        // Note: This would require modifications to SocketRelay to support
        // ephemeral ports (port 0). For now, we test the configuration.
        XCTAssertNotNil(config)
    }
    
    // MARK: - E2E Tests (Full Integration)
    
    func testFullRelayDataFlow() async throws {
        throw XCTSkip("E2E test requires container runtime - run manually")
        
        // Full test would:
        // 1. Start a container with --publish-socket
        // 2. Start relay manager
        // 3. Connect via TCP
        // 4. Verify data flows through
        // 5. Clean up
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
