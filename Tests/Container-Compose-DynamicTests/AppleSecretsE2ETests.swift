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

/// Apple Secrets Extension E2E Tests
/// Tests the x-apple-secrets feature using generic service names and local images
/// This ensures tests are fast (local images) and not tied to specific applications
@Suite("Apple Secrets E2E Tests")
final class AppleSecretsE2ETests {

  var composeFilePath: String!

  init() {
    composeFilePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("apple-secrets-test-\(UUID().uuidString).yml")
      .path
  }

  deinit {
    try? FileManager.default.removeItem(atPath: composeFilePath)
  }

  // MARK: - Compose File Parsing Tests

  @Test("Parse Apple Secrets Compose file")
  func parseAppleSecretsCompose() throws {
    let yaml = """
version: '3.8'
name: test-stack

x-apple-secrets:
  version: "1.0"
  enclave: /Volumes/AGENT_SECRETS
  default_mount: /run/secrets
  format: files
  permissions: "0400"
  cleanup: immediate

services:
  db:
    image: ${OCI_REGISTRY_URL}/pgmicro:latest
    x-apple-relays:
      - type: vsock-db
        port: 5432
    x-apple-secrets:
      mount: /run/secrets
      filter:
        - DB_PASSWORD
        - AWS_ACCESS_KEY_ID
        - AWS_SECRET_ACCESS_KEY
      read_only: true
      noexec: true
      nosuid: true
      cleanup: immediate

  api:
    image: nginx:alpine
    x-apple-secrets:
      mount: /run/secrets
      filter:
        - API_TOKEN
        - LLM_API_KEY
        - DATABASE_URL
      read_only: true
      noexec: true
      nosuid: true
      cleanup: immediate
    depends_on:
      db:
        condition: service_started

  worker:
    image: nginx:alpine
    x-apple-secrets:
      mount: /run/secrets
      filter:
        - LLM_API_KEY
        - DATABASE_URL
    depends_on:
      api:
        condition: service_started
"""

    try yaml.write(toFile: composeFilePath, atomically: true, encoding: .utf8)

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // Verify global config
    let globalConfig = try #require(compose.xAppleSecretsGlobal)
    #expect(globalConfig.enclave == "/Volumes/AGENT_SECRETS")
    #expect(globalConfig.defaultMount == "/run/secrets")

    // Verify db secrets
    let dbService = try #require(compose.services["db"])
    let dbSecrets = try #require(dbService?.xAppleSecrets)
    #expect(dbSecrets.filter?.contains("DB_PASSWORD") == true)
    #expect(dbSecrets.filter?.contains("AWS_ACCESS_KEY_ID") == true)
    #expect(dbSecrets.filter?.contains("AWS_SECRET_ACCESS_KEY") == true)
    #expect(dbSecrets.readOnly == true)
    #expect(dbSecrets.noexec == true)
    #expect(dbSecrets.nosuid == true)

    // Verify api secrets
    let apiService = try #require(compose.services["api"])
    let apiSecrets = try #require(apiService?.xAppleSecrets)
    #expect(apiSecrets.filter?.contains("API_TOKEN") == true)
    #expect(apiSecrets.filter?.contains("LLM_API_KEY") == true)
    #expect(apiSecrets.filter?.contains("DATABASE_URL") == true)

    // Verify worker secrets
    let workerService = try #require(compose.services["worker"])
    let workerSecrets = try #require(workerService?.xAppleSecrets)
    #expect(workerSecrets.filter?.contains("LLM_API_KEY") == true)
  }

  // MARK: - Service Configuration Tests

  @Test("All services have secrets")
  func verifyAllServicesHaveSecrets() throws {
    let yaml = """
version: '3.8'
services:
  db:
    image: ${OCI_REGISTRY_URL}/pgmicro:latest
    x-apple-secrets:
      filter:
        - DB_PASSWORD
        - AWS_ACCESS_KEY_ID

  api:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - API_TOKEN
        - LLM_API_KEY

  worker-1:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - LLM_API_KEY

  worker-2:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - LLM_API_KEY

  worker-3:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - LLM_API_KEY

  cache:
    image: redis:alpine
    x-apple-secrets:
      filter:
        - REDIS_PASSWORD
"""

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // All 6 services should have x-apple-secrets
    let servicesWithSecrets = compose.services.values.filter { $0?.xAppleSecrets != nil }
    #expect(servicesWithSecrets.count == 6)

    // Verify each service type
    #expect(compose.services["db"]??.xAppleSecrets?.filter?.contains("DB_PASSWORD") == true)
    #expect(compose.services["api"]??.xAppleSecrets?.filter?.contains("API_TOKEN") == true)
    #expect(compose.services["cache"]??.xAppleSecrets?.filter?.contains("REDIS_PASSWORD") == true)
  }

  @Test("Worker secrets consistency")
  func verifyWorkerSecretsConsistency() throws {
    let yaml = """
version: '3.8'
services:
  worker-1:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - LLM_API_KEY
        - DATABASE_URL

  worker-2:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - LLM_API_KEY
        - DATABASE_URL

  worker-3:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - LLM_API_KEY
        - DATABASE_URL
"""

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // All workers should have the same secrets
    for i in 1...3 {
      let worker = compose.services["worker-\(i)"]
      let secrets = worker??.xAppleSecrets?.filter

      #expect(secrets?.contains("LLM_API_KEY") == true)
      #expect(secrets?.contains("DATABASE_URL") == true)
      #expect(secrets?.count == 2)
    }
  }

  // MARK: - Security Configuration Tests

  @Test("Verify secure mounts")
  func verifySecureMounts() throws {
    let yaml = """
version: '3.8'
services:
  db:
    image: ${OCI_REGISTRY_URL}/pgmicro:latest
    x-apple-secrets:
      mount: /run/secrets
      filter:
        - DB_PASSWORD
      read_only: true
      noexec: true
      nosuid: true
"""

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbSecrets = compose.services["db"]??.xAppleSecrets

    #expect(dbSecrets?.readOnly == true)
    #expect(dbSecrets?.noexec == true)
    #expect(dbSecrets?.nosuid == true)
    #expect(dbSecrets?.cleanup == .immediate)
  }

  // MARK: - Integration with Relays Tests

  @Test("Secrets work with relays")
  func secretsWorkWithRelays() throws {
    let yaml = """
version: '3.8'
services:
  db:
    image: ${OCI_REGISTRY_URL}/pgmicro:latest
    x-apple-relays:
      - type: vsock-db
        port: 5432
    x-apple-secrets:
      filter:
        - DB_PASSWORD

  api:
    image: nginx:alpine
    environment:
      DATABASE_URL: postgresql://...@vsock:2:5432/app
    x-apple-secrets:
      filter:
        - API_TOKEN
    depends_on:
      db:
        condition: service_started
"""

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbService = compose.services["db"]
    let apiService = compose.services["api"]

    // Both extensions should coexist
    #expect(dbService??.xAppleRelays != nil)
    #expect(dbService??.xAppleSecrets != nil)

    #expect(apiService??.xAppleSecrets != nil)
    #expect(apiService??.environment != nil)
  }

  // MARK: - Cleanup Policy Tests

  @Test("Verify immediate cleanup")
  func verifyImmediateCleanup() throws {
    let yaml = """
version: '3.8'
services:
  db:
    image: ${OCI_REGISTRY_URL}/pgmicro:latest
    x-apple-secrets:
      filter:
        - DB_PASSWORD
      cleanup: immediate

  api:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - API_TOKEN
      cleanup: immediate
"""

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbCleanup = compose.services["db"]??.xAppleSecrets?.cleanup
    let apiCleanup = compose.services["api"]??.xAppleSecrets?.cleanup

    #expect(dbCleanup == .immediate)
    #expect(apiCleanup == .immediate)
  }

  // MARK: - Mount Path Tests

  @Test("Verify consistent mount paths")
  func verifyConsistentMountPaths() throws {
    let yaml = """
version: '3.8'
services:
  db:
    image: ${OCI_REGISTRY_URL}/pgmicro:latest
    x-apple-secrets:
      mount: /run/secrets
      filter:
        - DB_PASSWORD

  api:
    image: nginx:alpine
    x-apple-secrets:
      mount: /run/secrets
      filter:
        - API_TOKEN
"""

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    let dbMount = compose.services["db"]??.xAppleSecrets?.mount
    let apiMount = compose.services["api"]??.xAppleSecrets?.mount

    // Consistent mount path for standardization
    #expect(dbMount == "/run/secrets")
    #expect(apiMount == "/run/secrets")
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

  @Test("Full stack configuration")
  func fullStackConfiguration() throws {
    let yaml = """
version: '3.8'
name: test-application

x-apple-secrets:
  version: "1.0"
  enclave: /Volumes/AGENT_SECRETS
  default_mount: /run/secrets
  cleanup: immediate

services:
  db:
    image: ${OCI_REGISTRY_URL}/pgmicro:latest
    x-apple-relays:
      - type: vsock-db
        port: 5432
    x-apple-secrets:
      filter:
        - DB_PASSWORD
        - AWS_ACCESS_KEY_ID
        - AWS_SECRET_ACCESS_KEY

  api:
    image: nginx:alpine
    environment:
      DATABASE_URL: postgresql://...:5432/app
      API_BASE_URL: vsock://2:8000
    x-apple-secrets:
      filter:
        - API_TOKEN
        - LLM_API_KEY
        - VLLM_API_KEY
    depends_on:
      db:
        condition: service_started

  worker-1:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - LLM_API_KEY
        - DATABASE_URL
    depends_on:
      api:
        condition: service_started

  worker-2:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - LLM_API_KEY
        - DATABASE_URL
    depends_on:
      api:
        condition: service_started

  worker-3:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - LLM_API_KEY
        - DATABASE_URL
    depends_on:
      api:
        condition: service_started

  worker-4:
    image: nginx:alpine
    x-apple-secrets:
      filter:
        - LLM_API_KEY
        - DATABASE_URL
    depends_on:
      api:
        condition: service_started

  cache:
    image: redis:alpine
    x-apple-secrets:
      filter:
        - REDIS_PASSWORD
    depends_on:
      api:
        condition: service_started
"""

    let decoder = YAMLDecoder()
    let compose = try decoder.decode(DockerCompose.self, from: yaml)

    // Verify all services present
    #expect(compose.services.count == 7)

    // Verify service names
    let serviceNames = Set(compose.services.keys)
    #expect(serviceNames.contains("db"))
    #expect(serviceNames.contains("api"))
    #expect(serviceNames.contains("worker-1"))
    #expect(serviceNames.contains("worker-2"))
    #expect(serviceNames.contains("worker-3"))
    #expect(serviceNames.contains("worker-4"))
    #expect(serviceNames.contains("cache"))

    // Verify global config
    let global = compose.xAppleSecretsGlobal
    #expect(global?.enclave == "/Volumes/AGENT_SECRETS")

    // Verify each service has secrets
    for (_, service) in compose.services {
      #expect(service?.xAppleSecrets != nil)
    }

    // Verify DB secrets (3)
    let dbSecrets = compose.services["db"]??.xAppleSecrets?.filter
    #expect(dbSecrets?.count == 3)

    // Verify api secrets (3)
    let apiSecrets = compose.services["api"]??.xAppleSecrets?.filter
    #expect(apiSecrets?.count == 3)

    // Verify cache secrets (1)
    let cacheSecrets = compose.services["cache"]??.xAppleSecrets?.filter
    #expect(cacheSecrets?.count == 1)
  }
}
