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
import Yams
import Testing
@testable import ContainerComposeCore

/// Honcho Stack Secrets E2E Tests
@Suite("Honcho Stack Secrets E2E Tests")
final class HonchoStackSecretsE2ETests {

var composeFilePath: String!

init() {
composeFilePath = FileManager.default.temporaryDirectory
.appendingPathComponent("honcho-test-\(UUID().uuidString).yml")
.path
}

deinit {
try? FileManager.default.removeItem(atPath: composeFilePath)
}

// MARK: - Compose File Parsing Tests

  @Test("Parse Honcho Stack Compose file")
  func parseHonchoStackCompose() throws {
    // CRITICAL: Use unique project name to avoid collision with production
    let testId = UUID().uuidString.prefix(8)
    let yaml = """
version: '3.8'
name: honcho-test-\(testId)

x-apple-secrets:
  version: "1.0"
  enclave: /Volumes/AGENT_SECRETS
  default_mount: /run/secrets
  format: files
  permissions: "0400"
  cleanup: immediate

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
      read_only: true
      noexec: true
      nosuid: true
      cleanup: immediate

  test-hub:
    image: honcho:latest
    x-apple-secrets:
      mount: /run/secrets
      filter:
        - HONCHO_ADMIN_TOKEN
        - LLM_ANTHROPIC_API_KEY
        - DATABASE_URL_VSOCK
      read_only: true
      noexec: true
      nosuid: true
      cleanup: immediate
    depends_on:
      test-db:
        condition: service_started

  test-deriver:
    image: honcho:latest
    x-apple-secrets:
      mount: /run/secrets
      filter:
        - LLM_ANTHROPIC_API_KEY
        - DATABASE_URL_VSOCK
    depends_on:
      test-hub:
        condition: service_started
"""

    try yaml.write(toFile: composeFilePath, atomically: true, encoding: .utf8)

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // Verify global config
    let globalConfig = try #require(compose.xAppleSecretsGlobal)
    #expect(globalConfig.enclave == "/Volumes/AGENT_SECRETS")
    #expect(globalConfig.defaultMount == "/run/secrets")

    // Verify test-db secrets
    let dbService = try #require(compose.services["test-db"])
    let dbSecrets = try #require(dbService?.xAppleSecrets)
    #expect(dbSecrets.filter?.contains("HONCHO_DB_PASSWORD") == true)
    #expect(dbSecrets.filter?.contains("WALG_AWS_ACCESS_KEY_ID") == true)
    #expect(dbSecrets.filter?.contains("WALG_AWS_SECRET_ACCESS_KEY") == true)
    #expect(dbSecrets.readOnly == true)
    #expect(dbSecrets.noexec == true)

    // Verify test-hub secrets
    let hubService = try #require(compose.services["test-hub"])
    let hubSecrets = try #require(hubService?.xAppleSecrets)
    #expect(hubSecrets.filter?.contains("HONCHO_ADMIN_TOKEN") == true)
    #expect(hubSecrets.filter?.contains("LLM_ANTHROPIC_API_KEY") == true)
    #expect(hubSecrets.filter?.contains("DATABASE_URL_VSOCK") == true)

    // Verify test-deriver secrets
    let deriverService = try #require(compose.services["test-deriver"])
    let deriverSecrets = try #require(deriverService?.xAppleSecrets)
    #expect(deriverSecrets.filter?.contains("LLM_ANTHROPIC_API_KEY") == true)
  }

  // MARK: - Service Configuration Tests

  
  @Test("All services have secrets")
  func verifyAllServicesHaveSecrets() throws {
    let yaml = """
      version: '3.8'
      services:
        test-db:
          image: walg-db:vsock
          x-apple-secrets:
            filter:
              - HONCHO_DB_PASSWORD
              - WALG_AWS_ACCESS_KEY_ID
              - WALG_AWS_SECRET_ACCESS_KEY

        test-hub:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - HONCHO_ADMIN_TOKEN
              - LLM_ANTHROPIC_API_KEY

        test-deriver-1:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY

        test-deriver-2:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY

        test-deriver-3:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY

        test-deriver-4:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY

        codegraph:
          image: codegraph-mcp:latest
          x-apple-secrets:
            filter:
              - HONCHO_ADMIN_TOKEN
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // All 7 services should have x-apple-secrets
    let servicesWithSecrets = compose.services.values.filter { $0?.xAppleSecrets != nil }
    #expect(servicesWithSecrets.count == 7)

    // Verify each service type
    #expect(compose.services["test-db"]??.xAppleSecrets?.filter?.contains("HONCHO_DB_PASSWORD") == true)
    #expect(compose.services["test-hub"]??.xAppleSecrets?.filter?.contains("HONCHO_ADMIN_TOKEN") == true)
    #expect(compose.services["codegraph"]??.xAppleSecrets?.filter?.contains("HONCHO_ADMIN_TOKEN") == true)
  }

  
  @Test("Deriver secrets consistency")
  func verifyDeriverSecretsConsistency() throws {
    let yaml = """
      version: '3.8'
      services:
        test-deriver-1:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY
              - DATABASE_URL_VSOCK

        test-deriver-2:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY
              - DATABASE_URL_VSOCK

        test-deriver-3:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY
              - DATABASE_URL_VSOCK
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // All derivers should have the same secrets
    for i in 1...3 {
      let deriver = compose.services["test-deriver-\(i)"]
      let secrets = deriver??.xAppleSecrets?.filter

      #expect(secrets?.contains("LLM_ANTHROPIC_API_KEY") == true)
      #expect(secrets?.contains("DATABASE_URL_VSOCK") == true)
      #expect(secrets?.count == 2)
    }
  }

  // MARK: - Security Configuration Tests

  
  @Test("Verify secure mounts")
  func verifySecureMounts() throws {
    let yaml = """
      version: '3.8'
      services:
        test-db:
          image: walg-db:vsock
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - HONCHO_DB_PASSWORD
            read_only: true
            noexec: true
            nosuid: true
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbSecrets = compose.services["test-db"]??.xAppleSecrets

    #expect(dbSecrets?.readOnly == true)
    #expect(dbSecrets?.noexec == true)
    #expect(dbSecrets?.nosuid == true)
    #expect(dbSecrets?.cleanup == .immediate)
  }

  // MARK: - Integration with vsock Tests

  
  @Test("Secrets work with relays")
  func secretsWorkWithRelays() throws {
    let yaml = """
      version: '3.8'
      services:
        test-db:
          image: walg-db:vsock
          x-apple-relays:
            - type: vsock-db
              port: 5432
          x-apple-secrets:
            filter:
              - HONCHO_DB_PASSWORD

        test-hub:
          image: honcho:latest
          environment:
            DATABASE_URL_VSOCK: postgresql://...@vsock:2:5432/honcho
          x-apple-secrets:
            filter:
              - HONCHO_ADMIN_TOKEN
          depends_on:
            test-db:
              condition: service_started
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbService = compose.services["test-db"]
    let hubService = compose.services["test-hub"]

    // Both extensions should coexist
    #expect(dbService??.xAppleRelays != nil)
    #expect(dbService??.xAppleSecrets != nil)

    #expect(hubService??.xAppleSecrets != nil)
    #expect(hubService??.environment != nil)
  }

  // MARK: - Cleanup Policy Tests

  
  @Test("Verify immediate cleanup")
  func verifyImmediateCleanup() throws {
    let yaml = """
      version: '3.8'
      services:
        test-db:
          image: walg-db:vsock
          x-apple-secrets:
            filter:
              - HONCHO_DB_PASSWORD
            cleanup: immediate

        test-hub:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - HONCHO_ADMIN_TOKEN
            cleanup: immediate
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbCleanup = compose.services["test-db"]??.xAppleSecrets?.cleanup
    let hubCleanup = compose.services["test-hub"]??.xAppleSecrets?.cleanup

    #expect(dbCleanup == .immediate)
    #expect(hubCleanup == .immediate)
  }

  // MARK: - Mount Path Tests

  
  @Test("Verify consistent mount paths")
  func verifyConsistentMountPaths() throws {
    let yaml = """
      version: '3.8'
      services:
        test-db:
          image: walg-db:vsock
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - HONCHO_DB_PASSWORD

        test-hub:
          image: honcho:latest
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - HONCHO_ADMIN_TOKEN
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbMount = compose.services["test-db"]??.xAppleSecrets?.mount
    let hubMount = compose.services["test-hub"]??.xAppleSecrets?.mount

    // Consistent mount path for standardization
    #expect(dbMount == "/run/secrets")
    #expect(hubMount == "/run/secrets")
  }

  // MARK: - Validation Tests

  
  @Test("Reject invalid secret names")
  func rejectInvalidSecretNames() {
    let yaml = """
      version: '3.8'
      services:
        app:
          image: alpine:latest
          x-apple-secrets:
            filter:
              - valid_secret
              - invalid-secret-with-dashes!
      """

    let decoder = YAMLDecoder()

    #expect(throws: (any Error).self) {
      _ = try decoder.decode(DockerCompose.self, from: yaml)
    }
  }

  
  @Test("Reject relative mount paths")
  func rejectRelativeMountPaths() {
    let yaml = """
      version: '3.8'
      services:
        app:
          image: alpine:latest
          x-apple-secrets:
            mount: relative/path
      """

    let decoder = YAMLDecoder()

    #expect(throws: (any Error).self) {
      _ = try decoder.decode(DockerCompose.self, from: yaml)
    }
  }

  // MARK: - Complete Stack Validation

  
  @Test("Full Honcho stack configuration")
  func fullHonchoStackConfiguration() throws {
    // CRITICAL: Use unique project name to avoid collision with production
    let testId = UUID().uuidString.prefix(8)
    let yaml = """
version: '3.8'
name: honcho-test-\(testId)

x-apple-secrets:
  version: "1.0"
  enclave: /Volumes/AGENT_SECRETS
  default_mount: /run/secrets
  cleanup: immediate

services:
  test-db:
    image: walg-db:vsock
    x-apple-relays:
      - type: vsock-db
        port: 5432
    x-apple-secrets:
      filter:
        - HONCHO_DB_PASSWORD
        - WALG_AWS_ACCESS_KEY_ID
        - WALG_AWS_SECRET_ACCESS_KEY

  test-hub:
    image: honcho:latest
    environment:
      DATABASE_URL_VSOCK: postgresql://...:5432/honcho
      HONCHO_BASE_URL: vsock://2:8000
    x-apple-secrets:
      filter:
        - HONCHO_ADMIN_TOKEN
        - LLM_ANTHROPIC_API_KEY
        - LLM_VLLM_API_KEY
    depends_on:
      test-db:
        condition: service_started

  test-deriver-1:
    image: honcho:latest
    x-apple-secrets:
      filter:
        - LLM_ANTHROPIC_API_KEY
        - DATABASE_URL_VSOCK
    depends_on:
      test-hub:
        condition: service_started

  test-deriver-2:
    image: honcho:latest
    x-apple-secrets:
      filter:
        - LLM_ANTHROPIC_API_KEY
        - DATABASE_URL_VSOCK
    depends_on:
      test-hub:
        condition: service_started

  test-deriver-3:
    image: honcho:latest
    x-apple-secrets:
      filter:
        - LLM_ANTHROPIC_API_KEY
        - DATABASE_URL_VSOCK
    depends_on:
      test-hub:
        condition: service_started

  test-deriver-4:
    image: honcho:latest
    x-apple-secrets:
      filter:
        - LLM_ANTHROPIC_API_KEY
        - DATABASE_URL_VSOCK
    depends_on:
      test-hub:
        condition: service_started

  codegraph:
    image: codegraph-mcp:latest
    x-apple-secrets:
      filter:
        - HONCHO_ADMIN_TOKEN
    depends_on:
      test-hub:
        condition: service_started
"""

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // Verify all services present
    #expect(compose.services.count == 7)

    // Verify service names
    let serviceNames = Set(compose.services.keys)
    #expect(serviceNames.contains("test-db"))
    #expect(serviceNames.contains("test-hub"))
    #expect(serviceNames.contains("test-deriver-1"))
    #expect(serviceNames.contains("test-deriver-2"))
    #expect(serviceNames.contains("test-deriver-3"))
    #expect(serviceNames.contains("test-deriver-4"))
    #expect(serviceNames.contains("codegraph"))

    // Verify global config
    let global = compose.xAppleSecretsGlobal
    #expect(global?.enclave == "/Volumes/AGENT_SECRETS")

    // Verify each service has secrets
    for (_, service) in compose.services {
      #expect(service?.xAppleSecrets != nil)
    }

    // Verify DB secrets (3)
    let dbSecrets = compose.services["test-db"]??.xAppleSecrets?.filter
    #expect(dbSecrets?.count == 3)

    // Verify hub secrets (3)
    let hubSecrets = compose.services["test-hub"]??.xAppleSecrets?.filter
    #expect(hubSecrets?.count == 3)

    // Verify codegraph secrets (1)
    let codegraphSecrets = compose.services["codegraph"]??.xAppleSecrets?.filter
    #expect(codegraphSecrets?.count == 1)
  }
}
