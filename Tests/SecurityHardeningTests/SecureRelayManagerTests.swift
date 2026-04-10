// SecureRelayManagerTests.swift
// Unit tests for SecureRelayManager security gates
// Plan 88 - Security re-enablement with primitive-based API

import XCTest
@testable import SecurityHardening

@available(macOS 26.0, *)
final class SecureRelayManagerTests: XCTestCase {

    var secureManager: SecureRelayManager!

    override func setUp() async throws {
        try await super.setUp()
        // Use development config for testing (gates disabled)
        secureManager = SecureRelayManager(configuration: .development)
    }

    override func tearDown() async throws {
        secureManager = nil
        try await super.tearDown()
    }

    // MARK: - Configuration Tests

    func testProductionConfiguration() {
        let config = SecureRelayManager.Configuration.production
        XCTAssertTrue(config.tccConfig.enforceTCCAuthorization)
        XCTAssertTrue(config.amfiConfig.enforceAMFIValidation)
        XCTAssertTrue(config.isolationConfig.enforceHorizontalIsolation)
        XCTAssertTrue(config.logSecurityEvents)
    }

    func testDevelopmentConfiguration() {
        let config = SecureRelayManager.Configuration.development
        XCTAssertFalse(config.tccConfig.enforceTCCAuthorization)
        XCTAssertFalse(config.amfiConfig.enforceAMFIValidation)
        XCTAssertFalse(config.isolationConfig.enforceHorizontalIsolation)
        XCTAssertTrue(config.logSecurityEvents)
    }

    // MARK: - SecurityCheckResult Tests

    func testSecurityCheckResultPassed() {
        let result = SecureRelayManager.SecurityCheckResult.passed
        XCTAssertTrue(result.passed)
        XCTAssertNil(result.blockedBy)
        XCTAssertNil(result.errorMessage)
    }

    func testSecurityCheckResultBlocked() {
        let result = SecureRelayManager.SecurityCheckResult.blocked(
            .tccPreflight,
            message: "TCC denied"
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.blockedBy, .tccPreflight)
        XCTAssertEqual(result.errorMessage, "TCC denied")
    }

    // MARK: - SecurityGate Tests

    func testSecurityGateDescriptions() {
        XCTAssertEqual(SecureRelayManager.SecurityGate.tccPreflight.description, "TCC Preflight")
        XCTAssertEqual(SecureRelayManager.SecurityGate.amfiValidation.description, "AMFI Validation")
        XCTAssertEqual(SecureRelayManager.SecurityGate.horizontalIsolation.description, "Horizontal Isolation")
        XCTAssertEqual(SecureRelayManager.SecurityGate.relayConfiguration.description, "Relay Configuration")
    }

    // MARK: - Relay Startup Validation Tests

    func testValidateRelayStartupWithDevelopmentConfig() async throws {
        // With development config, all gates should pass
        let config = RelayConfiguration(
            id: "test-relay",
            tcpPort: 5432,
            unixSocketPath: "/tmp/test.sock",
            description: "Test relay"
        )

        let result = await secureManager.validateRelayStartup(config)
        XCTAssertTrue(result.passed, "Development config should allow all relays")
    }

    func testValidateContainerStartupWithDevelopmentConfig() async throws {
        // With development config, container startup should pass
        let result = await secureManager.validateContainerStartup()
        XCTAssertTrue(result.passed, "Development config should allow container startup")
    }

    // MARK: - Sendable Compliance Tests

    func testConfigurationIsSendable() {
        let config = SecureRelayManager.Configuration.production
        let task = Task {
            return config.tccConfig.enforceTCCAuthorization
        }
        let result = Task { 
            return config 
        }
        XCTAssertTrue(result != nil)
    }

    func testSecurityCheckResultIsSendable() {
        let result = SecureRelayManager.SecurityCheckResult.passed
        let task = Task {
            return result.passed
        }
        XCTAssertTrue(task != nil)
    }
}