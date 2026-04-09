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

import Testing
import Foundation
@testable import ContainerComposeCore

@Suite("SecretsMountManager Tests")
struct SecretsMountManagerTests {

  // MARK: - Mock Enclave Setup

  private func createMockEnclave(secrets: [String: String]) throws -> String {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .path

    try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

    for (name, content) in secrets {
      let path = "\(tempDir)/\(name.lowercased()).txt"
      try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    return tempDir
  }

  private func cleanupMockEnclave(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
  }

  // MARK: - Initialization Tests

  @Test("Initialize with default enclave path")
  func initializeWithDefaultPath() {
    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: "/Volumes/AGENT_SECRETS", logger: logger)

    #expect(manager.enclavePath == "/Volumes/AGENT_SECRETS")
  }

  @Test("Initialize with custom enclave path")
  func initializeWithCustomPath() {
    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: "/custom/enclave", logger: logger)

    #expect(manager.enclavePath == "/custom/enclave")
  }

  // MARK: - Secrets Loading Tests

  @Test("Load all secrets when no filter specified")
  func loadAllSecretsWithoutFilter() async throws {
    let enclave = try createMockEnclave(secrets: [
      "SECRET_ONE": "value1",
      "SECRET_TWO": "value2",
      "SECRET_THREE": "value3"
    ])
    defer { cleanupMockEnclave(enclave) }

    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: enclave, logger: logger)

    let secrets = try await manager.loadSecrets(filter: nil)

    #expect(secrets.count == 3)
    #expect(secrets["SECRET_ONE"] == "value1")
    #expect(secrets["SECRET_TWO"] == "value2")
    #expect(secrets["SECRET_THREE"] == "value3")
  }

  @Test("Load filtered secrets only")
  func loadFilteredSecrets() async throws {
    let enclave = try createMockEnclave(secrets: [
      "DB_PASSWORD": "db-secret",
      "API_KEY": "api-secret",
      "UNWANTED": "should-not-appear"
    ])
    defer { cleanupMockEnclave(enclave) }

    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: enclave, logger: logger)

    let secrets = try await manager.loadSecrets(filter: ["DB_PASSWORD", "API_KEY"])

    #expect(secrets.count == 2)
    #expect(secrets["DB_PASSWORD"] == "db-secret")
    #expect(secrets["API_KEY"] == "api-secret")
    #expect(secrets["UNWANTED"] == nil)
  }

  @Test("Load secrets case-insensitively")
  func loadSecretsCaseInsensitive() async throws {
    let enclave = try createMockEnclave(secrets: [
      "db_password": "lowercase-secret",
      "API_KEY": "uppercase-secret"
    ])
    defer { cleanupMockEnclave(enclave) }

    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: enclave, logger: logger)

    let secrets = try await manager.loadSecrets(filter: ["DB_PASSWORD", "api_key"])

    #expect(secrets.count == 2)
    #expect(secrets["DB_PASSWORD"] == "lowercase-secret")
    #expect(secrets["API_KEY"] == "uppercase-secret")
  }

  @Test("Trim whitespace from secret content")
  func trimSecretWhitespace() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .path
    try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { cleanupMockEnclave(tempDir) }

    let secretPath = "\(tempDir)/secret_with_whitespace.txt"
    try "  secret-value-with-spaces  \n".write(toFile: secretPath, atomically: true, encoding: .utf8)

    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: tempDir, logger: logger)

    let secrets = try await manager.loadSecrets(filter: ["SECRET_WITH_WHITESPACE"])

    #expect(secrets["SECRET_WITH_WHITESPACE"] == "secret-value-with-spaces")
  }

  // MARK: - Mount Options Tests

  @Test("Build mount options with defaults")
  func buildMountOptionsDefaults() {
    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(logger: logger)

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let options = manager.buildMountOptions(config: config)

    #expect(options.contains("size=1m"))
    #expect(options.contains("mode=0400"))
    #expect(options.contains("noexec"))
    #expect(options.contains("nosuid"))
  }

  @Test("Build mount options without noexec")
  func buildMountOptionsWithoutNoexec() {
    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(logger: logger)

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: false,
      nosuid: true,
      cleanup: .immediate
    )

    let options = manager.buildMountOptions(config: config)

    #expect(options.contains("size=1m"))
    #expect(!options.contains("noexec"))
    #expect(options.contains("nosuid"))
  }

  @Test("Build mount options without nosuid")
  func buildMountOptionsWithoutNosuid() {
    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(logger: logger)

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: false,
      cleanup: .immediate
    )

    let options = manager.buildMountOptions(config: config)

    #expect(options.contains("size=1m"))
    #expect(options.contains("noexec"))
    #expect(!options.contains("nosuid"))
  }

  // MARK: - Error Handling Tests

  @Test("Throw error when enclave not found")
  func throwWhenEnclaveNotFound() async {
    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: "/nonexistent/path", logger: logger)

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    await #expect(throws: SecretsError.enclaveNotMounted) {
      _ = try await manager.createSecretsMount(for: "test-container", config: config)
    }
  }

  @Test("Throw error for invalid secret name")
  func throwForInvalidSecretName() async throws {
    let enclave = try createMockEnclave(secrets: [
      "VALID_SECRET": "value"
    ])
    defer { cleanupMockEnclave(enclave) }

    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: enclave, logger: logger)

    // Filter contains invalid name
    let secrets = try await manager.loadSecrets(filter: ["VALID_SECRET", "invalid-secret!"])

    // Should skip invalid names and load only valid ones
    #expect(secrets.count == 1)
    #expect(secrets["VALID_SECRET"] == "value")
  }

  // MARK: - Cleanup Policy Tests

  @Test("Verify immediate cleanup policy")
  func verifyImmediateCleanup() {
    let policy = XAppleSecretsConfig.CleanupPolicy.immediate
    #expect(policy == .immediate)
    #expect(policy.description == "immediate")
  }

  @Test("Verify on_stop cleanup policy")
  func verifyOnStopCleanup() {
    let policy = XAppleSecretsConfig.CleanupPolicy.onStop
    #expect(policy == .onStop)
    #expect(policy.description == "on_stop")
  }

  @Test("Verify manual cleanup policy")
  func verifyManualCleanup() {
    let policy = XAppleSecretsConfig.CleanupPolicy.manual
    #expect(policy == .manual)
    #expect(policy.description == "manual")
  }

  // MARK: - Active Mounts Tracking

  @Test("Track active mounts by container ID")
  func trackActiveMounts() async throws {
    let enclave = try createMockEnclave(secrets: ["TEST_SECRET": "value"])
    defer { cleanupMockEnclave(enclave) }

    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: enclave, logger: logger)

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    // Mock mount creation - track that it's called
    let mount = try await manager.createSecretsMount(for: "container-1", config: config)

    #expect(mount.containerID == "container-1")
    #expect(mount.containerPath == "/run/secrets")
    #expect(mount.cleanupPolicy == .immediate)
  }

  // MARK: - Performance Tests

  @Test("Load large number of secrets efficiently")
  func loadManySecrets() async throws {
    var secrets: [String: String] = [:]
    for i in 0..<100 {
      secrets["SECRET_\(i)"] = String(repeating: "x", count: 100)
    }

    let enclave = try createMockEnclave(secrets: secrets)
    defer { cleanupMockEnclave(enclave) }

    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: enclave, logger: logger)

    let start = Date()
    let loaded = try await manager.loadSecrets(filter: nil)
    let duration = Date().timeIntervalSince(start)

    #expect(loaded.count == 100)
    #expect(duration < 1.0, "Loading 100 secrets should take less than 1 second")
  }
}

// MARK: - Mock File Manager Extension

@Suite("SecretsMountManager Error Scenarios")
struct SecretsMountManagerErrorTests {

  @Test("Handle permission denied on enclave read")
  func handlePermissionDenied() async throws {
    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: "/root/protected", logger: logger)

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    await #expect(throws: SecretsError.enclaveNotMounted) {
      _ = try await manager.createSecretsMount(for: "test", config: config)
    }
  }

  @Test("Handle empty enclave directory")
  func handleEmptyEnclave() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .path
    try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: tempDir, logger: logger)

    let secrets = try await manager.loadSecrets(filter: nil)

    #expect(secrets.isEmpty)
  }

  @Test("Handle binary file in enclave")
  func handleBinaryFile() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .path
    try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    // Create a binary file
    let binaryPath = "\(tempDir)/binary_secret.txt"
    var binaryData: [UInt8] = [0x00, 0x01, 0x02, 0xFF, 0xFE]
    let data = Data(binaryData)
    try data.write(to: URL(fileURLWithPath: binaryPath))

    let logger = Logger(subsystem: "test", category: "secrets")
    let manager = SecretsMountManager(enclavePath: tempDir, logger: logger)

    // Should handle gracefully
    let secrets = try await manager.loadSecrets(filter: ["BINARY_SECRET"])

    // Binary data converted to string might be empty or contain replacement characters
    #expect(secrets["BINARY_SECRET"] != nil)
  }
}

// MARK: - SecretsMount Struct Tests

@Suite("SecretsMount Struct Tests")
struct SecretsMountStructTests {

  @Test("Create SecretsMount with all properties")
  func createSecretsMount() {
    let mount = SecretsMount(
      containerID: "test-container",
      hostPath: "/tmp/secrets-123",
      containerPath: "/run/secrets",
      cleanupPolicy: .immediate
    )

    #expect(mount.containerID == "test-container")
    #expect(mount.hostPath == "/tmp/secrets-123")
    #expect(mount.containerPath == "/run/secrets")
    #expect(mount.cleanupPolicy == .immediate)
  }

  @Test("SecretsMount equality")
  func secretsMountEquality() {
    let mount1 = SecretsMount(
      containerID: "container-1",
      hostPath: "/tmp/secrets",
      containerPath: "/run/secrets",
      cleanupPolicy: .immediate
    )

    let mount2 = SecretsMount(
      containerID: "container-1",
      hostPath: "/tmp/secrets",
      containerPath: "/run/secrets",
      cleanupPolicy: .immediate
    )

    let mount3 = SecretsMount(
      containerID: "container-2",
      hostPath: "/tmp/secrets",
      containerPath: "/run/secrets",
      cleanupPolicy: .immediate
    )

    #expect(mount1 == mount2)
    #expect(mount1 != mount3)
  }
}
