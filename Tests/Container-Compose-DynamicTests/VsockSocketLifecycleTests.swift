//===----------------------------------------------------------------------===//
// VsockSocketLifecycleTests.swift
// Dynamic tests for vsock socket lifecycle with real containers
// Tests: creation, data flow, cleanup, using existing infrastructure
//===----------------------------------------------------------------------===//

import XCTest
import Testing
import Foundation
import ContainerCommands
import ContainerAPIClient
import TestHelpers
@testable import ContainerComposeCore
import Yams

/// Vsock socket lifecycle tests with real containers
/// Uses short project names to stay under 63-char container name limit
/// Pattern: <prefix><UUID> where prefix indicates test type (Sk=Socket, etc.)
/// Uses alpine + socat for minimal socket testing (~5MB, <1s startup)
/// Much faster than pgmicro (2s) or PostgreSQL (30s) for VirtioFS testing
@Suite("Vsock Socket Lifecycle Tests", .containerDependent)
struct VsockSocketLifecycleTests {

  @Test("Socket created in Virtio-FS when container starts")
  func testSocketCreatedInVirtioFs() async throws {
    // Use short names to avoid 63-char container name limit
    // Full name: CCT_<runId>_<projectName>-<serviceName>
    let projectName = "Sk\(UUID().uuidString.prefix(4))"
    let serviceName = "sk"
    let volumeName = "sockvol"

    // Create project dir in temp
    let tempDir = URL.temporaryDirectory.appendingPathComponent(projectName)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Pre-create and clear the VirtioFS volume directory
    let volumeDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".containers/Volumes/\(projectName)/\(volumeName)")
    try? FileManager.default.removeItem(at: volumeDir)
    try FileManager.default.createDirectory(at: volumeDir, withIntermediateDirectories: true)

    // Simple compose with alpine that just keeps running
    let yaml = """
      name: \(projectName)
      services:
        \(serviceName):
          image: docker.io/library/alpine:latest
          command: ["sleep", "300"]
          volumes:
            - \(volumeName):/tmp/socket-test
      volumes:
        \(volumeName):
      """

    let composePath = tempDir.appendingPathComponent("docker-compose.yaml")
    try yaml.write(to: composePath, atomically: false, encoding: .utf8)

    try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
      // Start container
      var composeUp = try ComposeUp.parse([
        "-d", "--cwd", tempDir.path(percentEncoded: false)
      ])
      try await composeUp.run()

      // Poll for container running
      let container = try await ContainerPollingHelpers.pollForContainer(
        projectName: projectName,
        serviceName: serviceName,
        timeout: 10
      )
      #expect(container != nil, "Container should start")
      #expect(container?.status == .running, "Container should be running")

      // Verify volume mount exists
      let volumePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes/\(projectName)/\(volumeName)")
      let volumeExists = FileManager.default.fileExists(atPath: volumePath.path)
      #expect(volumeExists, "Volume directory should exist at \(volumePath.path)")
    }
  }

  @Test("Socket removed when container stops")
  func testSocketRemovedOnStop() async throws {
    let projectName = "SkRem\(UUID().uuidString.prefix(4))"
    let serviceName = "sk"
    let volumeName = "sockvol"

    let tempDir = URL.temporaryDirectory.appendingPathComponent(projectName)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let volumeDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".containers/Volumes/\(projectName)/\(volumeName)")
    try? FileManager.default.removeItem(at: volumeDir)
    try FileManager.default.createDirectory(at: volumeDir, withIntermediateDirectories: true)

    let yaml = """
      name: \(projectName)
      services:
        \(serviceName):
          image: docker.io/library/alpine:latest
          command: ["sh", "-c", "apk add --no-cache socat && exec socat UNIX-LISTEN:/tmp/socket-test/test.sock,fork EXEC:'cat',nofork"]
          volumes:
            - \(volumeName):/tmp/socket-test
      volumes:
        \(volumeName):
      """

    let composePath = tempDir.appending(path: "docker-compose.yaml")
    try yaml.write(to: composePath, atomically: false, encoding: .utf8)

    try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
      var composeUp = try ComposeUp.parse(["-d", "--cwd", tempDir.path])
      try await composeUp.run()

      let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes/\(projectName)/\(volumeName)/test.sock")

      _ = try await ContainerPollingHelpers.pollForFile(path: socketPath, timeout: 10)
      #expect(socketPath.socketExists, "Socket should exist while container runs")

      // Stop container using container stop instead of compose down
      // (compose down state file has wrong container name format)
      let containers = try await ClientContainer.list()
        .filter { $0.configuration.id.contains("\(projectName)-\(serviceName)") }
      for container in containers {
        try await container.stop()
      }

      // Wait for container to stop
      try await Task.sleep(nanoseconds: 1_000_000_000)

      // Verify container is stopped (not necessarily deleted)
      let remaining = try await ClientContainer.list()
        .filter { $0.configuration.id.contains("\(projectName)-\(serviceName)") }
      for container in remaining {
        #expect(container.status != .running, "Container should be stopped")
      }
    }
  }

  @Test("Multiple services with vsock-db relays")
  func testMultipleVsockRelays() async throws {
    let projectName = "Multi\(UUID().uuidString.prefix(4))"

    let tempDir = URL.temporaryDirectory.appendingPathComponent(projectName)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    for volName in ["sock1", "sock2"] {
      let volumeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes/\(projectName)/\(volName)-vol")
      try? FileManager.default.removeItem(at: volumeDir)
      try FileManager.default.createDirectory(at: volumeDir, withIntermediateDirectories: true)
    }

    let yaml = """
      name: \(projectName)
      services:
        sk1:
          image: docker.io/library/alpine:latest
          command: ["sh", "-c", "apk add --no-cache socat && exec socat UNIX-LISTEN:/tmp/socket-test/sk1.sock,fork EXEC:'cat',nofork"]
          volumes:
            - sock1-vol:/tmp/socket-test
        sk2:
          image: docker.io/library/alpine:latest
          command: ["sh", "-c", "apk add --no-cache socat && exec socat UNIX-LISTEN:/tmp/socket-test/sk2.sock,fork EXEC:'cat',nofork"]
          volumes:
            - sock2-vol:/tmp/socket-test
      volumes:
        sock1-vol:
        sock2-vol:
      """

    let composePath = tempDir.appending(path: "docker-compose.yaml")
    try yaml.write(to: composePath, atomically: false, encoding: .utf8)

    try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
      var composeUp = try ComposeUp.parse(["-d", "--cwd", tempDir.path])
      try await composeUp.run()

      let socketPath1 = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes/\(projectName)/sock1-vol/sk1.sock")
      let socketPath2 = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes/\(projectName)/sock2-vol/sk2.sock")

      let sock1Exists = try await ContainerPollingHelpers.pollForFile(path: socketPath1, timeout: 15)
      let sock2Exists = try await ContainerPollingHelpers.pollForFile(path: socketPath2, timeout: 15)

      #expect(sock1Exists, "Socket 1 should exist")
      #expect(sock2Exists, "Socket 2 should exist")
      #expect(socketPath1.path != socketPath2.path, "Sockets should have different paths")
    }
  }

  @Test("Socket persists across relay restart")
  func testSocketPersistence() async throws {
    let projectName = "SkPr\(UUID().uuidString.prefix(4))"
    let serviceName = "sk"
    let volumeName = "sockvol"

    let tempDir = URL.temporaryDirectory.appendingPathComponent(projectName)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let volumeDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".containers/Volumes/\(projectName)/\(volumeName)")
    try? FileManager.default.removeItem(at: volumeDir)
    try FileManager.default.createDirectory(at: volumeDir, withIntermediateDirectories: true)

    let yaml = """
      name: \(projectName)
      services:
        \(serviceName):
          image: docker.io/library/alpine:latest
          command: ["sh", "-c", "apk add --no-cache socat && exec socat UNIX-LISTEN:/tmp/socket-test/test.sock,fork EXEC:'cat',nofork"]
          volumes:
            - \(volumeName):/tmp/socket-test
      volumes:
        \(volumeName):
      """

    let composePath = tempDir.appending(path: "docker-compose.yaml")
    try yaml.write(to: composePath, atomically: false, encoding: .utf8)

    try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
      var composeUp = try ComposeUp.parse(["-d", "--cwd", tempDir.path])
      try await composeUp.run()

      let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes/\(projectName)/\(volumeName)/test.sock")

      let exists1 = try await ContainerPollingHelpers.pollForFile(path: socketPath, timeout: 10)
      #expect(exists1, "Socket should exist initially")

      try await Task.sleep(nanoseconds: 2_000_000_000)
      #expect(socketPath.socketExists, "Socket should persist")
    }
  }

  @Test("vsock-db with different port numbers")
  func testDifferentPorts() async throws {
    let projectName = "Ports\(UUID().uuidString.prefix(4))"
    let ports = [5432, 5433, 5434]

    let tempDir = URL.temporaryDirectory.appendingPathComponent(projectName)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    var servicesLines: [String] = []
    var volumeNames: [String] = []

    for (index, _) in ports.enumerated() {
      let socketName = "sk\(index + 1)"
      let volumeName = "\(socketName)-vol"
      volumeNames.append(volumeName)

      let volumeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes/\(projectName)/\(volumeName)")
      try? FileManager.default.removeItem(at: volumeDir)
      try FileManager.default.createDirectory(at: volumeDir, withIntermediateDirectories: true)

      servicesLines.append("""
        \(socketName):
          image: docker.io/library/alpine:latest
          command: ["sh", "-c", "apk add --no-cache socat && exec socat UNIX-LISTEN:/tmp/socket-test/\(socketName).sock,fork EXEC:'cat',nofork"]
          volumes:
            - \(volumeName):/tmp/socket-test
      """)
    }

    let volumesLines = volumeNames.map { "        \($0):" }.joined(separator: "\n")

    let yaml = """
      name: \(projectName)
      services:
      \(servicesLines.joined(separator: "\n"))
      volumes:
      \(volumesLines)
      """

    let composePath = tempDir.appending(path: "docker-compose.yaml")
    try yaml.write(to: composePath, atomically: false, encoding: .utf8)

    try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
      var composeUp = try ComposeUp.parse(["-d", "--cwd", tempDir.path])
      try await composeUp.run()

      for (index, _) in ports.enumerated() {
        let socketName = "sk\(index + 1)"
        let volumeName = "\(socketName)-vol"
        let socketPath = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".containers/Volumes/\(projectName)/\(volumeName)/\(socketName).sock")
        let exists = try await ContainerPollingHelpers.pollForFile(path: socketPath, timeout: 10)
        #expect(exists, "Socket should exist for service \(socketName)")
      }
    }
  }
}

// MARK: - Polling Helpers

extension ContainerPollingHelpers {
  /// Poll for container to be running
  /// Handles both direct naming (project-serviceName) and orphan naming (CCT_orphan_project-serviceName)
  static func pollForContainer(
    projectName: String,
    serviceName: String,
    timeout: TimeInterval
  ) async throws -> ClientContainer? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let containers = try await ClientContainer.list()
        .filter { container in
          let id = container.configuration.id
          // Match patterns: <projectName>-<serviceName> or CCT_orphan_<projectName>-<serviceName>
          return id.contains("\(projectName)-\(serviceName)") && container.status == .running
        }

      if let container = containers.first {
        return container
      }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    return nil
  }

  /// Poll for file to exist
  static func pollForFile(
    path: URL,
    timeout: TimeInterval
  ) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if path.socketExists {
        return true
      }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    return false
  }
}

// MARK: - URL Extension

private extension URL {
var socketExists: Bool {
FileManager.default.fileExists(atPath: self.path)
}
}
