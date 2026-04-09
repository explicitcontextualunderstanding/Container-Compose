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
@testable import Yams
@testable import ContainerComposeCore

@Suite("XAppleSecrets Parser Tests")
struct XAppleSecretsParserTests {

  // MARK: - Basic Parsing Tests

  @Test("Parse x-apple-secrets with minimal configuration")
  func parseMinimalConfig() throws {
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

    let service = try #require(compose.services["web"])
    let secretsConfig = try #require(service?.xAppleSecrets)

    #expect(secretsConfig.mount == "/run/secrets")
    #expect(secretsConfig.filter == nil)
    #expect(secretsConfig.readOnly == true)
    #expect(secretsConfig.noexec == true)
    #expect(secretsConfig.nosuid == true)
    #expect(secretsConfig.cleanup == .immediate)
  }

  @Test("Parse x-apple-secrets with filter")
  func parseWithFilter() throws {
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

    let service = try #require(compose.services["db"])
    let secretsConfig = try #require(service?.xAppleSecrets)

    #expect(secretsConfig.mount == "/run/secrets")
    #expect(secretsConfig.filter?.count == 3)
    #expect(secretsConfig.filter?.contains("DB_PASSWORD") == true)
    #expect(secretsConfig.filter?.contains("API_KEY") == true)
    #expect(secretsConfig.filter?.contains("SECRET_TOKEN") == true)
  }

  @Test("Parse x-apple-secrets with custom security options")
  func parseWithCustomSecurityOptions() throws {
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

    let service = try #require(compose.services["app"])
    let secretsConfig = try #require(service?.xAppleSecrets)

    #expect(secretsConfig.mount == "/secrets")
    #expect(secretsConfig.readOnly == false)
    #expect(secretsConfig.noexec == false)
    #expect(secretsConfig.nosuid == false)
    #expect(secretsConfig.cleanup == .onStop)
  }

  @Test("Parse x-apple-secrets with manual cleanup policy")
  func parseWithManualCleanup() throws {
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

    let service = try #require(compose.services["worker"])
    let secretsConfig = try #require(service?.xAppleSecrets)

    #expect(secretsConfig.cleanup == .manual)
  }

  // MARK: - Default Value Tests

  @Test("Verify default values when x-apple-secrets not specified")
  func verifyNoSecretsConfig() throws {
    let yaml = """
      version: '3.8'
      services:
        web:
          image: nginx:latest
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let service = try #require(compose.services["web"])
    #expect(service?.xAppleSecrets == nil)
  }

  @Test("Verify default mount path")
  func verifyDefaultMount() throws {
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

    let service = try #require(compose.services["app"])
    let secretsConfig = try #require(service?.xAppleSecrets)

    #expect(secretsConfig.mount == "/run/secrets")
  }

  // MARK: - Multiple Services Tests

  @Test("Parse multiple services with different secrets configs")
  func parseMultipleServicesWithSecrets() throws {
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
    let webService = try #require(compose.services["web"])
    let webSecrets = try #require(webService?.xAppleSecrets)
    #expect(webSecrets.mount == "/run/secrets")
    #expect(webSecrets.filter?.count == 2)
    #expect(webSecrets.filter?.contains("NGINX_CERT") == true)

    // DB service secrets
    let dbService = try #require(compose.services["db"])
    let dbSecrets = try #require(dbService?.xAppleSecrets)
    #expect(dbSecrets.mount == "/var/run/db-secrets")
    #expect(dbSecrets.filter?.count == 2)
    #expect(dbSecrets.filter?.contains("DB_PASSWORD") == true)

    // Cache service has no secrets
    let cacheService = try #require(compose.services["cache"])
    #expect(cacheService?.xAppleSecrets == nil)
  }

  // MARK: - Global Configuration Tests

  @Test("Parse global x-apple-secrets configuration")
  func parseGlobalConfig() throws {
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

    let globalConfig = try #require(compose.xAppleSecretsGlobal)
    #expect(globalConfig.version == "1.0")
    #expect(globalConfig.enclave == "/Volumes/AGENT_SECRETS")
    #expect(globalConfig.defaultMount == "/run/secrets")
    #expect(globalConfig.format == .files)
    #expect(globalConfig.permissions == "0400")
    #expect(globalConfig.cleanup == .immediate)
  }

  @Test("Service inherits defaults from global config")
  func serviceInheritsGlobalDefaults() throws {
    let yaml = """
      version: '3.8'
      x-apple-secrets:
        default_mount: /secrets
        cleanup: on_stop
      services:
        app:
          image: alpine:latest
          x-apple-secrets:
            filter:
              - TOKEN
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let service = try #require(compose.services["app"])
    let secretsConfig = try #require(service?.xAppleSecrets)

    // Should inherit from global
    #expect(secretsConfig.mount == "/secrets")
    #expect(secretsConfig.cleanup == .onStop)
  }

  // MARK: - Edge Cases

  @Test("Parse x-apple-secrets with empty filter")
  func parseWithEmptyFilter() throws {
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

    let service = try #require(compose.services["app"])
    let secretsConfig = try #require(service?.xAppleSecrets)

    #expect(secretsConfig.filter?.isEmpty == true)
  }

  @Test("Parse x-apple-secrets with complex mount path")
  func parseWithComplexMountPath() throws {
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

    let service = try #require(compose.services["app"])
    let secretsConfig = try #require(service?.xAppleSecrets)

    #expect(secretsConfig.mount == "/very/deep/nested/path/to/secrets")
  }

  // MARK: - Validation Tests

  @Test("Reject invalid cleanup policy")
  func rejectInvalidCleanupPolicy() throws {
    let yaml = """
      version: '3.8'
      services:
        app:
          image: alpine:latest
          x-apple-secrets:
            mount: /run/secrets
            cleanup: invalid_policy
      """

    let decoder = YAMLDecoder()

    #expect(throws: (any Error).self) {
      _ = try decoder.decode(DockerCompose.self, from: yaml)
    }
  }

  @Test("Reject invalid mount path")
  func rejectInvalidMountPath() throws {
    let yaml = """
      version: '3.8'
      services:
        app:
          image: alpine:latest
          x-apple-secrets:
            mount: not/an/absolute/path
      """

    let decoder = YAMLDecoder()

    #expect(throws: (any Error).self) {
      _ = try decoder.decode(DockerCompose.self, from: yaml)
    }
  }

  @Test("Reject invalid secret name in filter")
  func rejectInvalidSecretName() throws {
    let yaml = """
      version: '3.8'
      services:
        app:
          image: alpine:latest
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - valid_secret
              - invalid-secret!
      """

    let decoder = YAMLDecoder()

    #expect(throws: (any Error).self) {
      _ = try decoder.decode(DockerCompose.self, from: yaml)
    }
  }

  // MARK: - Honcho Stack Configuration Tests

  @Test("Parse honcho-db configuration")
  func parseHonchoDBConfig() throws {
    let yaml = """
      version: '3.8'
      services:
        honcho-db:
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

    let dbService = try #require(compose.services["honcho-db"])
    let secretsConfig = try #require(dbService?.xAppleSecrets)

    #expect(secretsConfig.mount == "/run/secrets")
    #expect(secretsConfig.filter?.count == 3)
    #expect(secretsConfig.filter?.contains("HONCHO_DB_PASSWORD") == true)
    #expect(secretsConfig.filter?.contains("WALG_AWS_ACCESS_KEY_ID") == true)
    #expect(secretsConfig.filter?.contains("WALG_AWS_SECRET_ACCESS_KEY") == true)
  }

  @Test("Parse honcho-hub configuration")
  func parseHonchoHubConfig() throws {
    let yaml = """
      version: '3.8'
      services:
        honcho-hub:
          image: honcho:latest
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - HONCHO_ADMIN_TOKEN
              - LLM_ANTHROPIC_API_KEY
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let hubService = try #require(compose.services["honcho-hub"])
    let secretsConfig = try #require(hubService?.xAppleSecrets)

    #expect(secretsConfig.filter?.contains("HONCHO_ADMIN_TOKEN") == true)
    #expect(secretsConfig.filter?.contains("LLM_ANTHROPIC_API_KEY") == true)
  }
}

// MARK: - XAppleSecretsConfig Validation

@Suite("XAppleSecretsConfig Validation Tests")
struct XAppleSecretsConfigValidationTests {

  @Test("Validate cleanup policy enum")
  func validateCleanupPolicy() {
    #expect(XAppleSecretsConfig.CleanupPolicy.immediate.rawValue == "immediate")
    #expect(XAppleSecretsConfig.CleanupPolicy.onStop.rawValue == "on_stop")
    #expect(XAppleSecretsConfig.CleanupPolicy.manual.rawValue == "manual")
  }

  @Test("Validate format enum")
  func validateFormatEnum() {
    #expect(XAppleSecretsGlobalConfig.Format.files.rawValue == "files")
  }

  @Test("Validate mount path is absolute")
  func validateAbsolutePath() {
    let validPaths = ["/run/secrets", "/var/lib/secrets", "/tmp/test"]
    let invalidPaths = ["relative/path", "secrets", "./secrets"]

    for path in validPaths {
      #expect(XAppleSecretsConfig.isValidMountPath(path) == true, "Path \(path) should be valid")
    }

    for path in invalidPaths {
      #expect(XAppleSecretsConfig.isValidMountPath(path) == false, "Path \(path) should be invalid")
    }
  }

  @Test("Validate secret name format")
  func validateSecretNameFormat() {
    let validNames = ["SECRET", "API_KEY", "DB_PASSWORD_123", "test_name"]
    let invalidNames = ["secret!", "api-key", "123starts", "with space", ""]

    for name in validNames {
      #expect(XAppleSecretsConfig.isValidSecretName(name) == true, "Name \(name) should be valid")
    }

    for name in invalidNames {
      #expect(XAppleSecretsConfig.isValidSecretName(name) == false, "Name \(name) should be invalid")
    }
  }
}
