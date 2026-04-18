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
import TestHelpers
@testable import Yams
@testable import ContainerComposeCore

final class XAppleSecretsParserTests: XCTestCase {

  // MARK: - Basic Parsing Tests

  func testLegacyParseMinimalConfig() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        web:
          image: nginx:latest
          x-apple-secrets:
            mount: /run/secrets
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let service = try XCTUnwrap(compose.services["web"])
    let secretsConfig = try XCTUnwrap(service?.x_apple_secrets)

    XCTAssertEqual(secretsConfig.mount, "/run/secrets")
    XCTAssertNil(secretsConfig.filter)
    XCTAssertTrue(secretsConfig.readOnly)
    XCTAssertTrue(secretsConfig.noexec)
    XCTAssertTrue(secretsConfig.nosuid)
    XCTAssertEqual(secretsConfig.cleanup, .immediate)
  }

  func testLegacyParseWithFilter() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        db:
          image: postgres:14
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - DB_PASSWORD
              - API_KEY
              - SECRET_TOKEN
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let service = try XCTUnwrap(compose.services["db"])
    let secretsConfig = try XCTUnwrap(service?.x_apple_secrets)

    XCTAssertEqual(secretsConfig.mount, "/run/secrets")
    XCTAssertEqual(secretsConfig.filter?.count, 3)
    XCTAssertTrue(secretsConfig.filter?.contains("DB_PASSWORD") ?? false)
    XCTAssertTrue(secretsConfig.filter?.contains("API_KEY") ?? false)
    XCTAssertTrue(secretsConfig.filter?.contains("SECRET_TOKEN") ?? false)
  }

  func testLegacyParseWithCustomSecurityOptions() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        app:
          image: myapp:latest
          x-apple-secrets:
            mount: /secrets
            read_only: false
            noexec: false
            nosuid: false
            cleanup: on_stop
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let service = try XCTUnwrap(compose.services["app"])
    let secretsConfig = try XCTUnwrap(service?.x_apple_secrets)

    XCTAssertEqual(secretsConfig.mount, "/secrets")
    XCTAssertFalse(secretsConfig.readOnly)
    XCTAssertFalse(secretsConfig.noexec)
    XCTAssertFalse(secretsConfig.nosuid)
    XCTAssertEqual(secretsConfig.cleanup, .onStop)
  }

  func testLegacyParseWithManualCleanup() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        worker:
          image: worker:latest
          x-apple-secrets:
            mount: /run/secrets
            cleanup: manual
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let service = try XCTUnwrap(compose.services["worker"])
    let secretsConfig = try XCTUnwrap(service?.x_apple_secrets)

    XCTAssertEqual(secretsConfig.cleanup, .manual)
  }

  // MARK: - Default Value Tests

  func testLegacyVerifyNoSecretsConfig() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        web:
          image: nginx:latest
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let service = try XCTUnwrap(compose.services["web"])
    XCTAssertNil(service?.x_apple_secrets)
  }

  func testLegacyVerifyDefaultMount() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        app:
          image: alpine:latest
          x-apple-secrets:
            filter:
              - TOKEN
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let service = try XCTUnwrap(compose.services["app"])
    let secretsConfig = try XCTUnwrap(service?.x_apple_secrets)

    XCTAssertEqual(secretsConfig.mount, "/run/secrets")
  }

  // MARK: - Multiple Services Tests

  func testLegacyParseMultipleServicesWithSecrets() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        web:
          image: nginx:latest
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - NGINX_CERT
              - NGINX_KEY
        db:
          image: postgres:14
          x-apple-secrets:
            mount: /var/run/db-secrets
            filter:
              - DB_PASSWORD
              - DB_USER
        cache:
          image: redis:alpine
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // Web service secrets
    let webService = try XCTUnwrap(compose.services["web"])
    let webSecrets = try XCTUnwrap(webService?.x_apple_secrets)
    XCTAssertEqual(webSecrets.mount, "/run/secrets")
    XCTAssertEqual(webSecrets.filter?.count, 2)
    XCTAssertTrue(webSecrets.filter?.contains("NGINX_CERT") ?? false)

    // DB service secrets
    let dbService = try XCTUnwrap(compose.services["db"])
    let dbSecrets = try XCTUnwrap(dbService?.x_apple_secrets)
    XCTAssertEqual(dbSecrets.mount, "/var/run/db-secrets")
    XCTAssertEqual(dbSecrets.filter?.count, 2)
    XCTAssertTrue(dbSecrets.filter?.contains("DB_PASSWORD") ?? false)

    // Cache service has no secrets
    let cacheService = try XCTUnwrap(compose.services["cache"])
    XCTAssertNil(cacheService?.x_apple_secrets)
  }

  // MARK: - Global Configuration Tests

  func testLegacyParseGlobalConfig() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      x-apple-secrets:
        version: "1.0"
        enclave: /Volumes/AGENT_SECRETS
        default_mount: /run/secrets
        format: files
        permissions: "0400"
        cleanup: immediate
      services:
        app:
          image: myapp:latest
          x-apple-secrets:
            filter:
              - API_KEY
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let globalConfig = try XCTUnwrap(compose.xAppleSecretsGlobal)
    XCTAssertEqual(globalConfig.version, "1.0")
    XCTAssertEqual(globalConfig.enclave, "/Volumes/AGENT_SECRETS")
    XCTAssertEqual(globalConfig.defaultMount, "/run/secrets")
    XCTAssertEqual(globalConfig.format, .files)
    XCTAssertEqual(globalConfig.permissions, "0400")
    XCTAssertEqual(globalConfig.cleanup, .immediate)
  }

  // MARK: - Edge Cases

  func testLegacyParseWithEmptyFilter() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        app:
          image: alpine:latest
          x-apple-secrets:
            mount: /run/secrets
            filter: []
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let service = try XCTUnwrap(compose.services["app"])
    let secretsConfig = try XCTUnwrap(service?.x_apple_secrets)

    XCTAssertTrue(secretsConfig.filter?.isEmpty ?? false)
  }

  func testLegacyParseWithComplexMountPath() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        app:
          image: alpine:latest
          x-apple-secrets:
            mount: /very/deep/nested/path/to/secrets
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let service = try XCTUnwrap(compose.services["app"])
    let secretsConfig = try XCTUnwrap(service?.x_apple_secrets)

    XCTAssertEqual(secretsConfig.mount, "/very/deep/nested/path/to/secrets")
  }

  // MARK: - Honcho Stack Configuration Tests

  func testLegacyParseHonchoDBConfig() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        test-db:
          image: walg-db:vsock
          x-apple-relays:
            - type: vsock-db
              port: 5432
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - HONCHO_DB_PASSWORD
              - WALG_AWS_ACCESS_KEY_ID
              - WALG_AWS_SECRET_ACCESS_KEY
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbService = try XCTUnwrap(compose.services["test-db"])
    let secretsConfig = try XCTUnwrap(dbService?.x_apple_secrets)

    XCTAssertEqual(secretsConfig.mount, "/run/secrets")
    XCTAssertEqual(secretsConfig.filter?.count, 3)
    XCTAssertTrue(secretsConfig.filter?.contains("HONCHO_DB_PASSWORD") ?? false)
    XCTAssertTrue(secretsConfig.filter?.contains("WALG_AWS_ACCESS_KEY_ID") ?? false)
    XCTAssertTrue(secretsConfig.filter?.contains("WALG_AWS_SECRET_ACCESS_KEY") ?? false)
  }

  func testLegacyParseHonchoHubConfig() throws {
    try skipIfLegacyValidationDisabled()
    let yaml = """
      version: '3.8'
      services:
        test-hub:
          image: honcho:latest
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - HONCHO_ADMIN_TOKEN
              - LLM_ANTHROPIC_API_KEY
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let hubService = try XCTUnwrap(compose.services["test-hub"])
    let secretsConfig = try XCTUnwrap(hubService?.x_apple_secrets)

    XCTAssertTrue(secretsConfig.filter?.contains("HONCHO_ADMIN_TOKEN") ?? false)
    XCTAssertTrue(secretsConfig.filter?.contains("LLM_ANTHROPIC_API_KEY") ?? false)
  }
}

// MARK: - XAppleSecretsConfig Validation Tests

final class XAppleSecretsConfigValidationTests: XCTestCase {

  func testLegacyValidateCleanupPolicy() throws {
    try skipIfLegacyValidationDisabled()
    XCTAssertEqual(XAppleSecretsConfig.CleanupPolicy.immediate.rawValue, "immediate")
    XCTAssertEqual(XAppleSecretsConfig.CleanupPolicy.onStop.rawValue, "on_stop")
    XCTAssertEqual(XAppleSecretsConfig.CleanupPolicy.manual.rawValue, "manual")
  }

  func testLegacyValidateFormatEnum() throws {
    try skipIfLegacyValidationDisabled()
    XCTAssertEqual(XAppleSecretsGlobalConfig.Format.files.rawValue, "files")
  }

  func testLegacyValidateAbsolutePath() throws {
    try skipIfLegacyValidationDisabled()
    let validPaths = ["/run/secrets", "/var/lib/secrets", "/tmp/test"]
    let invalidPaths = ["relative/path", "secrets", "./secrets"]

    for path in validPaths {
      XCTAssertTrue(XAppleSecretsConfig.isValidMountPath(path), "Path \(path) should be valid")
    }

    for path in invalidPaths {
      XCTAssertFalse(XAppleSecretsConfig.isValidMountPath(path), "Path \(path) should be invalid")
    }
  }

  func testLegacyValidateSecretNameFormat() throws {
    try skipIfLegacyValidationDisabled()
    let validNames = ["SECRET", "API_KEY", "DB_PASSWORD_123", "test_name"]
    let invalidNames = ["secret!", "api-key", "123starts", "with space", ""]

    for name in validNames {
      XCTAssertTrue(XAppleSecretsConfig.isValidSecretName(name), "Name \(name) should be valid")
    }

    for name in invalidNames {
      XCTAssertFalse(XAppleSecretsConfig.isValidSecretName(name), "Name \(name) should be invalid")
    }
  }
}
