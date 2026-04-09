//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import XCTest
import Foundation
import os.log
@testable import ContainerComposeCore

final class SecretsMountIntegrationTests: XCTestCase {

  var secretsManager: SecretsMountManager!
  var mockEnclavePath: String!
  var tempMountDir: String!

  override func setUp() {
    super.setUp()

    // Create mock enclave
    mockEnclavePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("mock-enclave-\(UUID().uuidString)")
      .path

    try? FileManager.default.createDirectory(atPath: mockEnclavePath, withIntermediateDirectories: true)

    // Add test secrets
    try? "test-value-1".write(toFile: "\(mockEnclavePath!)/secret_one.txt", atomically: true, encoding: .utf8)
    try? "test-value-2".write(toFile: "\(mockEnclavePath!)/secret_two.txt", atomically: true, encoding: .utf8)

    secretsManager = SecretsMountManager(
      enclavePath: mockEnclavePath,
      logger: Logger(subsystem: "test", category: "integration")
    )

    tempMountDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mounts-\(UUID().uuidString)")
      .path
    try? FileManager.default.createDirectory(atPath: tempMountDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    // Cleanup
    try? FileManager.default.removeItem(atPath: mockEnclavePath)
    try? FileManager.default.removeItem(atPath: tempMountDir)
    super.tearDown()
  }

  // MARK: - End-to-End Mount Tests

  func testCompleteMountUnmountCycle() async throws {
    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["SECRET_ONE", "SECRET_TWO"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    // Mount secrets
    let mount = try await secretsManager.createSecretsMount(
      for: "integration-test-container",
      config: config
    )

    XCTAssertEqual(mount.containerID, "integration-test-container")
    XCTAssertEqual(mount.containerPath, "/run/secrets")
    XCTAssertTrue(FileManager.default.fileExists(atPath: mount.hostPath))

    // Verify secrets copied
    let secretOnePath = "\(mount.hostPath)/SECRET_ONE"
    let secretTwoPath = "\(mount.hostPath)/SECRET_TWO"

    XCTAssertTrue(FileManager.default.fileExists(atPath: secretOnePath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secretTwoPath))

    let secretOneContent = try String(contentsOfFile: secretOnePath, encoding: .utf8)
    let secretTwoContent = try String(contentsOfFile: secretTwoPath, encoding: .utf8)

    XCTAssertEqual(secretOneContent, "test-value-1")
    XCTAssertEqual(secretTwoContent, "test-value-2")

    // Verify permissions
    let attrs = try FileManager.default.attributesOfItem(atPath: secretOnePath)
    let permissions = attrs[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o400)

    // Cleanup
    try await secretsManager.cleanupMount(for: "integration-test-container")

    // Verify cleanup
    XCTAssertFalse(FileManager.default.fileExists(atPath: mount.hostPath))
  }

  func testMountWithImmediateCleanup() async throws {
    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["SECRET_ONE"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let mount = try await secretsManager.createSecretsMount(
      for: "cleanup-test",
      config: config
    )

    XCTAssertEqual(mount.cleanupPolicy, .immediate)

    // Simulate immediate cleanup
    try await secretsManager.cleanupMount(for: "cleanup-test")

    // Mount point should not exist
    XCTAssertFalse(FileManager.default.fileExists(atPath: mount.hostPath))
  }

  func testMountWithOnStopCleanup() async throws {
    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["SECRET_ONE"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .onStop
    )

    let mount = try await secretsManager.createSecretsMount(
      for: "on-stop-test",
      config: config
    )

    XCTAssertEqual(mount.cleanupPolicy, .onStop)

    // Mount should still exist before explicit cleanup
    XCTAssertTrue(FileManager.default.fileExists(atPath: mount.hostPath))

    // Manual cleanup simulates container stop
    try await secretsManager.cleanupMount(for: "on-stop-test")

    // Now should be gone
    XCTAssertFalse(FileManager.default.fileExists(atPath: mount.hostPath))
  }

  func testMountWithManualCleanup() async throws {
    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["SECRET_ONE"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .manual
    )

    let mount = try await secretsManager.createSecretsMount(
      for: "manual-test",
      config: config
    )

    XCTAssertEqual(mount.cleanupPolicy, .manual)

    // Should persist until explicitly cleaned
    XCTAssertTrue(FileManager.default.fileExists(atPath: mount.hostPath))

    // Manual cleanup
    try await secretsManager.cleanupMount(for: "manual-test")
    XCTAssertFalse(FileManager.default.fileExists(atPath: mount.hostPath))
  }

  // MARK: - Multiple Container Tests

  func testMountForMultipleContainers() async throws {
    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["SECRET_ONE"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let mount1 = try await secretsManager.createSecretsMount(
      for: "container-1",
      config: config
    )

    let mount2 = try await secretsManager.createSecretsMount(
      for: "container-2",
      config: config
    )

    // Different containers should have different host paths
    XCTAssertNotEqual(mount1.hostPath, mount2.hostPath)

    // Both should have the secret
    let secret1Path = "\(mount1.hostPath)/SECRET_ONE"
    let secret2Path = "\(mount2.hostPath)/SECRET_ONE"

    XCTAssertTrue(FileManager.default.fileExists(atPath: secret1Path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secret2Path))

    // Cleanup
    try await secretsManager.cleanupMount(for: "container-1")
    try await secretsManager.cleanupMount(for: "container-2")
  }

  func testIsolatedSecretsBetweenContainers() async throws {
    // Container 1 gets all secrets
    let config1 = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,  // All secrets
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    // Container 2 gets only one secret
    let config2 = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["SECRET_ONE"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let mount1 = try await secretsManager.createSecretsMount(
      for: "isolated-1",
      config: config1
    )

    let mount2 = try await secretsManager.createSecretsMount(
      for: "isolated-2",
      config: config2
    )

    // Container 1 has both secrets
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(mount1.hostPath)/SECRET_ONE"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(mount1.hostPath)/SECRET_TWO"))

    // Container 2 only has SECRET_ONE
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(mount2.hostPath)/SECRET_ONE"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: "\(mount2.hostPath)/SECRET_TWO"))

    try await secretsManager.cleanupMount(for: "isolated-1")
    try await secretsManager.cleanupMount(for: "isolated-2")
  }

  // MARK: - Error Handling Tests

  func testFailWhenEnclaveNotMounted() async {
    let badManager = SecretsMountManager(
      enclavePath: "/nonexistent/enclave",
      logger: Logger(subsystem: "test", category: "integration")
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    do {
      _ = try await badManager.createSecretsMount(
        for: "fail-test",
        config: config
      )
      XCTFail("Should have thrown error")
    } catch let error as SecretsError {
      XCTAssertEqual(error, SecretsError.enclaveNotMounted(path: "/nonexistent/enclave"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testHandleMissingFilteredSecret() async throws {
    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["SECRET_ONE", "NONEXISTENT_SECRET"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let mount = try await secretsManager.createSecretsMount(
      for: "missing-test",
      config: config
    )

    // Should only have SECRET_ONE
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(mount.hostPath)/SECRET_ONE"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: "\(mount.hostPath)/NONEXISTENT_SECRET"))

    try await secretsManager.cleanupMount(for: "missing-test")
  }

  // MARK: - Mount Options Tests

  func testVerifyMountSecurityOptions() async throws {
    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["SECRET_ONE"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let mount = try await secretsManager.createSecretsMount(
      for: "security-test",
      config: config
    )

    // Verify mount options are set (if we can inspect mount)
    // This would require actual mount inspection in production
    XCTAssertEqual(mount.containerPath, "/run/secrets")

    try await secretsManager.cleanupMount(for: "security-test")
  }

  // MARK: - Performance Tests

  func testMountManySecretsPerformance() async throws {
    // Create many secrets
    for i in 0..<50 {
      try? "secret-value-\(i)".write(
        toFile: "\(mockEnclavePath!)/secret_\(i).txt",
        atomically: true,
        encoding: .utf8
      )
    }

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,  // All secrets
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let start = Date()
    let mount = try await secretsManager.createSecretsMount(
      for: "perf-test",
      config: config
    )
    let duration = Date().timeIntervalSince(start)

    // Should complete within 500ms
    XCTAssertLessThan(duration, 0.5, "Mounting 50 secrets took \(duration)s")

    // Verify all secrets present
    var secretCount = 0
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: mount.hostPath) {
      secretCount = contents.count
    }

    XCTAssertEqual(secretCount, 50)

    try await secretsManager.cleanupMount(for: "perf-test")
  }

  // MARK: - Concurrent Tests

  func testHandleConcurrentMounts() async throws {
    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["SECRET_ONE"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    // Create 10 concurrent mounts
    var mounts: [SecretsMount] = []
    await withTaskGroup(of: SecretsMount.self) { group in
      for i in 0..<10 {
        group.addTask {
          try! await self.secretsManager.createSecretsMount(
            for: "concurrent-\(i)",
            config: config
          )
        }
      }

      for await mount in group {
        mounts.append(mount)
      }
    }

    // All 10 should succeed
    XCTAssertEqual(mounts.count, 10)

    // All should have unique paths
    let uniquePaths = Set(mounts.map { $0.hostPath })
    XCTAssertEqual(uniquePaths.count, 10)

    // Cleanup
    for i in 0..<10 {
      try? await secretsManager.cleanupMount(for: "concurrent-\(i)")
    }
  }
}

// MARK: - Test Helpers

extension SecretsError: Equatable {
  public static func == (lhs: SecretsError, rhs: SecretsError) -> Bool {
    switch (lhs, rhs) {
    case (.enclaveNotMounted(let lhsPath), .enclaveNotMounted(let rhsPath)):
      return lhsPath == rhsPath
    case (.mountFailed, .mountFailed):
      return true
    case (.permissionDenied(let lhsSecret), .permissionDenied(let rhsSecret)):
      return lhsSecret == rhsSecret
    default:
      return false
    }
  }
}
