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
import SecurityHardening

/// Validates secrets mounts before container start (Plan 85 integration)
public final class SecretsMountValidator: @unchecked Sendable {
  private let amfiGating: AMFIRelayGating
  private let isolationValidator: HorizontalIsolationValidator
  private let esfClient: ESFClient?
  private let logger: Logger

  public init(
    amfiGating: AMFIRelayGating,
    isolationValidator: HorizontalIsolationValidator,
    esfClient: ESFClient?,
    logger: Logger
  ) {
    self.amfiGating = amfiGating
    self.isolationValidator = isolationValidator
    self.esfClient = esfClient
    self.logger = logger
  }

  /// Validates secrets mount before container startup
  public func validateSecretsMount(
    config: XAppleSecretsConfig,
    containerCID: Int
  ) async -> SecurityValidationResult {
    // Gate 1: AMFI validation (binary must be signed)
    logger.debug("Running AMFI validation for secrets mount")
    let amfiResult = await self.amfiGating.validateForSocatRemoval(binaryPath: "/usr/local/bin/container-compose")
    guard amfiResult.canRemoveSocat else {
      logger.error("AMFI validation failed: \(amfiResult.errorMessage ?? "Unknown")")
      return .failed(gate: .amfi, message: amfiResult.errorMessage ?? "AMFI validation failed")
    }

    // Gate 2: Horizontal isolation (enclave boundaries) - validate socket path
    logger.debug("Running horizontal isolation validation for CID: \(containerCID)")
    let isolationResult = await isolationValidator.validateSocketPath("/Volumes/AGENT_SECRETS")
    guard isolationResult.isIsolated else {
      logger.error("Horizontal isolation validation failed: \(isolationResult.errorMessage ?? "Unknown")")
      return .failed(gate: .horizontalIsolation, message: isolationResult.errorMessage ?? "Isolation validation failed")
    }

    // Gate 3: ESF audit logging
    logger.debug("Logging secrets mount attempt to ESF")
    await esfClient?.logSecretsMountAttempt(
      containerCID: containerCID,
      mountPath: config.mount
    )

    logger.info("Security validation passed for secrets mount")
    return .passed
  }

  /// Logs successful mount for audit
  public func logMountSuccess(
    containerCID: Int,
    secretsCount: Int
  ) async {
    logger.debug("Logging successful mount to ESF")
    await esfClient?.logSecretsMountSuccess(
      containerCID: containerCID,
      secretsCount: secretsCount
    )
  }
}

// MARK: - Security Validation Result

public struct SecurityValidationResult: Equatable, Sendable {
  public let passed: Bool
  public let blockedBy: SecurityGate?
  public let errorMessage: String?

  public static let passed = SecurityValidationResult(
    passed: true,
    blockedBy: nil,
    errorMessage: nil
  )

  public static func failed(gate: SecurityGate, message: String) -> SecurityValidationResult {
    return SecurityValidationResult(
      passed: false,
      blockedBy: gate,
      errorMessage: message
    )
  }
}

// MARK: - Security Gate

public enum SecurityGate: String, CustomStringConvertible, Sendable {
  case amfi = "AMFI"
  case horizontalIsolation = "HorizontalIsolation"
  case tcc = "TCC"
  case unknown = "Unknown"

  public var description: String {
    return rawValue
  }
}

// MARK: - Protocol Extensions

/// Protocol for AMFI gating - matches SecurityHardening.AMFIRelayGating
public protocol AMFIRelayGating: Sendable {
  func validateForSocatRemoval(binaryPath: String) async -> GatingResult
  func validateBeforeRelayStart(binaryPath: String) async -> Bool
}

/// Gating result from SecurityHardening module
public struct GatingResult: Equatable, Sendable {
  public let canRemoveSocat: Bool
  public let isValidated: Bool
  public let errorMessage: String?

  public init(canRemoveSocat: Bool, isValidated: Bool, errorMessage: String? = nil) {
    self.canRemoveSocat = canRemoveSocat
    self.isValidated = isValidated
    self.errorMessage = errorMessage
  }

  public static let validated = GatingResult(canRemoveSocat: true, isValidated: true)
}

/// Protocol for horizontal isolation validation
public protocol HorizontalIsolationValidating: Sendable {
  func validateSocketPath(_ path: String) async -> IsolationResult
}

/// Isolation result from SecurityHardening module
public struct IsolationResult: Equatable, Sendable {
  public let isIsolated: Bool
  public let errorMessage: String?

  public init(isIsolated: Bool, errorMessage: String? = nil) {
    self.isIsolated = isIsolated
    self.errorMessage = errorMessage
  }

  public static let isolated = IsolationResult(isIsolated: true)
}

// MARK: - ESF Client Extension

public extension ESFClient {
  func logSecretsMountAttempt(containerCID: Int, mountPath: String) async {
    // In production, this would write to ESF audit log
    print("[ESF] Secrets mount attempt - CID: \(containerCID), Path: \(mountPath)")
  }

  func logSecretsMountSuccess(containerCID: Int, secretsCount: Int) async {
    // In production, this would write to ESF audit log
    print("[ESF] Secrets mount success - CID: \(containerCID), Count: \(secretsCount)")
  }
}
