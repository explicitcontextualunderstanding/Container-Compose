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

import Foundation
import OSLog

/// Manages the creation and lifecycle of tmpfs mounts for secrets
public actor SecretsMountManager {
/// Path to the secrets enclave (source)
	public nonisolated(unsafe) let enclavePath: String

  /// Logger for operations
  private let logger: Logger

  /// Active mounts tracked by container ID
  private var activeMounts: [String: SecretsMount] = [:]

  /// Initialize with enclave path and logger
  public init(enclavePath: String = "/Volumes/AGENT_SECRETS", logger: Logger) {
    self.enclavePath = enclavePath
    self.logger = logger
  }

  /// Creates a tmpfs mount with filtered secrets for a container
  public func createSecretsMount(
    for containerID: String,
    config: XAppleSecretsConfig
  ) async throws -> SecretsMount {
    // Phase 1: Validate enclave exists
    guard FileManager.default.fileExists(atPath: enclavePath) else {
      logger.error("Enclave not found at path: \(self.enclavePath)")
      throw SecretsError.enclaveNotMounted(path: enclavePath)
    }

    // Phase 2: Create tmpfs mount point
    let tmpfsPath = "/tmp/container-secrets-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: tmpfsPath,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )

    logger.debug("Created tmpfs mount point: \(tmpfsPath)")

    // Phase 3: Mount tmpfs with security options
    let mountOptions = buildMountOptions(config: config)
    try await mountTmpfs(at: tmpfsPath, options: mountOptions)

    logger.debug("Mounted tmpfs with options: \(mountOptions.joined(separator: ","))")

    // Phase 4: Copy filtered secrets with restricted permissions
    let secrets = try await loadSecrets(filter: config.filter)
    for (name, content) in secrets {
      let destPath = "\(tmpfsPath)/\(name)"
      try content.write(toFile: destPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o400],
        ofItemAtPath: destPath
      )
      logger.debug("Copied secret: \(name)")
    }

    let mount = SecretsMount(
      containerID: containerID,
      hostPath: tmpfsPath,
      containerPath: config.mount,
      cleanupPolicy: config.cleanup,
      secretsCount: secrets.count
    )

    activeMounts[containerID] = mount

    logger.info("Created secrets mount for container \(containerID) with \(secrets.count) secrets")

    // Phase 5: Handle immediate cleanup
    if config.cleanup == .immediate {
      // Schedule cleanup after a brief delay to allow container to start
      Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        try? await cleanupMount(for: containerID)
      }
    }

    return mount
  }

  /// Cleanup mount based on policy
  public func cleanupMount(for containerID: String) async throws {
    guard let mount = activeMounts.removeValue(forKey: containerID) else {
      logger.debug("No active mount found for container: \(containerID)")
      return
    }

    logger.debug("Cleaning up secrets mount for container: \(containerID)")

    // Unmount tmpfs
    try await unmountTmpfs(at: mount.hostPath)

    // Remove directory
    try? FileManager.default.removeItem(atPath: mount.hostPath)

    logger.info("Cleaned up secrets mount for container: \(containerID)")
  }

/// Build mount options based on configuration
public nonisolated func buildMountOptions(config: XAppleSecretsConfig) -> [String] {
var options: [String] = []
#if os(Linux)
options.append("size=1m")
options.append("mode=0400")
#else
// macOS: tmpfs doesn't support -o mode. Permissions set via chmod after mount.
// size is also not supported on macOS tmpfs
#endif
if config.noexec { options.append("noexec") }
if config.nosuid { options.append("nosuid") }
return options
}

  /// Load secrets from enclave with optional filtering
  public func loadSecrets(filter: [String]?) async throws -> [String: String] {
    let fileManager = FileManager.default
    let allFiles = try fileManager.contentsOfDirectory(atPath: enclavePath)

    var result: [String: String] = [:]

    for fileName in allFiles {
      // Extract secret name from filename (e.g., "secret_name.txt" -> "SECRET_NAME")
      let normalizedName = fileName
        .replacingOccurrences(of: ".txt", with: "")
        .uppercased()

      // Apply filter if specified (case-insensitive comparison)
      if let filter = filter {
        let uppercasedFilter = filter.map { $0.uppercased() }
        if !uppercasedFilter.contains(normalizedName) {
          continue
        }
      }

      // Validate secret name format
      guard XAppleSecretsConfig.isValidSecretName(normalizedName) else {
        logger.warning("Skipping invalid secret name: \(normalizedName)")
        continue
      }

      let path = "\(enclavePath)/\(fileName)"
      let content: String
      do {
        content = try String(contentsOfFile: path, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      } catch {
        // Binary or non-UTF8 files: read as Latin1 to preserve bytes
        let data = FileManager.default.contents(atPath: path) ?? Data()
        content = String(data: data, encoding: .isoLatin1) ?? "[binary data]"
      }

      result[normalizedName] = content
    }

    return result
  }

/// Mount tmpfs at the specified path
private func mountTmpfs(at path: String, options: [String]) async throws {
#if os(macOS)
// macOS: Use mount_tmpfs directly with its specific syntax
// usage: mount_tmpfs [-o options] [-i | -e] [-n max_nodes] [-s max_mem_size] <directory>
// Note: macOS mount_tmpfs is restricted to root/superuser in SIP-enabled systems
let task = Process()
task.launchPath = "/sbin/mount_tmpfs"
// Convert our options format to mount_tmpfs format
var args: [String] = []
// Filter out unsupported options - macOS tmpfs doesn't support mode/size via -o
let supportedOptions = options.filter { !$0.hasPrefix("mode=") && !$0.hasPrefix("size=") }
if !supportedOptions.isEmpty {
args.append("-o")
args.append(supportedOptions.joined(separator: ","))
}
args.append(path)
task.arguments = args

let pipe = Pipe()
task.standardOutput = pipe
task.standardError = pipe

try task.run()
task.waitUntilExit()

guard task.terminationStatus == 0 else {
let data = pipe.fileHandleForReading.readDataToEndOfFile()
let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
// Log warning but don't fail - tmpfs may be restricted on macOS
logger.warning("Failed to mount tmpfs (expected on macOS without root): \(errorMessage)")
// On macOS without root, create a regular directory as fallback
try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
// Set restrictive permissions
let chmodTask = Process()
chmodTask.launchPath = "/bin/chmod"
chmodTask.arguments = ["700", path]
try? chmodTask.run()
chmodTask.waitUntilExit()
return
}

// Set restrictive permissions after mount
let chmodTask = Process()
chmodTask.launchPath = "/bin/chmod"
chmodTask.arguments = ["700", path]
try? chmodTask.run()
chmodTask.waitUntilExit()
#else
// Linux: tmpfs supports -o options
let optionsString = options.joined(separator: ",")
let task = Process()
task.launchPath = "/sbin/mount"
task.arguments = ["-t", "tmpfs", "-o", optionsString, "tmpfs", path]

let pipe = Pipe()
task.standardOutput = pipe
task.standardError = pipe

try task.run()
task.waitUntilExit()

guard task.terminationStatus == 0 else {
let data = pipe.fileHandleForReading.readDataToEndOfFile()
let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
logger.error("Failed to mount tmpfs: \(errorMessage)")
throw SecretsError.mountFailed(underlying: NSError(domain: "MountError", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMessage]))
}
#endif
}

  /// Unmount tmpfs at the specified path
  private func unmountTmpfs(at path: String) async throws {
    let task = Process()
    task.launchPath = "/sbin/umount"
    task.arguments = [path]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe

    try task.run()
    task.waitUntilExit()

    // Ignore errors - mount may already be unmounted
    if task.terminationStatus != 0 {
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
      logger.debug("Unmount warning (may already be unmounted): \(errorMessage)")
    }
  }
}

/// Represents an active secrets mount
public struct SecretsMount: Hashable, Sendable {
  public let containerID: String
  public let hostPath: String
  public let containerPath: String
  public let cleanupPolicy: XAppleSecretsConfig.CleanupPolicy
  public let secretsCount: Int

  public init(
    containerID: String,
    hostPath: String,
    containerPath: String,
    cleanupPolicy: XAppleSecretsConfig.CleanupPolicy,
    secretsCount: Int
  ) {
    self.containerID = containerID
    self.hostPath = hostPath
    self.containerPath = containerPath
    self.cleanupPolicy = cleanupPolicy
    self.secretsCount = secretsCount
  }
}

/// Errors that can occur during secrets mount operations
public enum SecretsError: Error, Equatable {
  case enclaveNotMounted(path: String)
  case mountFailed(underlying: Error)
  case permissionDenied(secret: String)

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

// MARK: - Logger Extension

extension Logger {
  func debug(_ message: String) {
    self.log(level: .debug, "\(message)")
  }

  func info(_ message: String) {
    self.log(level: .info, "\(message)")
  }

  func warning(_ message: String) {
    self.log(level: .default, "\(message)")
  }

  func error(_ message: String) {
    self.log(level: .fault, "\(message)")
  }
}
