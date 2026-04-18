import XCTest
import Yams
import TestHelpers
@testable import ContainerComposeCore

// MARK: - Compose YAML Schema Mapping Tests (Plan 77 Phase 6)

final class ComposeSchemaMappingTests: XCTestCase {

    // MARK: - End-to-End Schema Parsing

func testLegacyParsesFullFleetConfiguration() throws {
    try skipIfLegacyValidationDisabled()
    // Simulate parsing a fleet configuration (renamed to avoid production collision)
    // Includes both legacy vsock-db and new uds types for Plan 88
    let yamlString = """
    name: test-schema-fleet
    services:
      test-db:
        image: walg-db:latest
        x-apple-relays:
          - type: "vsock-db"
            port: 5432
            priority: "high"

      test-db-uds:
        image: walg-db:latest
        x-apple-relays:
          - type: "uds-db"
            port: 5433
            socket_path: "/run/uds-test-db.sock"
            priority: "high"

      test-hermes:
        image: hermes:v26
        x-apple-relays:
          - type: "vsock-log-stream"
            port: 5001
            target: "test-code-graph"
            priority: "high"
          - type: "vsock-mcp-bridge"
            port: 5002
            target: "test-hub"
            priority: "high"
          - type: "vsock-ane-embedding"
            port: 6000
            priority: "high"

      test-hub:
        image: honcho:latest

      test-code-graph:
        image: codegraph:latest
    """

        // Parse YAML
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)

 // Verify services parsed
 XCTAssertEqual(dockerCompose.services.count, 5)

        // Verify test-db has vsock-db relay
        guard let dbServiceOptional = dockerCompose.services["test-db"],
              let dbService = dbServiceOptional else {
            XCTFail("Missing test-db service")
            return
        }
        XCTAssertNotNil(dbService.x_apple_relays)
        XCTAssertEqual(dbService.x_apple_relays?.count, 1)
        XCTAssertEqual(dbService.x_apple_relays?[0].type, "vsock-db")
        XCTAssertEqual(dbService.x_apple_relays?[0].port, 5432)

        // Verify test-hermes has all three relays
        guard let hermesServiceOptional = dockerCompose.services["test-hermes"],
              let hermesService = hermesServiceOptional else {
            XCTFail("Missing test-hermes service")
            return
        }
        XCTAssertNotNil(hermesService.x_apple_relays)
        XCTAssertEqual(hermesService.x_apple_relays?.count, 3)

        // Load relays via configuration loader
        let loader = RelayConfigurationLoader()
        let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }

        let loadedRelays = try loader.loadRelays(from: services)

 // Should have 5 relays total (1 vsock-db + 1 uds-db + 3 Hermes)
 XCTAssertEqual(loadedRelays.count, 5)

 // Verify types using fully qualified type names
 let dbRelay = loadedRelays.first { $0.type == RelayConfigurationLoader.SupportedRelayType.vsockDb }
 XCTAssertNotNil(dbRelay)
 XCTAssertEqual(dbRelay?.port, 5432)

 // Verify uds-db relay (Plan 88)
 let udsDbRelay = loadedRelays.first { $0.type == RelayConfigurationLoader.SupportedRelayType.udsDb }
 XCTAssertNotNil(udsDbRelay)
 XCTAssertEqual(udsDbRelay?.port, 5433)

 let aneRelay = loadedRelays.first { $0.type == RelayConfigurationLoader.SupportedRelayType.vsockAneEmbedding }
 XCTAssertNotNil(aneRelay)
 XCTAssertEqual(aneRelay?.port, 6000)

 let mcpRelay = loadedRelays.first { $0.type == RelayConfigurationLoader.SupportedRelayType.vsockMcpBridge }
 XCTAssertNotNil(mcpRelay)
 XCTAssertEqual(mcpRelay?.port, 5002)
 XCTAssertEqual(mcpRelay?.target, "test-hub")

 let logRelay = loadedRelays.first { $0.type == RelayConfigurationLoader.SupportedRelayType.vsockLogStream }
 XCTAssertNotNil(logRelay)
 XCTAssertEqual(logRelay?.port, 5001)
 XCTAssertEqual(logRelay?.target, "test-code-graph")
 }

    func testLegacyRejectsMalformedRelayType() throws {
        try skipIfLegacyValidationDisabled()
        // YAML parsing accepts any string, validation happens in loadRelays
        let yamlString = """
        services:
          test-service:
            image: test:latest
            x-apple-relays:
            - type: "invalid-relay-type"
              port: 5000
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        let loader = RelayConfigurationLoader()

        let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }

        // Validation should throw during loading
        XCTAssertThrowsError(try loader.loadRelays(from: services)) { error in
            guard let configError = error as? RelayConfigurationLoader.ConfigurationError else {
                XCTFail("Wrong error type")
                return
            }
            if case .unsupportedRelayType(let type) = configError {
                XCTAssertEqual(type, "invalid-relay-type")
            } else {
                XCTFail("Expected unsupportedRelayType error, got \(configError)")
            }
        }
    }

    func testLegacyHandlesServicesWithoutRelays() throws {
        try skipIfLegacyValidationDisabled()
        let yamlString = """
        services:
          plain-service:
            image: nginx:latest

          service-with-relay:
            image: hermes:latest
            x-apple-relays:
            - type: "vsock-generic"
              port: 8080
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        let loader = RelayConfigurationLoader()

        let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }

        XCTAssertTrue(loader.hasAppleRelays(in: services))

        let loadedRelays = try loader.loadRelays(from: services)
        XCTAssertEqual(loadedRelays.count, 1)
        XCTAssertEqual(loadedRelays[0].serviceName, "service-with-relay")
    }

    func testLegacyValidatesPortUniquenessAcrossServices() throws {
        try skipIfLegacyValidationDisabled()
        // Same port on different services should fail during loadRelays
        let yamlString = """
        services:
          service1:
            image: test1:latest
            x-apple-relays:
            - type: "vsock-generic"
              port: 5000

          service2:
            image: test2:latest
            x-apple-relays:
            - type: "vsock-generic"
              port: 5000
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        let loader = RelayConfigurationLoader()

        let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }

        XCTAssertThrowsError(try loader.loadRelays(from: services)) { error in
            guard let configError = error as? RelayConfigurationLoader.ConfigurationError else {
                XCTFail("Wrong error type")
                return
            }
            if case .conflictingPort(let port, _) = configError {
                XCTAssertEqual(port, 5000)
            } else {
                XCTFail("Expected conflictingPort error, got \(configError)")
            }
        }
    }

    // MARK: - Security Policy Tests

    func testLegacyEnforcesTargetRequirementForMcpBridge() throws {
        try skipIfLegacyValidationDisabled()
        let yamlString = """
        services:
          test:
            image: test:latest
            x-apple-relays:
            - type: "vsock-mcp-bridge"
              port: 5002
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        let loader = RelayConfigurationLoader()

        let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }

        XCTAssertThrowsError(try loader.loadRelays(from: services)) { error in
            guard let configError = error as? RelayConfigurationLoader.ConfigurationError else {
                XCTFail("Wrong error type")
                return
            }
            if case .missingTarget(let service) = configError {
                XCTAssertEqual(service, "test")
            } else {
                XCTFail("Expected missingTarget error, got \(configError)")
            }
        }
    }

    func testLegacyEnforcesTargetRequirementForLogStream() throws {
        try skipIfLegacyValidationDisabled()
        let yamlString = """
        services:
          test:
            image: test:latest
            x-apple-relays:
            - type: "vsock-log-stream"
              port: 5001
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        let loader = RelayConfigurationLoader()

        let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }

        XCTAssertThrowsError(try loader.loadRelays(from: services)) { error in
            guard let configError = error as? RelayConfigurationLoader.ConfigurationError else {
                XCTFail("Wrong error type")
                return
            }
            if case .missingTarget(let service) = configError {
                XCTAssertEqual(service, "test")
            } else {
                XCTFail("Expected missingTarget error, got \(configError)")
            }
        }
    }

    func testLegacyDatabaseRelayWorksWithoutTarget() throws {
        try skipIfLegacyValidationDisabled()
        let yamlString = """
        services:
          db:
            image: postgres:15
            x-apple-relays:
            - type: "vsock-db"
              port: 5432
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        let loader = RelayConfigurationLoader()

        let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }

        // Should NOT throw missingTarget error
        let loadedRelays = try loader.loadRelays(from: services)
XCTAssertEqual(loadedRelays.count, 1)
    XCTAssertNil(loadedRelays[0].target)
}

func testLegacyUDSRelayTypeInComposeSchema() throws {
    try skipIfLegacyValidationDisabled()
    // Plan 88: Test that 'type: uds' can be parsed from compose YAML
    // This tests the transparent mapping decision (Decision 3)
    let yamlString = """
services:
  db:
    image: postgres:15
    x-apple-relays:
    - type: "uds"
      port: 5432
      socket_path: "/tmp/test-uds.sock"
"""

    let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
    let loader = RelayConfigurationLoader()

    let services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
        guard let service = service else { return nil }
        return (name, service)
    }

    // This will fail until SupportedRelayType has .uds case - TDD workflow
    let loadedRelays = try loader.loadRelays(from: services)
    XCTAssertEqual(loadedRelays.count, 1, "Should load UDS relay from YAML")
}
}
