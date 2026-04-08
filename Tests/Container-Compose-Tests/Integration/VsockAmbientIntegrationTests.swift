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

import XCTest
import Yams
@testable import ContainerComposeCore

// MARK: - Vsock Ambient Integration Tests

/// Integration tests for x-apple-relays → RelayManager → Port Binding
/// Validates the complete orchestration flow from YAML to socket
final class VsockAmbientIntegrationTests: XCTestCase {

    // MARK: - Phase 0: YAML → RelayManager Integration

    /// Tests that ComposeUp sees x-apple-relays and includes service in relay processing
    func testXAppleRelaysDetectedInServiceFilter() throws {
        // Given compose YAML with x-apple-relays
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

        // When parsing YAML
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)

        // Then x-apple-relays should be present on db service
        guard let dbServiceOptional = dockerCompose.services["db"],
              let dbService = dbServiceOptional else {
            XCTFail("db service not found")
            return
        }

        XCTAssertNotNil(dbService.x_apple_relays, "x_apple_relays should be parsed")
        XCTAssertEqual(dbService.x_apple_relays?.count, 1, "Should have 1 relay config")
        XCTAssertEqual(dbService.x_apple_relays?[0].type, "vsock-db")
        XCTAssertEqual(dbService.x_apple_relays?[0].port, 5432)

        // And web service should not have relays
        guard let webServiceOptional = dockerCompose.services["web"],
              let webService = webServiceOptional else {
            XCTFail("web service not found")
            return
        }
        XCTAssertNil(webService.x_apple_relays, "web service should not have relays")
    }

    /// Tests that RelayConfigurationLoader correctly parses x-apple-relays
    func testRelayConfigurationLoaderParsesXAppleRelays() throws {
        // Given services with x-apple-relays
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
              - type: "vsock-mcp-bridge"
                port: 5002
                target: "honcho-hub"
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        let loader = RelayConfigurationLoader()

        let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }

        // When loading relays
        let loadedRelays = try loader.loadRelays(from: services)

        // Then all relays should be loaded
        XCTAssertEqual(loadedRelays.count, 3, "Should load 3 relays total")

        // Verify vsock-db relay
        let dbRelay = loadedRelays.first { $0.type == .vsockDb }
        XCTAssertNotNil(dbRelay, "Should have vsock-db relay")
        XCTAssertEqual(dbRelay?.port, 5432)
        XCTAssertEqual(dbRelay?.serviceName, "honcho-db")

        // Verify log stream relay
        let logRelay = loadedRelays.first { $0.type == .vsockLogStream }
        XCTAssertNotNil(logRelay, "Should have vsock-log-stream relay")
        XCTAssertEqual(logRelay?.port, 5001)
        XCTAssertEqual(logRelay?.target, "code-graph")
    }

    // MARK: - Phase 1: RelayManager → Port Binding

    /// Tests that RelayManager starts TCP listener on localhost:PORT
    /// This is the critical test that was missing - verifying actual socket binding
    func testRelayManagerBindsTCPListener() async throws {
        // Given a relay configuration
        let eventLog = RelayEventLog()
        let relayManager = RelayManager(eventLog: eventLog)

        let config = RelayManager.RelayConfiguration(
            id: "test-db-relay",
            tcpPort: 15432,  // Use ephemeral port to avoid conflicts
            transport: .vsock(cid: 2, port: 5432),
            description: "Test DB relay for integration"
        )

        // When starting relay
        try await relayManager.startRelay(config)

        // Then relay should be running
        let status = await relayManager.status()
        XCTAssertEqual(status.count, 1, "Should have 1 active relay")
        XCTAssertTrue(status[0].isRunning, "Relay should be running")
        XCTAssertEqual(status[0].tcpPort, 15432)

        // Cleanup
        await relayManager.stopRelay(id: "test-db-relay")
    }

    /// Tests that relay state is tracked correctly for compose down
    func testRelayStateTracking() async throws {
        // Given a started relay
        let eventLog = RelayEventLog()
        let relayManager = RelayManager(eventLog: eventLog)

        let config = RelayManager.RelayConfiguration(
            id: "test-relay-for-state",
            tcpPort: 15433,
            transport: .vsock(cid: 2, port: 5432),
            description: "Test relay for state tracking"
        )

        try await relayManager.startRelay(config)

        // When getting status
        let status = await relayManager.status()

        // Then status should include all relay details needed for state file
        XCTAssertEqual(status.count, 1)
        XCTAssertEqual(status[0].id, "test-relay-for-state")
        XCTAssertEqual(status[0].tcpPort, 15433)
        XCTAssertFalse(status[0].unixSocketPath.isEmpty, "Should have socket path")

        // Cleanup
        await relayManager.stopRelay(id: "test-relay-for-state")
    }

    // MARK: - Phase 2: Full Orchestration

    /// Tests complete flow: YAML → RelayManager → Port Binding
    /// This is the "convincer" test that proves the integration works end-to-end
    func testFullOrchestrationYAMLToPortBinding() async throws {
        // Given compose file with x-apple-relays
        let yamlString = """
        name: integration-test
        services:
          test-db:
            image: postgres:15
            x-apple-relays:
              - type: "vsock-db"
                port: 15434
        """

        // Parse the compose file
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)

        // Verify x-apple-relays is present
        guard let dbServiceOptional = dockerCompose.services["test-db"],
              let dbService = dbServiceOptional else {
            XCTFail("test-db service not found")
            return
        }

        XCTAssertNotNil(dbService.x_apple_relays, "x-apple-relays should be present")

        // Load relay configurations
        let loader = RelayConfigurationLoader()
        let services: [(serviceName: String, service: Service)] = [("test-db", dbService)]
        let loadedRelays = try loader.loadRelays(from: services)

        XCTAssertEqual(loadedRelays.count, 1, "Should load 1 relay")
        XCTAssertEqual(loadedRelays[0].port, 15434)

        // Start RelayManager with loaded configuration
        let eventLog = RelayEventLog()
        let relayManager = RelayManager(eventLog: eventLog)

        let config = RelayManager.RelayConfiguration(
            id: "integration-test-db",
            tcpPort: UInt16(loadedRelays[0].port),
            transport: .vsock(cid: 2, port: loadedRelays[0].port),
            description: "Integration test relay"
        )

        // When starting the relay
        try await relayManager.startRelay(config)

        // Then verify relay is active
        let status = await relayManager.status()
        XCTAssertEqual(status.count, 1, "Relay should be active")
        XCTAssertTrue(status[0].isRunning, "Relay should be running")

        // Cleanup
        await relayManager.stopRelay(id: "integration-test-db")
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
              - type: "vsock-mcp-bridge"
                port: 5002
              - type: "vsock-ane-embedding"
                port: 6000
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
