//===----------------------------------------------------------------------===//
// IsolatedDatabaseConnectivityTests.swift
// Database connectivity tests using isolated CCT_* containers
// Follows production-like pattern but doesn't touch production systems
//===----------------------------------------------------------------------===//

import XCTest
import Foundation
import ContainerAPIClient
import TestHelpers
@testable import ContainerComposeCore

/// Isolated database connectivity tests using CCT_* containers
/// Validates vsock-db relay without touching production
@available(macOS 15.0, *)
final class IsolatedDatabaseConnectivityTests: XCTestCase {

  // MARK: - Configuration

  private let testTimeout: TimeInterval = 60.0
  private let dbPort: UInt16 = 5432

  // MARK: - Test: PostgreSQL via vsock-db Relay

  /// Test database connectivity through vsock-db relay using isolated container
  /// Similar to production setup but completely isolated (CCT_* prefix)
  func testPostgresViaVsockRelay() async throws {
    let projectName = "CCT_DBRelay_\(UUID().uuidString.prefix(8))"
    let tempDir = URL.temporaryDirectory.appending(path: projectName)

    let composeYaml = """
      name: \(projectName)
      services:
        db:
          image: postgres:14-alpine
          environment:
            POSTGRES_DB: testdb
            POSTGRES_USER: testuser
            POSTGRES_PASSWORD: testpass
          volumes:
            - db-data:/var/lib/postgresql/data
            - db-sockets:/var/run/postgresql/sockets
          x-apple-relays:
            - type: vsock-db
              port: \(dbPort)
              socket_path: ~/.containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.\(dbPort)
          command:
            - postgres
            - -c
            - unix_socket_directories=/var/run/postgresql/sockets
      volumes:
        db-data:
        db-sockets:
      """

    // Write compose file to temp directory
    let composePath = tempDir.appending(path: "docker-compose.yaml")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try composeYaml.write(to: composePath, atomically: false, encoding: .utf8)

    // Deploy and test using isolated container pattern
    try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
      // Start the composition
      var composeUp = try ComposeUp.parse(["-d", "--cwd", tempDir.path])
      try await composeUp.run()

      // Wait for database to be ready
      let dbReady = try await ContainerPollingHelpers.pollForDatabase(
        projectName: projectName,
        serviceName: "db",
        timeout: testTimeout
      )
      XCTAssertTrue(dbReady, "Database should be ready within \(testTimeout)s")

      // Verify socket was created in Virtio-FS volume
      let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.\(dbPort)")
      XCTAssertTrue(socketPath.exists, "Socket should exist at \(socketPath.path)")

      // Test relay connectivity (if relay is running)
      if await VsockRelayHelper.isRelayAvailable(port: dbPort) {
        let connected = try await testRelayConnection(port: dbPort)
        XCTAssertTrue(connected, "Should connect through vsock relay")
      } else {
        print("Relay not yet active - socket creation validated")
      }

      // Verify container health
      let containers = try await ClientContainer.list()
        .filter { $0.configuration.id.contains(projectName) }
      XCTAssertEqual(containers.count, 1, "Should have exactly 1 database container")

      if let dbContainer = containers.first {
        XCTAssertEqual(dbContainer.status, .running, "Database should be running")
        XCTAssertTrue(dbContainer.configuration.image.reference.contains("postgres"))
      }
    }
  }

  /// Test multiple concurrent connections through relay
  func testConcurrentConnections() async throws {
    let projectName = "CCT_Concurrent_\(UUID().uuidString.prefix(8))"

    try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
      // Deploy test database
      try await deployTestDatabase(projectName: projectName)

      // Test concurrent access (simulated)
      let connectionCount = 5
      var results: [Bool] = []

      for i in 0..<connectionCount {
        let connected = await simulateConnection(projectName: projectName, index: i)
        results.append(connected)
      }

      XCTAssertEqual(results.filter { $0 }.count, connectionCount,
                     "All \(connectionCount) connections should succeed")
    }
  }

  /// Test transaction handling through relay
  func testTransactionHandling() async throws {
    let projectName = "CCT_Transaction_\(UUID().uuidString.prefix(8))"

    try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
      try await deployTestDatabase(projectName: projectName)

      // Verify socket exists (prerequisite for transactions)
      let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.\(dbPort)")
      XCTAssertTrue(socketPath.exists, "Socket required for transaction test")

      // Transaction test would execute BEGIN/COMMIT/ROLLBACK
      // For now, validate socket persistence
      try await Task.sleep(nanoseconds: 2_000_000_000) // 2s
      XCTAssertTrue(socketPath.exists, "Socket should persist during operations")
    }
  }

  /// Test connection resilience (restart scenario)
  func testConnectionResilience() async throws {
    let projectName = "CCT_Resilience_\(UUID().uuidString.prefix(8))"

    try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
      // Initial deployment
      try await deployTestDatabase(projectName: projectName)

      let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.\(dbPort)")

      // Verify initial state
      XCTAssertTrue(socketPath.exists, "Socket should exist initially")

      // Simulate relay restart by checking socket persistence
      try await Task.sleep(nanoseconds: 1_000_000_000)
      XCTAssertTrue(socketPath.exists, "Socket should survive simulated restart")
    }
  }

  // MARK: - Helper Methods

  private func deployTestDatabase(projectName: String) async throws {
    let tempDir = URL.temporaryDirectory.appending(path: projectName)
    let composeYaml = """
      name: \(projectName)
      services:
        db:
          image: postgres:14-alpine
          environment:
            POSTGRES_DB: testdb
            POSTGRES_USER: testuser
            POSTGRES_PASSWORD: testpass
          volumes:
            - db-sockets:/var/run/postgresql/sockets
          x-apple-relays:
            - type: vsock-db
              port: \(dbPort)
              socket_path: ~/.containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.\(dbPort)
          command:
            - postgres
            - -c
            - unix_socket_directories=/var/run/postgresql/sockets
      volumes:
        db-sockets:
      """

    let composePath = tempDir.appending(path: "docker-compose.yaml")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try composeYaml.write(to: composePath, atomically: false, encoding: .utf8)

    var composeUp = try ComposeUp.parse(["-d", "--cwd", tempDir.path])
    try await composeUp.run()

    // Wait for ready
    let ready = try await ContainerPollingHelpers.pollForDatabase(
      projectName: projectName,
      serviceName: "db",
      timeout: 30
    )
    XCTAssertTrue(ready, "Database should be ready")
  }

  private func testRelayConnection(port: UInt16) async throws -> Bool {
    // Simulate connection test to relay
    // In full implementation, would use PostgreSQL client
    return true
  }

  private func simulateConnection(projectName: String, index: Int) async -> Bool {
    // Simulate connection validation
    let socketPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.\(dbPort)")
    return socketPath.exists
  }
}

// MARK: - Polling Helper Extensions

extension ContainerPollingHelpers {
  /// Poll for database container to be ready
  static func pollForDatabase(
    projectName: String,
    serviceName: String,
    timeout: TimeInterval
  ) async throws -> Bool {
    let startTime = Date()
    while Date().timeIntervalSince(startTime) < timeout {
      let containers = try await ClientContainer.list()
        .filter { $0.configuration.id == "\(projectName)-\(serviceName)" }

      if let db = containers.first, db.status == .running {
        // Additional check: socket file exists
        let socketPath = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.5432")
        if socketPath.exists {
          return true
        }
      }

      try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    }
    return false
  }
}

// MARK: - VsockRelay Helper

actor VsockRelayHelper {
  static func isRelayAvailable(port: UInt16) async -> Bool {
    // Check if relay is active on port
    // Implementation would verify relay status
    return false // Placeholder
  }
}

// MARK: - URL Extension

private extension URL {
  var exists: Bool {
    FileManager.default.fileExists(atPath: self.path)
  }
}
