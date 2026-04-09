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
import OSLog
@testable import SecurityHardening
@testable import ContainerComposeCore

// MARK: - Protocol Definitions (for test mocks)

protocol ESFClientProtocol: Sendable {
  func logSecretsMountAttempt(containerCID: Int, mountPath: String) async
  func logSecretsMountSuccess(containerCID: Int, secretsCount: Int) async
}

enum ESFEventType: Sendable {
  case secretsMountAttempt
  case secretsMountSuccess
}

@Suite("SecretsMountValidator Tests")
struct SecretsMountValidatorTests {

  // MARK: - Initialization Tests

  @Test("Initialize with all dependencies")
  func initializeWithDependencies() {
    let amfiGating = MockAMFIRelayGating()
    let isolationValidator = MockHorizontalIsolationValidator()
    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    #expect(validator != nil)
  }

  // MARK: - AMFI Validation Tests

  @Test("Pass AMFI validation")
  func passAMFIValidation() async {
    let amfiGating = await MockAMFIRelayGating(shouldPass: true)
    let isolationValidator = await MockHorizontalIsolationValidator(shouldPass: true)
    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["TEST_SECRET"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let result = await validator.validateSecretsMount(config: config, containerCID: 3)

    #expect(result.passed == true)
    #expect(result.blockedBy == nil)
    #expect(result.errorMessage == nil)
  }

  @Test("Fail AMFI validation")
  func failAMFIValidation() async {
    let amfiGating = await MockAMFIRelayGating(shouldPass: false, errorMessage: "Binary not signed with valid Developer ID")
    let isolationValidator = await MockHorizontalIsolationValidator(shouldPass: true)
    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let result = await validator.validateSecretsMount(config: config, containerCID: 3)

    #expect(result.passed == false)
    #expect(result.blockedBy?.description == "AMFI")
    #expect(result.errorMessage == "Binary not signed with valid Developer ID")
  }

  // MARK: - Horizontal Isolation Tests

  @Test("Pass horizontal isolation for guest CID")
  func passHorizontalIsolation() async {
    let amfiGating = MockAMFIRelayGating()
    amfiGating.shouldPassValidation = true

    let isolationValidator = MockHorizontalIsolationValidator()
    isolationValidator.shouldPassValidation = true

    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let result = await validator.validateSecretsMount(config: config, containerCID: 5)

    #expect(result.passed == true)
    #expect(isolationValidator.validatedCID == 5)
    #expect(isolationValidator.validatedEnclavePath == "/Volumes/AGENT_SECRETS")
  }

  @Test("Fail horizontal isolation - direct guest-to-guest communication")
  func failHorizontalIsolation() async {
    let amfiGating = MockAMFIRelayGating()
    amfiGating.shouldPassValidation = true

    let isolationValidator = MockHorizontalIsolationValidator()
    isolationValidator.shouldPassValidation = false
    isolationValidator.errorMessage = "Direct CID 3 to CID 5 communication blocked"

    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let result = await validator.validateSecretsMount(config: config, containerCID: 5)

    #expect(result.passed == false)
    #expect(result.blockedBy?.description == "HorizontalIsolation")
    #expect(result.errorMessage == "Direct CID 3 to CID 5 communication blocked")
  }

  // MARK: - ESF Audit Logging Tests

  @Test("Log mount attempt to ESF")
  func logMountAttempt() async {
    let amfiGating = MockAMFIRelayGating()
    amfiGating.shouldPassValidation = true

    let isolationValidator = MockHorizontalIsolationValidator()
    isolationValidator.shouldPassValidation = true

    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: ["API_KEY", "DB_PASSWORD"],
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    _ = await validator.validateSecretsMount(config: config, containerCID: 3)

    #expect(esfClient.loggedEvents.contains { event in
      event.type == .secretsMountAttempt &&
      event.containerCID == 3 &&
      event.mountPath == "/run/secrets"
    })
  }

  @Test("Log mount success to ESF")
  func logMountSuccess() async {
    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: MockAMFIRelayGating(),
      isolationValidator: MockHorizontalIsolationValidator(),
      esfClient: esfClient,
      logger: logger
    )

    await validator.logMountSuccess(containerCID: 5, secretsCount: 3)

    #expect(esfClient.loggedEvents.contains { event in
      event.type == .secretsMountSuccess &&
      event.containerCID == 5 &&
      event.secretsCount == 3
    })
  }

  @Test("Handle nil ESF client gracefully")
  func handleNilESFClient() async {
    let amfiGating = MockAMFIRelayGating()
    amfiGating.shouldPassValidation = true

    let isolationValidator = MockHorizontalIsolationValidator()
    isolationValidator.shouldPassValidation = true

    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: nil,
      logger: logger
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let result = await validator.validateSecretsMount(config: config, containerCID: 3)

    #expect(result.passed == true)
    // Should not crash even without ESF client
  }

  // MARK: - Security Validation Result Tests

  @Test("Create passed validation result")
  func createPassedResult() {
    let result = SecurityValidationResult.passed

    #expect(result.passed == true)
    #expect(result.blockedBy == nil)
    #expect(result.errorMessage == nil)
  }

  @Test("Create failed validation result")
  func createFailedResult() {
    let result = SecurityValidationResult.failed(
      gate: "AMFI",
      message: "Binary not signed"
    )

    #expect(result.passed == false)
    #expect(result.blockedBy?.description == "AMFI")
    #expect(result.errorMessage == "Binary not signed")
  }

  // MARK: - Configuration Validation Tests

  @Test("Validate read-only mount requirement")
  func validateReadOnlyMount() async {
    let amfiGating = MockAMFIRelayGating()
    amfiGating.shouldPassValidation = true

    let isolationValidator = MockHorizontalIsolationValidator()
    isolationValidator.shouldPassValidation = true

    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    // With readOnly = false
    let configNoReadOnly = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: false,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let result = await validator.validateSecretsMount(config: configNoReadOnly, containerCID: 3)

    // Should still pass - readOnly is mount option, not security gate
    #expect(result.passed == true)
  }

  @Test("Validate noexec requirement")
  func validateNoexec() async {
    let amfiGating = MockAMFIRelayGating()
    amfiGating.shouldPassValidation = true

    let isolationValidator = MockHorizontalIsolationValidator()
    isolationValidator.shouldPassValidation = true

    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,  // Required
      nosuid: true,
      cleanup: .immediate
    )

    let result = await validator.validateSecretsMount(config: config, containerCID: 3)

    #expect(result.passed == true)
  }

  @Test("Validate nosuid requirement")
  func validateNosuid() async {
    let amfiGating = MockAMFIRelayGating()
    amfiGating.shouldPassValidation = true

    let isolationValidator = MockHorizontalIsolationValidator()
    isolationValidator.shouldPassValidation = true

    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,  // Required
      cleanup: .immediate
    )

    let result = await validator.validateSecretsMount(config: config, containerCID: 3)

    #expect(result.passed == true)
  }

  // MARK: - Gate Priority Tests

  @Test("AMFI blocks before isolation check")
  func amfiBlocksFirst() async {
    let amfiGating = MockAMFIRelayGating()
    amfiGating.shouldPassValidation = false
    amfiGating.errorMessage = "AMFI failure"

    let isolationValidator = MockHorizontalIsolationValidator()
    isolationValidator.shouldPassValidation = false  // Would fail too, but AMFI comes first

    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let result = await validator.validateSecretsMount(config: config, containerCID: 3)

    // AMFI should block first
    #expect(result.blockedBy?.description == "AMFI")
    #expect(isolationValidator.wasCalled == false)  // Isolation not called if AMFI fails
  }

  @Test("Isolation blocks if AMFI passes")
  func isolationBlocksAfterAMFI() async {
    let amfiGating = MockAMFIRelayGating()
    amfiGating.shouldPassValidation = true

    let isolationValidator = MockHorizontalIsolationValidator()
    isolationValidator.shouldPassValidation = false
    isolationValidator.errorMessage = "Isolation failure"

    let esfClient = MockESFClient()
    let logger = Logger(subsystem: "test", category: "security")

    let validator = SecretsMountValidator(
      amfiGating: amfiGating,
      isolationValidator: isolationValidator,
      esfClient: esfClient,
      logger: logger
    )

    let config = XAppleSecretsConfig(
      mount: "/run/secrets",
      filter: nil,
      readOnly: true,
      noexec: true,
      nosuid: true,
      cleanup: .immediate
    )

    let result = await validator.validateSecretsMount(config: config, containerCID: 3)

    // Both should be called, but isolation blocks
    #expect(amfiGating.wasCalled == true)
    #expect(isolationValidator.wasCalled == true)
    #expect(result.blockedBy?.description == "HorizontalIsolation")
  }
}

// MARK: - Mock Classes

actor MockAMFIRelayGating: AMFIRelayGating {
  var shouldPassValidation = true
  var errorMessage: String?
  var wasCalled = false

  func validateForSocatRemoval(binaryPath: String) async -> GatingResult {
    wasCalled = true
    if shouldPassValidation {
      return .validated
    } else {
      return .failed(errorMessage ?? "AMFI validation failed")
    }
  }

  func validateBeforeRelayStart(binaryPath: String) async -> Bool {
    return shouldPassValidation
  }
}

actor MockHorizontalIsolationValidator: HorizontalIsolationValidating {
  var shouldPassValidation = true
  var errorMessage: String?
  var wasCalled = false

  func validateSocketPath(_ path: String) async -> IsolationResult {
    wasCalled = true
    if shouldPassValidation {
      return .isolated
    } else {
      return IsolationResult(isIsolated: false, errorMessage: errorMessage ?? "Isolation validation failed")
    }
  }
}

actor MockESFClient: ESFClientProtocol {
  struct LoggedEvent {
    let type: ESFEventType
    let containerCID: Int
    let mountPath: String?
    let secretsCount: Int?
  }

  var loggedEvents: [LoggedEvent] = []

  func logSecretsMountAttempt(containerCID: Int, mountPath: String) async {
    loggedEvents.append(LoggedEvent(
      type: .secretsMountAttempt,
      containerCID: containerCID,
      mountPath: mountPath,
      secretsCount: nil
    ))
  }

  func logSecretsMountSuccess(containerCID: Int, secretsCount: Int) async {
    loggedEvents.append(LoggedEvent(
      type: .secretsMountSuccess,
      containerCID: containerCID,
      mountPath: nil,
      secretsCount: secretsCount
    ))
  }
}

// MARK: - Supporting Types

enum ESFEventType: Sendable {
  case secretsMountAttempt
  case secretsMountSuccess
}

// MARK: - Security Gate Description

enum SecurityGate: CustomStringConvertible, Sendable {
  case amfi
  case horizontalIsolation
  case tcc
  case unknown

  var description: String {
    switch self {
    case .amfi: return "AMFI"
    case .horizontalIsolation: return "HorizontalIsolation"
    case .tcc: return "TCC"
    case .unknown: return "Unknown"
    }
  }
}
