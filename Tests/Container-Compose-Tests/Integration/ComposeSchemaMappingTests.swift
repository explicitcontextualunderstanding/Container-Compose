import XCTest
@testable import Container_Compose

// MARK: - Compose YAML Schema Mapping Tests (Plan 77 Phase 6)

final class ComposeSchemaMappingTests: XCTestCase {
    
    // MARK: - End-to-End Schema Parsing
    
    func testParsesFullFleetConfiguration() throws {
        // Simulate parsing the actual Hermes/Honcho compose file
        let yamlString = """
        name: apple-honcho
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
                priority: "high"
              - type: "vsock-mcp-bridge"
                port: 5002
                target: "honcho-hub"
                priority: "high"
              - type: "vsock-ane-embedding"
                port: 6000
                priority: "high"
          
          honcho-hub:
            image: honcho:latest
          
          code-graph:
            image: codegraph:latest
        """
        
        // Parse YAML
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        
        // Verify services parsed
        XCTAssertEqual(dockerCompose.services.count, 4)
        
        // Verify honcho-db has vsock-db relay
        let dbService = dockerCompose.services["honcho-db"]
        XCTAssertNotNil(dbService?.x_apple_relays)
        XCTAssertEqual(dbService?.x_apple_relays?.count, 1)
        XCTAssertEqual(dbService?.x_apple_relays?[0].type, "vsock-db")
        XCTAssertEqual(dbService?.x_apple_relays?[0].port, 5432)
        
        // Verify hermes has all three relays
        let hermesService = dockerCompose.services["hermes"]
        XCTAssertNotNil(hermesService?.x_apple_relays)
        XCTAssertEqual(hermesService?.x_apple_relays?.count, 3)
        
        // Load relays via configuration loader
        let loader = RelayConfigurationLoader()
        let services = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }
        
        let loadedRelays = try loader.loadRelays(from: services)
        
        // Should have 4 relays total (1 DB + 3 Hermes)
        XCTAssertEqual(loadedRelays.count, 4)
        
        // Verify types
        let dbRelay = loadedRelays.first { $0.type == .vsockDb }
        XCTAssertNotNil(dbRelay)
        XCTAssertEqual(dbRelay?.port, 5432)
        
        let aneRelay = loadedRelays.first { $0.type == .vsockAneEmbedding }
        XCTAssertNotNil(aneRelay)
        XCTAssertEqual(aneRelay?.port, 6000)
        
        let mcpRelay = loadedRelays.first { $0.type == .vsockMcpBridge }
        XCTAssertNotNil(mcpRelay)
        XCTAssertEqual(mcpRelay?.port, 5002)
        XCTAssertEqual(mcpRelay?.target, "honcho-hub")
        
        let logRelay = loadedRelays.first { $0.type == .vsockLogStream }
        XCTAssertNotNil(logRelay)
        XCTAssertEqual(logRelay?.port, 5001)
        XCTAssertEqual(logRelay?.target, "code-graph")
    }
    
    func testRejectsMalformedRelayType() {
        let yamlString = """
        services:
          test-service:
            image: test:latest
            x-apple-relays:
              - type: "invalid-relay-type"
                port: 5000
        """
        
        XCTAssertThrowsError(try YAMLDecoder().decode(DockerCompose.self, from: yamlString)) { error in
            // YAMLDecoder may throw during decoding
            XCTAssertNotNil(error)
        }
    }
    
    func testHandlesServicesWithoutRelays() throws {
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
        
        let services = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }
        
        XCTAssertTrue(loader.hasAppleRelays(in: services))
        
        let loadedRelays = try loader.loadRelays(from: services)
        XCTAssertEqual(loadedRelays.count, 1)
        XCTAssertEqual(loadedRelays[0].serviceName, "service-with-relay")
    }
    
    func testValidatesPortUniquenessAcrossServices() {
        // Same port on different services should fail
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
        
        XCTAssertThrowsError(try YAMLDecoder().decode(DockerCompose.self, from: yamlString)) { error in
            // Should throw port conflict error during loading
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Security Policy Tests
    
    func testEnforcesTargetRequirementForMcpBridge() {
        let yamlString = """
        services:
          test:
            image: test:latest
            x-apple-relays:
              - type: "vsock-mcp-bridge"
                port: 5002
        """
        
        XCTAssertThrowsError(try YAMLDecoder().decode(DockerCompose.self, from: yamlString)) { error in
            XCTAssertNotNil(error)
        }
    }
    
    func testEnforcesTargetRequirementForLogStream() {
        let yamlString = """
        services:
          test:
            image: test:latest
            x-apple-relays:
              - type: "vsock-log-stream"
                port: 5001
        """
        
        XCTAssertThrowsError(try YAMLDecoder().decode(DockerCompose.self, from: yamlString)) { error in
            XCTAssertNotNil(error)
        }
    }
    
    func testDatabaseRelayWorksWithoutTarget() throws {
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
        
        let services = dockerCompose.services.compactMap { name, service in
            guard let service = service else { return nil }
            return (name, service)
        }
        
        // Should NOT throw missingTarget error
        let loadedRelays = try loader.loadRelays(from: services)
        XCTAssertEqual(loadedRelays.count, 1)
        XCTAssertNil(loadedRelays[0].target)
    }
}
