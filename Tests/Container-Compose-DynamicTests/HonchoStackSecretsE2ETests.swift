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
@testable import ContainerComposeCore

@Suite("Honcho Stack Secrets E2E Tests")
final class HonchoStackSecretsE2ETests: XCTestCase {

  var composeFilePath: String!

  override func setUp() {
    super.setUp()
    composeFilePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("honcho-test-\(UUID().uuidString).yml")
      .path
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: composeFilePath)
    super.tearDown()
  }

  // MARK: - Compose File Parsing Tests

  @Test("Parse honcho-stack-with-derivers.yml with x-apple-secrets")
  func parseHonchoStackCompose() throws {
    let yaml = """
      version: '3.8'
      name: honcho-stack

      x-apple-secrets:
        version: "1.0"
        enclave: /Volumes/AGENT_SECRETS
        default_mount: /run/secrets
        format: files
        permissions: "0400"
        cleanup: immediate

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
            read_only: true
            noexec: true
            nosuid: true
            cleanup: immediate

        honcho-hub:
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
            honcho-db:
              condition: service_started

        honcho-deriver:
          image: honcho:latest
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - LLM_ANTHROPIC_API_KEY
              - DATABASE_URL_VSOCK
          depends_on:
            honcho-hub:
              condition: service_started
      """

    try yaml.write(toFile: composeFilePath, atomically: true, encoding: .utf8)

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // Verify global config
    let globalConfig = try #require(compose.xAppleSecretsGlobal)
    #expect(globalConfig.enclave == "/Volumes/AGENT_SECRETS")
    #expect(globalConfig.defaultMount == "/run/secrets")

    // Verify honcho-db secrets
    let dbService = try #require(compose.services["honcho-db"])
    let dbSecrets = try #require(dbService?.xAppleSecrets)
    #expect(dbSecrets.filter?.contains("HONCHO_DB_PASSWORD") == true)
    #expect(dbSecrets.filter?.contains("WALG_AWS_ACCESS_KEY_ID") == true)
    #expect(dbSecrets.filter?.contains("WALG_AWS_SECRET_ACCESS_KEY") == true)
    #expect(dbSecrets.readOnly == true)
    #expect(dbSecrets.noexec == true)

    // Verify honcho-hub secrets
    let hubService = try #require(compose.services["honcho-hub"])
    let hubSecrets = try #require(hubService?.xAppleSecrets)
    #expect(hubSecrets.filter?.contains("HONCHO_ADMIN_TOKEN") == true)
    #expect(hubSecrets.filter?.contains("LLM_ANTHROPIC_API_KEY") == true)
    #expect(hubSecrets.filter?.contains("DATABASE_URL_VSOCK") == true)

    // Verify honcho-deriver secrets
    let deriverService = try #require(compose.services["honcho-deriver"])
    let deriverSecrets = try #require(deriverService?.xAppleSecrets)
    #expect(deriverSecrets.filter?.contains("LLM_ANTHROPIC_API_KEY") == true)
  }

  // MARK: - Service Configuration Tests

  @Test("Verify all services have required secrets")
  func verifyAllServicesHaveSecrets() throws {
    let yaml = """
      version: '3.8'
      services:
        honcho-db:
          image: walg-db:vsock
          x-apple-secrets:
            filter:
              - HONCHO_DB_PASSWORD
              - WALG_AWS_ACCESS_KEY_ID
              - WALG_AWS_SECRET_ACCESS_KEY

        honcho-hub:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - HONCHO_ADMIN_TOKEN
              - LLM_ANTHROPIC_API_KEY

        honcho-deriver-1:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY

        honcho-deriver-2:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY

        honcho-deriver-3:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY

        honcho-deriver-4:
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
    #expect(compose.services["honcho-db"]??.xAppleSecrets?.filter?.contains("HONCHO_DB_PASSWORD") == true)
    #expect(compose.services["honcho-hub"]??.xAppleSecrets?.filter?.contains("HONCHO_ADMIN_TOKEN") == true)
    #expect(compose.services["codegraph"]??.xAppleSecrets?.filter?.contains("HONCHO_ADMIN_TOKEN") == true)
  }

  @Test("Verify secrets consistency across derivers")
  func verifyDeriverSecretsConsistency() throws {
    let yaml = """
      version: '3.8'
      services:
        honcho-deriver-1:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY
              - DATABASE_URL_VSOCK

        honcho-deriver-2:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY
              - DATABASE_URL_VSOCK

        honcho-deriver-3:
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
      let deriver = compose.services["honcho-deriver-\(i)"]
      let secrets = deriver??.xAppleSecrets?.filter

      #expect(secrets?.contains("LLM_ANTHROPIC_API_KEY") == true)
      #expect(secrets?.contains("DATABASE_URL_VSOCK") == true)
      #expect(secrets?.count == 2)
    }
  }

  // MARK: - Security Configuration Tests

  @Test("Verify all mounts are read-only and secure")
  func verifySecureMounts() throws {
    let yaml = """
      version: '3.8'
      services:
        honcho-db:
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

    let dbSecrets = compose.services["honcho-db"]??.xAppleSecrets

    #expect(dbSecrets?.readOnly == true)
    #expect(dbSecrets?.noexec == true)
    #expect(dbSecrets?.nosuid == true)
    #expect(dbSecrets?.cleanup == .immediate)
  }

  // MARK: - Integration with vsock Tests

  @Test("x-apple-secrets works with x-apple-relays")
  func secretsWorkWithRelays() throws {
    let yaml = """
      version: '3.8'
      services:
        honcho-db:
          image: walg-db:vsock
          x-apple-relays:
            - type: vsock-db
              port: 5432
          x-apple-secrets:
            filter:
              - HONCHO_DB_PASSWORD

        honcho-hub:
          image: honcho:latest
          environment:
            DATABASE_URL_VSOCK: postgresql://...@vsock:2:5432/honcho
          x-apple-secrets:
            filter:
              - HONCHO_ADMIN_TOKEN
          depends_on:
            honcho-db:
              condition: service_started
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbService = compose.services["honcho-db"]
    let hubService = compose.services["honcho-hub"]

    // Both extensions should coexist
    #expect(dbService??.xAppleRelays != nil)
    #expect(dbService??.xAppleSecrets != nil)

    #expect(hubService??.xAppleSecrets != nil)
    #expect(hubService??.environment != nil)
  }

  // MARK: - Cleanup Policy Tests

  @Test("Verify immediate cleanup for all services")
  func verifyImmediateCleanup() throws {
    let yaml = """
      version: '3.8'
      services:
        honcho-db:
          image: walg-db:vsock
          x-apple-secrets:
            filter:
              - HONCHO_DB_PASSWORD
            cleanup: immediate

        honcho-hub:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - HONCHO_ADMIN_TOKEN
            cleanup: immediate
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbCleanup = compose.services["honcho-db"]??.xAppleSecrets?.cleanup
    let hubCleanup = compose.services["honcho-hub"]??.xAppleSecrets?.cleanup

    #expect(dbCleanup == .immediate)
    #expect(hubCleanup == .immediate)
  }

  // MARK: - Mount Path Tests

  @Test("Verify consistent mount paths")
  func verifyConsistentMountPaths() throws {
    let yaml = """
      version: '3.8'
      services:
        honcho-db:
          image: walg-db:vsock
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - HONCHO_DB_PASSWORD

        honcho-hub:
          image: honcho:latest
          x-apple-secrets:
            mount: /run/secrets
            filter:
              - HONCHO_ADMIN_TOKEN
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbMount = compose.services["honcho-db"]??.xAppleSecrets?.mount
    let hubMount = compose.services["honcho-hub"]??.xAppleSecrets?.mount

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

  @Test("Full honcho stack configuration")
  func fullHonchoStackConfiguration() throws {
    let yaml = """
      version: '3.8'
      name: apple-honcho

      x-apple-secrets:
        version: "1.0"
        enclave: /Volumes/AGENT_SECRETS
        default_mount: /run/secrets
        cleanup: immediate

      services:
        honcho-db:
          image: walg-db:vsock
          x-apple-relays:
            - type: vsock-db
              port: 5432
          x-apple-secrets:
            filter:
              - HONCHO_DB_PASSWORD
              - WALG_AWS_ACCESS_KEY_ID
              - WALG_AWS_SECRET_ACCESS_KEY

        honcho-hub:
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
            honcho-db:
              condition: service_started

        honcho-deriver-1:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY
              - DATABASE_URL_VSOCK
          depends_on:
            honcho-hub:
              condition: service_started

        honcho-deriver-2:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY
              - DATABASE_URL_VSOCK
          depends_on:
            honcho-hub:
              condition: service_started

        honcho-deriver-3:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY
              - DATABASE_URL_VSOCK
          depends_on:
            honcho-hub:
              condition: service_started

        honcho-deriver-4:
          image: honcho:latest
          x-apple-secrets:
            filter:
              - LLM_ANTHROPIC_API_KEY
              - DATABASE_URL_VSOCK
          depends_on:
            honcho-hub:
              condition: service_started

        codegraph:
          image: codegraph-mcp:latest
          x-apple-secrets:
            filter:
              - HONCHO_ADMIN_TOKEN
          depends_on:
            honcho-hub:
              condition: service_started
      """

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // Verify all services present
    #expect(compose.services.count == 7)

    // Verify service names
    let serviceNames = Set(compose.services.keys)
    #expect(serviceNames.contains("honcho-db"))
    #expect(serviceNames.contains("honcho-hub"))
    #expect(serviceNames.contains("honcho-deriver-1"))
    #expect(serviceNames.contains("honcho-deriver-2"))
    #expect(serviceNames.contains("honcho-deriver-3"))
    #expect(serviceNames.contains("honcho-deriver-4"))
    #expect(serviceNames.contains("codegraph"))

    // Verify global config
    let global = compose.xAppleSecretsGlobal
    #expect(global?.enclave == "/Volumes/AGENT_SECRETS")

    // Verify each service has secrets
    for (_, service) in compose.services {
      #expect(service?.xAppleSecrets != nil)
    }

    // Verify DB secrets (3)
    let dbSecrets = compose.services["honcho-db"]??.xAppleSecrets?.filter
    #expect(dbSecrets?.count == 3)

    // Verify hub secrets (3)
    let hubSecrets = compose.services["honcho-hub"]??.xAppleSecrets?.filter
    #expect(hubSecrets?.count == 3)

    // Verify codegraph secrets (1)
    let codegraphSecrets = compose.services["codegraph"]??.xAppleSecrets?.filter
    #expect(codegraphSecrets?.count == 1)
  }
}
