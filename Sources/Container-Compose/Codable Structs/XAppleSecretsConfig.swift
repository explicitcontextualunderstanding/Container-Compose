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

/// Configuration for x-apple-secrets extension at service level
public struct XAppleSecretsConfig: Codable, Hashable, Sendable {
  /// Container mount point for secrets
  public let mount: String

  /// List of secret names to include (nil means all)
  public let filter: [String]?

  /// Mount read-only (default: true)
  public let readOnly: Bool

  /// No execution bit (default: true)
  public let noexec: Bool

  /// No setuid bit (default: true)
  public let nosuid: Bool

  /// Cleanup policy (default: immediate)
  public let cleanup: CleanupPolicy

  /// Cleanup policy options
  public enum CleanupPolicy: String, Codable, Hashable, Sendable {
    case immediate
    case onStop = "on_stop"
    case manual
  }

  enum CodingKeys: String, CodingKey {
    case mount
    case filter
    case readOnly = "read_only"
    case noexec
    case nosuid
    case cleanup
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    
    // Decode mount path and validate it's absolute
    let decodedMount = try container.decodeIfPresent(String.self, forKey: .mount) ?? "/run/secrets"
    guard XAppleSecretsConfig.isValidMountPath(decodedMount) else {
      throw DecodingError.dataCorruptedError(
        forKey: .mount,
        in: container,
        debugDescription: "Mount path must be absolute (start with /) and not contain '..' or '~'. Got: \(decodedMount)"
      )
    }
    self.mount = decodedMount
    
    // Decode filter and validate secret names
    let decodedFilter = try container.decodeIfPresent([String].self, forKey: .filter)
    if let filter = decodedFilter {
      for secretName in filter {
        guard XAppleSecretsConfig.isValidSecretName(secretName) else {
          throw DecodingError.dataCorruptedError(
            forKey: .filter,
            in: container,
            debugDescription: "Secret name '\(secretName)' is invalid. Must start with letter or underscore, followed by alphanumeric or underscore characters."
          )
        }
      }
    }
    self.filter = decodedFilter
    
    self.readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
    self.noexec = try container.decodeIfPresent(Bool.self, forKey: .noexec) ?? true
    self.nosuid = try container.decodeIfPresent(Bool.self, forKey: .nosuid) ?? true
    self.cleanup = try container.decodeIfPresent(CleanupPolicy.self, forKey: .cleanup) ?? .immediate
  }

  public init(
    mount: String = "/run/secrets",
    filter: [String]? = nil,
    readOnly: Bool = true,
    noexec: Bool = true,
    nosuid: Bool = true,
    cleanup: CleanupPolicy = .immediate
  ) {
    self.mount = mount
    self.filter = filter
    self.readOnly = readOnly
    self.noexec = noexec
    self.nosuid = nosuid
    self.cleanup = cleanup
  }

  /// Validates the mount path is absolute
  public static func isValidMountPath(_ path: String) -> Bool {
    return path.hasPrefix("/") && !path.contains("..") && !path.contains("~")
  }

  /// Validates secret name format (alphanumeric + underscore)
  public static func isValidSecretName(_ name: String) -> Bool {
    let pattern = "^[A-Za-z_][A-Za-z0-9_]*$"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return false
    }
    let range = NSRange(location: 0, length: name.utf16.count)
    return regex.firstMatch(in: name, options: [], range: range) != nil
  }
}

/// Global x-apple-secrets configuration
public struct XAppleSecretsGlobalConfig: Codable, Hashable, Sendable {
  /// Version of the extension
  public let version: String

  /// Source enclave path
  public let enclave: String

  /// Default mount point for services
  public let defaultMount: String

  /// Secret format
  public let format: Format

  /// Default file permissions
  public let permissions: String

  /// Default cleanup policy
  public let cleanup: XAppleSecretsConfig.CleanupPolicy

  /// Secret format options
  public enum Format: String, Codable, Hashable, Sendable {
    case files
  }

  enum CodingKeys: String, CodingKey {
    case version
    case enclave
    case defaultMount = "default_mount"
    case format
    case permissions
    case cleanup
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
    self.enclave = try container.decodeIfPresent(String.self, forKey: .enclave) ?? "/Volumes/AGENT_SECRETS"
    self.defaultMount = try container.decodeIfPresent(String.self, forKey: .defaultMount) ?? "/run/secrets"
    self.format = try container.decodeIfPresent(Format.self, forKey: .format) ?? .files
    self.permissions = try container.decodeIfPresent(String.self, forKey: .permissions) ?? "0400"
    self.cleanup = try container.decodeIfPresent(XAppleSecretsConfig.CleanupPolicy.self, forKey: .cleanup) ?? .immediate
  }

  public init(
    version: String = "1.0",
    enclave: String = "/Volumes/AGENT_SECRETS",
    defaultMount: String = "/run/secrets",
    format: Format = .files,
    permissions: String = "0400",
    cleanup: XAppleSecretsConfig.CleanupPolicy = .immediate
  ) {
    self.version = version
    self.enclave = enclave
    self.defaultMount = defaultMount
    self.format = format
    self.permissions = permissions
    self.cleanup = cleanup
  }
}

// MARK: - CustomStringConvertible

extension XAppleSecretsConfig.CleanupPolicy: CustomStringConvertible {
  public var description: String {
    return rawValue
  }
}
