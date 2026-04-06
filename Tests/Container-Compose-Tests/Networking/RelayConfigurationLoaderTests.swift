import XCTest
@testable import Container_Compose

// MARK: - Relay Configuration Loader Tests (Plan 77 Phase 6)

final class RelayConfigurationLoaderTests: XCTestCase {
    
    var loader: RelayConfigurationLoader!
    
    override func setUp() {
        super.setUp()
        loader = RelayConfigurationLoader()
    }
    
    override func tearDown() {
        loader = nil
        super.tearDown()
    }
    
    // MARK: - Basic Loading Tests
    
    func testLoadsValidConfiguration() throws {
        // Create a service with x-apple-relays
        let relay1 = AppleRelayConfig(type: "vsock-ane-embedding", port: 6000, priority: "high")
        let relay2 = AppleRelayConfig(type: "vsock-mcp-bridge", port: 5002, target: "honcho-hub")
        
        let service = Service(
            image: "hermes:v26",
            x_apple_relays: [relay1, relay2]
        )
        
        let services = [("hermes", service)]
        
        // Load relays
        let loaded = try loader.loadRelays(from: services)
        
        XCTAssertEqual(loaded.count, 2, "Should load 2 relays")
        
        XCTAssertEqual(loaded[0].type, .vsockAneEmbedding)
        XCTAssertEqual(loaded[0].port, 6000)
        XCTAssertEqual(loaded[0].serviceName, "hermes")
        XCTAssertNil(loaded[0].target)
        
        XCTAssertEqual(loaded[1].type, .vsockMcpBridge)
        XCTAssertEqual(loaded[1].port, 5002)
        XCTAssertEqual(loaded[1].target, "honcho-hub")
    }
    
    func testDetectsPresenceOfAppleRelays() {
        // Service without relays
        let service1 = Service(image: "postgres:15")
        XCTAssertFalse(loader.hasAppleRelays(in: [("db", service1)]))
        
        // Service with relays
        let relay = AppleRelayConfig(type: "vsock-log-stream", port: 5001, target: "code-graph")
        let service2 = Service(image: "hermes:v26", x_apple_relays: [relay])
        XCTAssertTrue(loader.hasAppleRelays(in: [("hermes", service2)]))
    }
    
    // MARK: - Validation Tests
    
    func testRejectsUnsupportedRelayType() {
        let relay = AppleRelayConfig(type: "invalid-type", port: 5001)
        let service = Service(image: "test:latest", x_apple_relays: [relay])
        
        XCTAssertThrowsError(try loader.loadRelays(from: [("test", service)])) { error in
            guard let configError = error as? RelayConfigurationLoader.ConfigurationError else {
                XCTFail("Wrong error type")
                return
            }
            
            if case .unsupportedRelayType(let type) = configError {
                XCTAssertEqual(type, "invalid-type")
            } else {
                XCTFail("Wrong error case")
            }
        }
    }
    
    func testRejectsInvalidPortNumbers() {
        // Port 0
        let relay1 = AppleRelayConfig(type: "vsock-generic", port: 0)
        let service1 = Service(image: "test:latest", x_apple_relays: [relay1])
        
        XCTAssertThrowsError(try loader.loadRelays(from: [("test", service1)])) { error in
            guard let configError = error as? RelayConfigurationLoader.ConfigurationError,
                  case .invalidPort(let port) = configError else {
                XCTFail("Wrong error type")
                return
            }
            XCTAssertEqual(port, 0)
        }
        
        // Port > 65535
        let relay2 = AppleRelayConfig(type: "vsock-generic", port: 70000)
        let service2 = Service(image: "test:latest", x_apple_relays: [relay2])
        
        XCTAssertThrowsError(try loader.loadRelays(from: [("test", service2)])) { error in
            guard let configError = error as? RelayConfigurationLoader.ConfigurationError,
                  case .invalidPort(let port) = configError else {
                XCTFail("Wrong error type")
                return
            }
            XCTAssertEqual(port, 70000)
        }
    }
    
    func testDetectsPortConflicts() {
        let relay1 = AppleRelayConfig(type: "vsock-ane-embedding", port: 6000)
        let relay2 = AppleRelayConfig(type: "vsock-generic", port: 6000)
        
        let service1 = Service(image: "service1:latest", x_apple_relays: [relay1])
        let service2 = Service(image: "service2:latest", x_apple_relays: [relay2])
        
        let services = [("service1", service1), ("service2", service2)]
        
        XCTAssertThrowsError(try loader.loadRelays(from: services)) { error in
            guard let configError = error as? RelayConfigurationLoader.ConfigurationError,
                  case .conflictingPort(let port, let service) = configError else {
                XCTFail("Wrong error type")
                return
            }
            XCTAssertEqual(port, 6000)
            XCTAssertEqual(service, "service1")
        }
    }
    
    func testRequiresTargetForMcpBridge() {
        // MCP bridge requires target
        let relay = AppleRelayConfig(type: "vsock-mcp-bridge", port: 5002)
        let service = Service(image: "test:latest", x_apple_relays: [relay])
        
        XCTAssertThrowsError(try loader.loadRelays(from: [("test", service)])) { error in
            guard let configError = error as? RelayConfigurationLoader.ConfigurationError,
                  case .missingTarget(let serviceName) = configError else {
                XCTFail("Wrong error type")
                return
            }
            XCTAssertEqual(serviceName, "test")
        }
    }
    
    func testRequiresTargetForLogStream() {
        // Log stream requires target
        let relay = AppleRelayConfig(type: "vsock-log-stream", port: 5001)
        let service = Service(image: "test:latest", x_apple_relays: [relay])
        
        XCTAssertThrowsError(try loader.loadRelays(from: [("test", service)])) { error in
            guard let configError = error as? RelayConfigurationLoader.ConfigurationError,
                  case .missingTarget(let serviceName) = configError else {
                XCTFail("Wrong error type")
                return
            }
            XCTAssertEqual(serviceName, "test")
        }
    }
    
    // MARK: - Integration Tests
    
    func testLoadsHermesHonchoConfiguration() throws {
        // Simulate the actual Hermes/Honcho compose configuration
        let hermesRelays = [
            AppleRelayConfig(type: "vsock-log-stream", port: 5001, target: "code-graph", priority: "high"),
            AppleRelayConfig(type: "vsock-mcp-bridge", port: 5002, target: "honcho-hub", priority: "high"),
            AppleRelayConfig(type: "vsock-ane-embedding", port: 6000, priority: "high")
        ]
        
        let hermes = Service(image: "hermes:v26", x_apple_relays: hermesRelays)
        
        let services = [
            ("hermes", hermes),
            ("honcho-hub", Service(image: "honcho:latest")),
            ("code-graph", Service(image: "codegraph:latest"))
        ]
        
        let loaded = try loader.loadRelays(from: services)
        
        XCTAssertEqual(loaded.count, 3)
        
        // Verify log stream
        XCTAssertEqual(loaded[0].type, .vsockLogStream)
        XCTAssertEqual(loaded[0].port, 5001)
        XCTAssertEqual(loaded[0].target, "code-graph")
        
        // Verify MCP bridge
        XCTAssertEqual(loaded[1].type, .vsockMcpBridge)
        XCTAssertEqual(loaded[1].port, 5002)
        XCTAssertEqual(loaded[1].target, "honcho-hub")
        
        // Verify ANE embedding
        XCTAssertEqual(loaded[2].type, .vsockAneEmbedding)
        XCTAssertEqual(loaded[2].port, 6000)
        XCTAssertNil(loaded[2].target)
    }
    
    func testSummarizeOutputs() {
        let relays = [
            RelayConfigurationLoader.LoadedRelay(
                serviceName: "hermes",
                type: .vsockAneEmbedding,
                port: 6000,
                priority: "high"
            ),
            RelayConfigurationLoader.LoadedRelay(
                serviceName: "hermes",
                type: .vsockMcpBridge,
                port: 5002,
                target: "honcho-hub",
                priority: "high"
            )
        ]
        
        let summary = loader.summarize(relays)
        
        XCTAssertTrue(summary.contains("Port 6000"))
        XCTAssertTrue(summary.contains("ANE Native Embedding Relay"))
        XCTAssertTrue(summary.contains("Port 5002"))
        XCTAssertTrue(summary.contains("MCP Bridge Relay"))
        XCTAssertTrue(summary.contains("honcho-hub"))
    }
    
    func testSummarizeEmptyRelays() {
        let summary = loader.summarize([])
        XCTAssertEqual(summary, "No vsock relays configured")
    }
    
    // MARK: - Database Relay Tests
    
    func testLoadsDatabaseRelayConfiguration() throws {
        // Test PostgreSQL/WAL-G vsock relay
        let relay = AppleRelayConfig(type: "vsock-db", port: 5432, priority: "high")
        let service = Service(image: "walg-db:latest", x_apple_relays: [relay])
        
        let loaded = try loader.loadRelays(from: [("honcho-db", service)])
        
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].type, .vsockDb)
        XCTAssertEqual(loaded[0].port, 5432)
        XCTAssertNil(loaded[0].target, "Database relay should not require target")
    }
    
    func testDatabaseRelayDoesNotRequireTarget() throws {
        // vsock-db should work without target (single endpoint)
        let relay = AppleRelayConfig(type: "vsock-db", port: 5432)
        let service = Service(image: "postgres:15", x_apple_relays: [relay])
        
        // Should not throw missingTarget error
        let loaded = try loader.loadRelays(from: [("db", service)])
        XCTAssertEqual(loaded.count, 1)
    }
    
    func testSupportedRelayTypesIncludeDatabase() {
        let allTypes = RelayConfigurationLoader.SupportedRelayType.allCases
        XCTAssertTrue(allTypes.contains(.vsockDb))
        
        XCTAssertEqual(RelayConfigurationLoader.SupportedRelayType.vsockDb.rawValue, "vsock-db")
        XCTAssertEqual(RelayConfigurationLoader.SupportedRelayType.vsockDb.description, "Database VSOCK Relay (PostgreSQL/WAL-G)")
    }
    
    func testRequiresTargetProperty() {
        // Types that require target
        XCTAssertTrue(RelayConfigurationLoader.SupportedRelayType.vsockMcpBridge.requiresTarget)
        XCTAssertTrue(RelayConfigurationLoader.SupportedRelayType.vsockLogStream.requiresTarget)
        
        // Types that don't require target
        XCTAssertFalse(RelayConfigurationLoader.SupportedRelayType.vsockAneEmbedding.requiresTarget)
        XCTAssertFalse(RelayConfigurationLoader.SupportedRelayType.vsockDb.requiresTarget)
        XCTAssertFalse(RelayConfigurationLoader.SupportedRelayType.vsockGeneric.requiresTarget)
    }
}
