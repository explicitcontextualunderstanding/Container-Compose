// SecureRelayManagerTests.swift
// Unit tests for Option B architecture: SecureRelayManager wrapper
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import XCTest
@testable import SecurityHardening

@available(macOS 26.0, *)
final class SecureRelayManagerTests: XCTestCase {

    var secureManager: SecureRelayManager!

    override func setUp() async throws {
        try await super.setUp()
        // Use development config for testing
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

    func testSecurityCheckResultEquality() {
        let result1 = SecureRelayManager.SecurityCheckResult.passed
        let result2 = SecureRelayManager.SecurityCheckResult.passed
        let result3 = SecureRelayManager.SecurityCheckResult.blocked(.amfiValidation, message: "Error")

        XCTAssertEqual(result1, result2)
        XCTAssertNotEqual(result1, result3)
    }

    // MARK: - SecurityGate Tests

    func testSecurityGateDescriptions() {
        XCTAssertEqual(SecureRelayManager.SecurityGate.tccPreflight.description, "TCC Preflight")
        XCTAssertEqual(SecureRelayManager.SecurityGate.amfiValidation.description, "AMFI Validation")
        XCTAssertEqual(SecureRelayManager.SecurityGate.horizontalIsolation.description, "Horizontal Isolation")
    }

    // MARK: - Relay Validation Tests

    func testValidateRelayStartupWithDevelopmentConfig() async {
        // Development config passes all gates
        let config = RelayConfiguration(
            type: "vsock-db",
            transport: .vsock(cid: 2, port: 5432)
        )

        let result = await secureManager.validateRelayStartup(config)
        XCTAssertTrue(result.passed)
        XCTAssertNil(result.blockedBy)
    }

    func testCanStartRelayWithDevelopmentConfig() async {
        let config = RelayConfiguration(
            type: "vsock-db",
            transport: .vsock(cid: 2, port: 5432)
        )

        let canStart = await secureManager.canStartRelay(config)
        XCTAssertTrue(canStart)
    }

    // MARK: - Container Startup Tests

    func testValidateContainerStartupWithDevelopmentConfig() async {
        let result = await secureManager.validateContainerStartup()
        XCTAssertTrue(result.passed)
    }

    // MARK: - CID Communication Tests

    func testValidateCIDCommunicationHostToGuest() async {
        // Host (CID 2) to Guest (CID 3) should pass
        let result = await secureManager.validateCIDCommunication(
            sourceCID: 2,
            targetCID: 3,
            port: 5432
        )
        XCTAssertTrue(result.passed)
    }

    func testValidateCIDCommunicationGuestToHost() async {
        // Guest (CID 3) to Host (CID 2) should pass
        let result = await secureManager.validateCIDCommunication(
            sourceCID: 3,
            targetCID: 2,
            port: 5432
        )
        XCTAssertTrue(result.passed)
    }

    func testValidateCIDCommunicationGuestToGuest() async {
        // Production config would block this
        // Development config passes
        let result = await secureManager.validateCIDCommunication(
            sourceCID: 3,
            targetCID: 4,
            port: 5432
        )
        XCTAssertTrue(result.passed) // Development config doesn't enforce
    }

    // MARK: - Status Tests

    func testSecurityStatus() async {
        let status = await secureManager.securityStatus()
        // Development config has enforcement disabled
        XCTAssertTrue(status.tccAuthorized) // No enforcement = passes
        XCTAssertFalse(status.amfiValidated) // Unsigned binary
        XCTAssertTrue(status.isolationCompliant) // No enforcement
        XCTAssertFalse(status.readyForPhase6) // Not validated
    }

    func testReadyForPhase6() async {
        let ready = await secureManager.readyForPhase6()
        XCTAssertFalse(ready) // Development config not validated
    }

    // MARK: - ESF Logging Tests

    func testLogVMStartWithoutESFClient() async {
        // Should not crash without ESFClient
        await secureManager.logVMStart(cid: 3, process: "test")
    }

    func testLogRelayStartedWithoutESFClient() async {
        // Should not crash without ESFClient
        await secureManager.logRelayStarted(port: 5432, transport: "vsock")
    }

    // MARK: - SecurityStatus Tests

    func testSecurityStatusCreation() {
        let status = SecurityStatus(
            tccAuthorized: true,
            amfiValidated: true,
            isolationCompliant: true,
            readyForPhase6: true
        )
        XCTAssertTrue(status.tccAuthorized)
        XCTAssertTrue(status.amfiValidated)
        XCTAssertTrue(status.isolationCompliant)
        XCTAssertTrue(status.readyForPhase6)
    }

    func testSecurityStatusEquality() {
        let status1 = SecurityStatus(
            tccAuthorized: true,
            amfiValidated: true,
            isolationCompliant: true,
            readyForPhase6: true
        )
        let status2 = SecurityStatus(
            tccAuthorized: true,
            amfiValidated: true,
            isolationCompliant: true,
            readyForPhase6: true
        )
        let status3 = SecurityStatus(
            tccAuthorized: false,
            amfiValidated: true,
            isolationCompliant: true,
            readyForPhase6: true
        )

        XCTAssertEqual(status1, status2)
        XCTAssertNotEqual(status1, status3)
    }

    // MARK: - Sendable Compliance Tests

    func testConfigurationIsSendable() async {
        let config = SecureRelayManager.Configuration.production

        let task = Task {
            return config.logSecurityEvents
        }

        let result = await task.value
        XCTAssertTrue(result)
    }

    func testSecurityCheckResultIsSendable() async {
        let result = SecureRelayManager.SecurityCheckResult.passed

        let task = Task {
            return result.passed
        }

        let passed = await task.value
        XCTAssertTrue(passed)
    }

    func testSecurityStatusIsSendable() async {
        let status = SecurityStatus(
            tccAuthorized: true,
            amfiValidated: true,
            isolationCompliant: true,
            readyForPhase6: true
        )

        let task = Task {
            return status.readyForPhase6
        }

        let ready = await task.value
        XCTAssertTrue(ready)
    }

    func testSecureManagerIsSendable() async {
        let testManager = SecureRelayManager(configuration: .development)

        let task = Task {
            return await testManager.canStartRelay(
                RelayConfiguration(type: "test", transport: .tcp(port: 8080))
            )
        }

        let canStart = await task.value
        XCTAssertTrue(canStart)
    }

    // MARK: - Integration Pattern Tests

    func testFullSecurityFlow() async {
        // Step 1: Validate container startup
        let containerResult = await secureManager.validateContainerStartup()
        XCTAssertTrue(containerResult.passed)

        // Step 2: Validate relay startup
        let config = RelayConfiguration(
            type: "vsock-db",
            transport: .vsock(cid: 2, port: 5432)
        )
        let relayResult = await secureManager.validateRelayStartup(config)
        XCTAssertTrue(relayResult.passed)

        // Step 3: Check security status
        let status = await secureManager.securityStatus()
        XCTAssertNotNil(status)

        // Step 4: Validate CID communication
        let cidResult = await secureManager.validateCIDCommunication(
            sourceCID: 3,
            targetCID: 2,
            port: 5432
        )
        XCTAssertTrue(cidResult.passed)
    }

    // MARK: - RelayManager Wrapper Pattern Tests

    func testRelayManagerWrapperPattern() async {
        // Simulate RelayManager wrapper usage
        let config = RelayConfiguration(
            type: "vsock-db",
            transport: .vsock(cid: 2, port: 5432)
        )

        // Check if can start
        guard await secureManager.canStartRelay(config) else {
            XCTFail("Should be able to start relay with dev config")
            return
        }

        // In real usage, would now call underlying RelayManager
        // try await relayManager.startRelay(config)
        XCTAssertTrue(true)
    }

    // MARK: - Phase 6 Integration Tests

    func testPhase6Readiness() async {
        // Check if ready for Phase 6 (socat removal)
        let ready = await secureManager.readyForPhase6()

        // Development config: not validated
        XCTAssertFalse(ready)

        // Production would check AMFI validation
    }

    // MARK: - Error Handling Tests

    func testLastSecurityErrorInitiallyNil() async {
        let error = await secureManager.lastSecurityError()
        XCTAssertNil(error)
    }
}

// MARK: - RelayConfiguration Helpers

extension RelayConfiguration {
    // Helper for testing
    init(type: String, transport: RelayTransport) {
        self.init(
            type: type,
            transport: transport,
            socketPath: nil
        )
    }
}
