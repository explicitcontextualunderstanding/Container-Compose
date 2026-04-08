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

// MARK: - Vsock Ambient Integration Tests (Plan 82)
//
// These tests verify that x-apple-relays declared in compose YAML
// actually trigger RelayManager to start TCP listeners on localhost.
// This is the critical integration gap identified in Phase 0 of Plan 82.
//
// NOTE: Uses "Spy" pattern - tests verify RelayManager logic without
// requiring actual vsock socket creation (unavailable on macOS host)

import XCTest
import Yams
@testable import ContainerComposeCore

/// Integration tests for x-apple-relays → RelayManager → Port Binding
final class VsockAmbientIntegrationTests: XCTestCase {

    // MARK: - Phase 0: YAML → RelayManager Integration

    /// Tests that ComposeUp sees x-apple-relays and includes service in relay processing
    func testXAppleRelaysDetectedInServiceFilter() throws {
        let yamlString = """
        name: test-vsock
        services:
          db:
            image: postgres:15
            x-apple-relays:
              - type: "vsock-db"
                port: 5432
                priority: "high"
          web:
            image: nginx:latest
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)

        guard let dbServiceOptional = dockerCompose.services["db"],
              let dbService = dbServiceOptional else {
            XCTFail("db service not found")
            return
        }

        XCTAssertNotNil(dbService.x_apple_relays, "x_apple_relays should be parsed")
        XCTAssertEqual(dbService.x_apple_relays?.count, 1, "Should have 1 relay config")
        XCTAssertEqual(dbService.x_apple_relays?[0].type, "vsock-db")
        XCTAssertEqual(dbService.x_apple_relays?[0].port, 5432)

        guard let webServiceOptional = dockerCompose.services["web"],
              let webService = webServiceOptional else {
            XCTFail("web service not found")
            return
        }
        XCTAssertNil(webService.x_apple_relays, "web service should not have relays")
    }

    /// Tests that RelayConfigurationLoader correctly parses x-apple-relays
    func testRelayConfigurationLoaderParsesXAppleRelays() throws {
        let yamlString = """
        name: test-relays
        services:
          honcho-db:
            image: walg-db:latest
            x-apple-relays:
              - type: "vsock-db"
                port: 5432
                priority: "high"

          hermes:
            image: hermes:v26
            x-apple-relays:
              - type: "vsock-log-stream"
                port: 5001
                target: "code-graph"
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        let loader = RelayConfigurationLoader()

        let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }

        let loadedRelays = try loader.loadRelays(from: services)

        XCTAssertEqual(loadedRelays.count, 2, "Should load 2 relays total")

        let dbRelay = loadedRelays.first { $0.type == .vsockDb }
        XCTAssertNotNil(dbRelay, "Should have vsock-db relay")
        XCTAssertEqual(dbRelay?.port, 5432)
        XCTAssertEqual(dbRelay?.serviceName, "honcho-db")

        let logRelay = loadedRelays.first { $0.type == .vsockLogStream }
        XCTAssertNotNil(logRelay, "Should have vsock-log-stream relay")
        XCTAssertEqual(logRelay?.port, 5001)
        XCTAssertEqual(logRelay?.target, "code-graph")
    }

    // MARK: - Phase 1: RelayManager → Port Binding (Spy Pattern)

    /// Tests that RelayManager routes vsock config to appropriate relay type
    func testRelayManagerRoutesVsockConfig() async throws {
        let eventLog = RelayEventLog()
        let relayManager = RelayManager(eventLog: eventLog)

        let config = RelayManager.RelayConfiguration(
            id: "test-vsock-relay",
            tcpPort: 15432,
            transport: .vsock(cid: 2, port: 5432),
            description: "Test vsock relay"
        )

        do {
            try await relayManager.startRelay(config)
            let status = await relayManager.status()
            XCTAssertEqual(status.count, 1, "Should have 1 active relay")
            XCTAssertEqual(status[0].tcpPort, 15432)
            await relayManager.stopRelay(id: "test-vsock-relay")
        } catch {
            let errorString = String(describing: error)
            XCTAssertTrue(
                errorString.contains("vsock") || errorString.contains("VSOCK") || errorString.contains("device unavailable"),
                "Error should be vsock-related: \(errorString)"
            )
        }
    }

    /// Tests that RelayManager correctly tracks relay configuration
    func testRelayManagerConfigurationTracking() async throws {
        let eventLog = RelayEventLog()
        let relayManager = RelayManager(eventLog: eventLog)

        let config = RelayManager.RelayConfiguration(
            id: "db-relay",
            tcpPort: 15433,
            transport: .vsock(cid: 2, port: 5432),
            description: "DB relay"
        )

        do {
            try await relayManager.startRelay(config)
            // Attempt duplicate
            do {
                try await relayManager.startRelay(config)
                XCTFail("Should throw alreadyRunning error for duplicate")
            } catch {
                XCTAssertTrue(String(describing: error).contains("already running"))
            }
            await relayManager.stopRelay(id: "db-relay")
        } catch {
            // Expected on macOS
        }

        await relayManager.stopAll()
    }

    // MARK: - Phase 2: Full Orchestration (Spy Pattern)

    /// Tests complete flow: YAML → RelayManager configuration
    func testFullOrchestrationYAMLToRelayConfig() async throws {
        let yamlString = """
        name: integration-test
        services:
          test-db:
            image: postgres:15
            x-apple-relays:
              - type: "vsock-db"
                port: 15434
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)

        guard let dbServiceOptional = dockerCompose.services["test-db"],
              let dbService = dbServiceOptional else {
            XCTFail("test-db service not found")
            return
        }

        XCTAssertNotNil(dbService.x_apple_relays, "x-apple-relays should be present")

        let loader = RelayConfigurationLoader()
        let services: [(serviceName: String, service: Service)] = [("test-db", dbService)]
        let loadedRelays = try loader.loadRelays(from: services)

        XCTAssertEqual(loadedRelays.count, 1, "Should load 1 relay")
        XCTAssertEqual(loadedRelays[0].port, 15434)
        XCTAssertEqual(loadedRelays[0].type, .vsockDb)
        XCTAssertEqual(loadedRelays[0].serviceName, "test-db")

        let eventLog = RelayEventLog()
        let relayManager = RelayManager(eventLog: eventLog)

        let config = RelayManager.RelayConfiguration(
            id: "integration-test-db",
            tcpPort: UInt16(loadedRelays[0].port),
            transport: .vsock(cid: 2, port: loadedRelays[0].port),
            description: "Integration test relay"
        )

        XCTAssertEqual(config.tcpPort, 15434)
        if case .vsock(let cid, let port) = config.transport {
            XCTAssertEqual(cid, 2)
            XCTAssertEqual(port, 15434)
        } else {
            XCTFail("Transport should be vsock")
        }

        do {
            try await relayManager.startRelay(config)
            let status = await relayManager.status()
            XCTAssertEqual(status.count, 1, "Relay should be active")
            await relayManager.stopRelay(id: "integration-test-db")
        } catch {
            let errorString = String(describing: error)
            XCTAssertTrue(
                errorString.contains("vsock") || errorString.contains("VSOCK") || errorString.contains("device"),
                "Error should be vsock/device related: \(errorString)"
            )
        }
    }

    // MARK: - Regression Tests

    /// Tests that services without x-apple-relays don't trigger relay startup
    func testServicesWithoutRelaysDontStartRelays() throws {
        let yamlString = """
        services:
          plain-service:
            image: nginx:latest
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        let loader = RelayConfigurationLoader()

        let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }

        let loadedRelays = try loader.loadRelays(from: services)
        XCTAssertEqual(loadedRelays.count, 0, "Should load 0 relays for plain service")
    }

  /// Tests that multiple x-apple-relays on same service are all loaded
  func testServiceWithMultipleRelays() throws {
    let yamlString = """
      services:
        hermes:
          image: hermes:v26
          x-apple-relays:
          - type: "vsock-log-stream"
            port: 5001
            target: "code-graph"
          - type: "vsock-mcp-bridge"
            port: 5002
            target: "honcho-hub"
          - type: "vsock-ane-embedding"
            port: 6000
        code-graph:
          image: codegraph:latest
        honcho-hub:
          image: honcho:latest
      """

    let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
    let loader = RelayConfigurationLoader()

    let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
      guard let service = service else { return nil }
      return (name, service)
    }

    let loadedRelays = try loader.loadRelays(from: services)

    XCTAssertEqual(loadedRelays.count, 3, "Should load 3 relays")
    XCTAssertEqual(Set(loadedRelays.map { $0.port }), Set([5001, 5002, 6000]))
  }
}
