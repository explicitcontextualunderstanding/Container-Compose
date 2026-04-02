import XCTest
@testable import ContainerComposeCore

final class HealthCommandTests: XCTestCase {
    
    // MARK: - Argument Mapping Tests
    
    func testHealthStatusEnumRawValues() throws {
        // Test that HealthStatusEnum has correct raw values
        XCTAssertEqual(HealthStatus.HealthStatusEnum.healthy.rawValue, "healthy")
        XCTAssertEqual(HealthStatus.HealthStatusEnum.unhealthy.rawValue, "unhealthy")
        XCTAssertEqual(HealthStatus.HealthStatusEnum.running.rawValue, "running")
        XCTAssertEqual(HealthStatus.HealthStatusEnum.stopped.rawValue, "stopped")
        XCTAssertEqual(HealthStatus.HealthStatusEnum.missing.rawValue, "missing")
    }
    
    func testHealthStatusEnumIcons() throws {
        // Test that each status has an icon
        XCTAssertEqual(HealthStatus.HealthStatusEnum.healthy.icon, "✓")
        XCTAssertEqual(HealthStatus.HealthStatusEnum.unhealthy.icon, "✗")
        XCTAssertEqual(HealthStatus.HealthStatusEnum.running.icon, "●")
        XCTAssertEqual(HealthStatus.HealthStatusEnum.stopped.icon, "○")
        XCTAssertEqual(HealthStatus.HealthStatusEnum.missing.icon, "?")
    }
    
    func testHealthStatusCodable() throws {
        // Test that HealthStatus can be encoded/decoded
        let status = HealthStatus(
            service: "web",
            container: "project-web",
            status: .healthy,
            healthCheck: true,
            message: "Health check passed"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(status)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(HealthStatus.self, from: data)
        
        XCTAssertEqual(decoded.service, "web")
        XCTAssertEqual(decoded.container, "project-web")
        XCTAssertEqual(decoded.status, .healthy)
        XCTAssertTrue(decoded.healthCheck)
        XCTAssertEqual(decoded.message, "Health check passed")
    }
    
    func testHealthStatusJSONOutput() throws {
        // Test JSON output format
        let statuses = [
            HealthStatus(service: "db", container: "project-db", status: .healthy, healthCheck: true, message: "OK"),
            HealthStatus(service: "web", container: "project-web", status: .unhealthy, healthCheck: true, message: "Failed")
        ]
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(statuses)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        
        XCTAssertTrue(json.contains("\"service\" : \"db\""))
        XCTAssertTrue(json.contains("\"status\" : \"healthy\""))
        XCTAssertTrue(json.contains("\"service\" : \"web\""))
        XCTAssertTrue(json.contains("\"status\" : \"unhealthy\""))
    }
    
    // MARK: - Healthcheck Execution Tests
    
    func testHealthCheckErrorDescription() throws {
        // Test that HealthCheckError has proper description
        let error = HealthCheckError("Container not found")
        XCTAssertEqual(error.message, "Container not found")
        XCTAssertEqual(error.description, "Container not found")
    }
    
    func testHealthStatusForMissingContainer() throws {
        // Test health status when container doesn't exist
        let status = HealthStatus(
            service: "nonexistent",
            container: "project-nonexistent",
            status: .missing,
            healthCheck: true,
            message: "Container not found"
        )
        
        XCTAssertEqual(status.status, .missing)
        // healthCheck is true because the service has a healthcheck configured
        // even though the container is missing
        XCTAssertTrue(status.healthCheck)
    }
    
    func testHealthStatusForStoppedContainer() throws {
        // Test health status when container is stopped
        let status = HealthStatus(
            service: "db",
            container: "project-db",
            status: .stopped,
            healthCheck: true,
            message: "Container not running (status: stopped)"
        )
        
        XCTAssertEqual(status.status, .stopped)
        XCTAssertTrue(status.healthCheck)
    }
    
    func testHealthStatusForNoHealthcheck() throws {
        // Test health status when no healthcheck configured
        let status = HealthStatus(
            service: "web",
            container: "project-web",
            status: .running,
            healthCheck: false,
            message: "No healthcheck configured"
        )
        
        XCTAssertEqual(status.status, .running)
        XCTAssertFalse(status.healthCheck)
    }
    
    // MARK: - Command Configuration Tests
    
    func testHealthCommandConfiguration() throws {
        // Test that HealthCommand has proper configuration
        XCTAssertEqual(HealthCommand.configuration.commandName, "health")
        XCTAssertTrue(HealthCommand.configuration.abstract.contains("health"))
    }
}
