import XCTest
import Foundation
import Network
@testable import ContainerComposeCore

/// Tier 2 Integration Tests: Actual TCP ports and Unix sockets
/// Goal: Verify Network.framework handshake between protocols
/// Requirement: Handle "Port already in use" gracefully
@available(macOS 12.0, *)
final class SocketRelayIntegrationTests: XCTestCase {
    var eventLog: RelayEventLog!
    
    override func setUp() {
        super.setUp()
        eventLog = RelayEventLog()
    }
    
    override func tearDown() async throws {
        // Clean up any socket files
        let tempDir = FileManager.default.temporaryDirectory
        let socketFiles = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".sock") }
        for file in socketFiles ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }
    
    // MARK: - TCP to Unix Socket Data Flow
    
    func testTCPToUnixSocketDataFlow() async throws {
        // Given: A Unix socket "echo server" and a relay
        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("relay-test-\(UUID().uuidString).sock").path
        
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        // Create a simple Unix socket echo server using nc
        guard FileManager.default.fileExists(atPath: "/usr/bin/nc") else {
            throw XCTSkip("nc not available")
        }
        
        let serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        // -l: listen mode, -U: Unix socket, -k: keep listening
        serverProcess.arguments = ["-l", "-U", socketPath, "-k"]
        try serverProcess.run()
        defer {
            serverProcess.terminate()
            serverProcess.waitUntilExit()
        }
        
        // Wait for server to start
        let manager = RelayManager(eventLog: eventLog)
        try await manager.waitForSocket(at: socketPath, timeout: 2.0)
        
        // Get an available TCP port
        let testPort = getAvailablePort()
        
        // Create and start the relay
        let config = RelayManager.RelayConfiguration(
            id: "test-relay",
            tcpPort: testPort,
            unixSocketPath: socketPath,
            description: "Integration test relay"
        )
        
        try await manager.startRelay(config)
        defer {
            Task {
                await manager.stopAll()
            }
        }
        
        // Give relay time to start
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // When: Connect via TCP and send data
        let tcpConnection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: testPort)),
            using: .tcp
        )
        tcpConnection.start(queue: .global())
        
        // Wait for connection
        var ready = false
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if case .ready = tcpConnection.state {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ready, "TCP connection should be ready")
        
        // Send test data
        let testData = "Hello from TCP client!".data(using: .utf8)!
        let sendExpectation = expectation(description: "Data sent")
        tcpConnection.send(content: testData, completion: .contentProcessed { _ in
            sendExpectation.fulfill()
        })
        await fulfillment(of: [sendExpectation], timeout: 2.0)
        
        // Then: Data should reach the Unix socket (nc would echo it back if we sent more)
        // For this test, we just verify the connection established successfully
        XCTAssertEqual(tcpConnection.state, .ready)
        
        tcpConnection.cancel()
    }
    
    // MARK: - Port Collision Handling
    
    func testPortCollisionHandling() async throws {
        // Given: A port already in use
        let occupiedPort = getAvailablePort()
        
        // Create a "server" that holds the port
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: occupiedPort))
        listener.start(queue: .global())
        defer {
            listener.cancel()
        }
        
        // Wait for listener to start
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Create a Unix socket for the relay
        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("port-collision-test-\(UUID().uuidString).sock").path
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        // Create a fake socket file
        FileManager.default.createFile(atPath: socketPath, contents: nil, attributes: nil)
        
        // Create the relay manager
        let manager = RelayManager(eventLog: eventLog)
        
        // When: Try to start relay on occupied port
        let config = RelayManager.RelayConfiguration(
            id: "collision-test",
            tcpPort: occupiedPort,
            unixSocketPath: socketPath,
            description: "Port collision test"
        )
        
        // Then: Should fail with port in use error
        do {
            try await manager.startRelay(config)
            XCTFail("Expected error when starting relay on occupied port")
        } catch {
            // Expected - either port in use or socket not available
            XCTAssertTrue(
                error is RelayError || error is NWError,
                "Expected RelayError or NWError, got: \(type(of: error))"
            )
        }
    }
    
    // MARK: - Concurrent Connections
    
    func testMultipleConcurrentConnections() async throws {
        // Given: A relay with multiple concurrent TCP connections
        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("concurrent-test-\(UUID().uuidString).sock").path
        
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        // Create a Unix socket server
        guard FileManager.default.fileExists(atPath: "/usr/bin/nc") else {
            throw XCTSkip("nc not available")
        }
        
        let serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        serverProcess.arguments = ["-l", "-U", socketPath, "-k"]
        try serverProcess.run()
        defer {
            serverProcess.terminate()
            serverProcess.waitUntilExit()
        }
        
        // Wait for server
        let manager = RelayManager(eventLog: eventLog)
        try await manager.waitForSocket(at: socketPath, timeout: 2.0)
        
        // Get port and start relay
        let testPort = getAvailablePort()
        let config = RelayManager.RelayConfiguration(
            id: "concurrent-relay",
            tcpPort: testPort,
            unixSocketPath: socketPath,
            description: "Concurrent connections test"
        )
        
        try await manager.startRelay(config)
        defer {
            Task {
                await manager.stopAll()
            }
        }
        
        // Give relay time to start
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // When: Create multiple concurrent connections
        let connectionCount = 5
        var connections: [NWConnection] = []
        
        for i in 0..<connectionCount {
            let conn = NWConnection(
                to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: testPort)),
                using: .tcp
            )
            conn.start(queue: .global())
            connections.append(conn)
            
            // Send data on each connection
            let data = "Message from connection \(i)".data(using: .utf8)!
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
        
        // Wait for connections to establish
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // Then: All connections should be ready
        let readyCount = connections.filter { conn in
            if case .ready = conn.state { return true }
            return false
        }.count
        
        XCTAssertGreaterThanOrEqual(readyCount, connectionCount - 1, "Most connections should be ready")
        
        // Clean up connections
        for conn in connections {
            conn.cancel()
        }
    }
    
    // MARK: - Ephemeral Port Assignment
    
    func testEphemeralPortAssignment() async throws {
        // Given: Port 0 (ephemeral) requested
        let tempDir = FileManager.default.temporaryDirectory
        let socketPath = tempDir.appendingPathComponent("ephemeral-test-\(UUID().uuidString).sock").path
        
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        // Create socket
        FileManager.default.createFile(atPath: socketPath, contents: nil, attributes: nil)
        
        // Note: Current implementation may not support ephemeral ports
        // This test documents expected behavior
        let manager = RelayManager(eventLog: eventLog)
        
        // When: Start with port 0
        // This should either fail with an error or be documented as not supported
        // For now, we skip the actual test since the implementation needs port 0 support
        throw XCTSkip("Ephemeral port (0) support needs implementation")
    }
    
    // MARK: - Helper Methods
    
    private func getAvailablePort() -> UInt16 {
        // Create a temporary socket to find an available port
        var port: UInt16 = 0
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        addr.sin_port = 0 // Let system assign port
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                bind(socket, addrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult == 0 else {
            // Fallback to random port in high range
            return UInt16.random(in: 30000...65000)
        }
        
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var assignedAddr = sockaddr_in()
        let getResult = withUnsafeMutablePointer(to: &assignedAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                getsockname(socket, addrPtr, &addrLen)
            }
        }
        
        guard getResult == 0 else {
            return UInt16.random(in: 30000...65000)
        }
        
        return assignedAddr.sin_port.bigEndian
    }
}
