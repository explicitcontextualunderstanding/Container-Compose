// TCCRelayIntegrationTests.swift
// Unit tests for Component 5: TCC Integration in RelayManager
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import XCTest
@testable import SecurityHardening

@available(macOS 26.0, *)
final class TCCRelayIntegrationTests: XCTestCase {

    var integration: TCCRelayIntegration!

    override func setUp() async throws {
        try await super.setUp()
        // Use development config to avoid actual TCC checks in tests
        integration = TCCRelayIntegration(configuration: .development)
    }

    override func tearDown() async throws {
        integration = nil
        try await super.tearDown()
    }

    // MARK: - Configuration Tests

    func testProductionConfiguration() {
        let config = TCCRelayIntegration.Configuration.production
        XCTAssertTrue(config.enforceTCCAuthorization)
        XCTAssertEqual(config.preflightTimeout, 30.0)
        XCTAssertFalse(config.allowPromptIfNotDetermined)
    }

    func testDevelopmentConfiguration() {
        let config = TCCRelayIntegration.Configuration.development
        XCTAssertFalse(config.enforceTCCAuthorization)
        XCTAssertEqual(config.preflightTimeout, 10.0)
        XCTAssertTrue(config.allowPromptIfNotDetermined)
    }

    func testCustomConfiguration() {
        let config = TCCRelayIntegration.Configuration(
            enforceTCCAuthorization: true,
            preflightTimeout: 60.0,
            allowPromptIfNotDetermined: true
        )
        XCTAssertTrue(config.enforceTCCAuthorization)
        XCTAssertEqual(config.preflightTimeout, 60.0)
        XCTAssertTrue(config.allowPromptIfNotDetermined)
    }

    // MARK: - PreflightResult Tests

    func testPreflightResultAuthorized() {
        let result = TCCRelayIntegration.PreflightResult.authorized
        XCTAssertTrue(result.canProceed)
        XCTAssertEqual(result.status, .authorized)
        XCTAssertNil(result.errorMessage)
        XCTAssertFalse(result.shouldBlockStartup)
    }

    func testPreflightResultEquality() {
        let result1 = TCCRelayIntegration.PreflightResult(
            canProceed: true,
            status: .authorized
        )
        let result2 = TCCRelayIntegration.PreflightResult(
            canProceed: true,
            status: .authorized
        )
        let result3 = TCCRelayIntegration.PreflightResult(
            canProceed: false,
            status: .denied
        )

        XCTAssertEqual(result1, result2)
        XCTAssertNotEqual(result1, result3)
    }

    // MARK: - TCCIntegrationError Tests

    func testTCCIntegrationErrorDescriptions() {
        XCTAssertEqual(
            TCCRelayIntegration.TCCIntegrationError.tccDenied.description,
            "TCC permission denied for hypervisor"
        )
        XCTAssertEqual(
            TCCRelayIntegration.TCCIntegrationError.tccNotDetermined.description,
            "TCC permission not determined"
        )
        XCTAssertEqual(
            TCCRelayIntegration.TCCIntegrationError.preflightTimeout.description,
            "TCC preflight check timed out"
        )
    }

    // MARK: - Preflight Check Tests

    func testPreflightCheckWithDisabledEnforcement() async {
        // Development config has enforcement disabled
        let result = await integration.preflightCheck()
        XCTAssertTrue(result.canProceed)
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.errorMessage, "TCC enforcement disabled")
    }

    // MARK: - Relay Validation Tests

    func testValidateRelayStartupWithDisabledEnforcement() async {
        let canStart = await integration.validateRelayStartup(relayType: "vsock-db")
        XCTAssertTrue(canStart)
    }

    func testValidateContainerStartupWithDisabledEnforcement() async {
        let error = await integration.validateContainerStartup()
        XCTAssertNil(error) // No error when enforcement is disabled
    }

    // MARK: - Last Preflight Result Tests

    func testLastPreflightResult() async {
        // Initially nil
        let initial = await integration.lastPreflight()
        XCTAssertNil(initial)

        // After preflight check
        _ = await integration.preflightCheck()
        let result = await integration.lastPreflight()
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.canProceed ?? false)
    }

    // MARK: - Convenience Method Tests

    func testPreflightCheckPassed() async {
        // Development config should pass
        let passed = await integration.preflightCheckPassed()
        XCTAssertTrue(passed)
    }

    func testLastErrorMessage() async {
        // Initially nil
        let initial = await integration.lastErrorMessage()
        XCTAssertNil(initial)

        // After preflight
        _ = await integration.preflightCheck()
        let message = await integration.lastErrorMessage()
        XCTAssertEqual(message, "TCC enforcement disabled")
    }

    // MARK: - Sendable Compliance Tests

    func testConfigurationIsSendable() async {
        let config = TCCRelayIntegration.Configuration.production

        let task = Task {
            return config.enforceTCCAuthorization
        }

        let result = await task.value
        XCTAssertTrue(result)
    }

    func testPreflightResultIsSendable() async {
        let result = TCCRelayIntegration.PreflightResult.authorized

        let task = Task {
            return result.canProceed
        }

        let canProceed = await task.value
        XCTAssertTrue(canProceed)
    }

    func testIntegrationIsSendable() async {
        let testIntegration = TCCRelayIntegration(configuration: .development)

        let task = Task {
            return await testIntegration.preflightCheckPassed()
        }

        let passed = await task.value
        XCTAssertTrue(passed)
    }

    // MARK: - Integration Pattern Tests

    func testFullPreflightFlow() async {
        // Step 1: Check TCC status
        let status = await integration.detailedStatus()
        XCTAssertEqual(status.service, "com.apple.security.hypervisor")

        // Step 2: Run preflight
        let result = await integration.preflightCheck()

        // Step 3: Verify last result
        let lastResult = await integration.lastPreflight()
        XCTAssertEqual(result, lastResult)

        // Step 4: Check if can proceed
        let canProceed = await integration.preflightCheckPassed()
        XCTAssertEqual(canProceed, result.canProceed && !result.shouldBlockStartup)
    }

    // MARK: - Plan 84 Integration Simulation Tests

    func testRelayManagerIntegrationPattern() async {
        // Simulate RelayManager.startRelay() pattern

        // Step 1: TCC preflight
        let preflightResult = await integration.preflightCheck()

        // Step 2: Check if should proceed
        guard preflightResult.canProceed else {
            XCTFail("Should proceed with development config")
            return
        }

        // Step 3: Validate specific relay
        let canStart = await integration.validateRelayStartup(relayType: "vsock-db")
        XCTAssertTrue(canStart)
    }

    func testContainerStartupGatingPattern() async {
        // Simulate container-compose up pattern

        // Step 1: Validate container startup
        let error = await integration.validateContainerStartup()

        // Step 2: If error, block startup
        if let errorMessage = error {
            // In production, this would block
            print("Container startup blocked: \(errorMessage)")
        }

        // With development config, no error
        XCTAssertNil(error)
    }

    // MARK: - Error Handling Tests

    func testTCCIntegrationErrorEquality() {
        XCTAssertEqual(
            TCCRelayIntegration.TCCIntegrationError.tccDenied,
            TCCRelayIntegration.TCCIntegrationError.tccDenied
        )
        XCTAssertNotEqual(
            TCCRelayIntegration.TCCIntegrationError.tccDenied,
            TCCRelayIntegration.TCCIntegrationError.tccNotDetermined
        )
    }

    // MARK: - Timeout Tests

    func testPreflightTimeoutConfiguration() {
        let config = TCCRelayIntegration.Configuration(
            preflightTimeout: 5.0
        )
        XCTAssertEqual(config.preflightTimeout, 5.0)
    }
}
