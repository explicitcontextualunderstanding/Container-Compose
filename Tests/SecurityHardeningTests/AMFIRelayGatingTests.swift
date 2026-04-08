// AMFIRelayGatingTests.swift
// Unit tests for Component 6: AMFI Gating for Phase 6
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import XCTest
@testable import SecurityHardening

@available(macOS 26.0, *)
final class AMFIRelayGatingTests: XCTestCase {

    var gating: AMFIRelayGating!

    override func setUp() async throws {
        try await super.setUp()
        // Use development config to avoid actual AMFI checks
        gating = AMFIRelayGating(configuration: .development)
    }

    override func tearDown() async throws {
        gating = nil
        try await super.tearDown()
    }

    // MARK: - Configuration Tests

    func testProductionConfiguration() {
        let config = AMFIRelayGating.Configuration.production
        XCTAssertTrue(config.enforceAMFIValidation)
        XCTAssertTrue(config.requireHypervisorEntitlement)
        XCTAssertFalse(config.allowAdHocSigning)
        XCTAssertTrue(config.gateSocatRemoval)
    }

    func testDevelopmentConfiguration() {
        let config = AMFIRelayGating.Configuration.development
        XCTAssertFalse(config.enforceAMFIValidation)
        XCTAssertFalse(config.requireHypervisorEntitlement)
        XCTAssertTrue(config.allowAdHocSigning)
        XCTAssertFalse(config.gateSocatRemoval)
    }

    // MARK: - GatingResult Tests

    func testGatingResultValidated() {
        let result = AMFIRelayGating.GatingResult.validated
        XCTAssertTrue(result.canRemoveSocat)
        XCTAssertTrue(result.isValidated)
        XCTAssertTrue(result.shouldUseNativeRelay)
    }

    func testGatingResultFailed() {
        let result = AMFIRelayGating.GatingResult.failed("Test error", issues: [.unsigned])
        XCTAssertFalse(result.canRemoveSocat)
        XCTAssertFalse(result.isValidated)
        XCTAssertFalse(result.shouldUseNativeRelay)
        XCTAssertEqual(result.errorMessage, "Test error")
        XCTAssertEqual(result.validationIssues.count, 1)
    }

    func testGatingResultEquality() {
        let result1 = AMFIRelayGating.GatingResult.validated
        let result2 = AMFIRelayGating.GatingResult.validated
        let result3 = AMFIRelayGating.GatingResult.failed("Error")

        XCTAssertEqual(result1, result2)
        XCTAssertNotEqual(result1, result3)
    }

    // MARK: - AMFIGatingError Tests

    func testAMFIGatingErrorDescriptions() {
        XCTAssertEqual(
            AMFIRelayGating.AMFIGatingError.signatureInvalid.description,
            "Code signature is invalid"
        )
        XCTAssertEqual(
            AMFIRelayGating.AMFIGatingError.hypervisorEntitlementMissing.description,
            "Hypervisor entitlement not found"
        )
        XCTAssertEqual(
            AMFIRelayGating.AMFIGatingError.gatingDisabled.description,
            "AMFI gating is disabled"
        )
    }

    // MARK: - Validation Tests

    func testValidateForSocatRemovalWithDisabledEnforcement() async {
        // Development config has enforcement disabled
        let result = await gating.validateForSocatRemoval()
        XCTAssertTrue(result.canRemoveSocat)
        XCTAssertFalse(result.isValidated)
        XCTAssertEqual(result.errorMessage, "AMFI validation disabled")
        XCTAssertTrue(result.shouldUseNativeRelay)
    }

    func testValidateBeforeRelayStartWithDisabledEnforcement() async {
        let canStart = await gating.validateBeforeRelayStart()
        XCTAssertTrue(canStart)
    }

    func testCanRemoveSocatWithDisabledEnforcement() async {
        let canRemove = await gating.canRemoveSocat()
        XCTAssertTrue(canRemove)
    }

    // MARK: - Last Gating Result Tests

    func testLastGatingResult() async {
        // Initially nil
        let initial = await gating.lastGating()
        XCTAssertNil(initial)

        // After validation
        _ = await gating.validateForSocatRemoval()
        let result = await gating.lastGating()
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.canRemoveSocat ?? false)
    }

    // MARK: - Convenience Method Tests

    func testIsSecurityValidatedWithDisabledEnforcement() async {
        let isValidated = await gating.isSecurityValidated()
        XCTAssertTrue(isValidated) // Returns true when disabled
    }

    func testLastErrorMessage() async {
        // Initially nil
        let initial = await gating.lastErrorMessage()
        XCTAssertNil(initial)

        // After validation
        _ = await gating.validateForSocatRemoval()
        let message = await gating.lastErrorMessage()
        XCTAssertEqual(message, "AMFI validation disabled")
    }

    // MARK: - Integration Method Tests

    func testGatingPassed() async {
        let passed = await gating.gatingPassed()
        XCTAssertTrue(passed)
    }

    func testFormattedError() async {
        _ = await gating.validateForSocatRemoval()
        let error = await gating.formattedError()
        XCTAssertEqual(error, "Security gating: AMFI validation disabled")
    }

    func testPhase6Decision() async {
        let (canRemove, error) = await gating.phase6Decision()
        XCTAssertTrue(canRemove)
        XCTAssertEqual(error, "AMFI validation disabled")
    }

    // MARK: - Sendable Compliance Tests

    func testConfigurationIsSendable() async {
        let config = AMFIRelayGating.Configuration.production

        let task = Task {
            return config.enforceAMFIValidation
        }

        let result = await task.value
        XCTAssertTrue(result)
    }

    func testGatingResultIsSendable() async {
        let result = AMFIRelayGating.GatingResult.validated

        let task = Task {
            return result.canRemoveSocat
        }

        let canRemove = await task.value
        XCTAssertTrue(canRemove)
    }

    func testGatingIsSendable() async {
        let testGating = AMFIRelayGating(configuration: .development)

        let task = Task {
            return await testGating.canRemoveSocat()
        }

        let canRemove = await task.value
        XCTAssertTrue(canRemove)
    }

    // MARK: - Integration Pattern Tests

    func testFullGatingFlow() async {
        // Step 1: Validate for socat removal
        let result = await gating.validateForSocatRemoval()

        // Step 2: Check if can remove
        let canRemove = await gating.canRemoveSocat()
        XCTAssertEqual(canRemove, result.canRemoveSocat)

        // Step 3: Verify last result
        let lastResult = await gating.lastGating()
        XCTAssertEqual(result, lastResult)

        // Step 4: Check phase 6 decision
        let (decision, error) = await gating.phase6Decision()
        XCTAssertEqual(decision, result.canRemoveSocat)
    }

    // MARK: - Plan 84 Phase 6 Integration Tests

    func testRelayManagerIntegrationPattern() async {
        // Simulate RelayManager.startRelay() pattern

        // Step 1: Validate before relay start
        let canStart = await gating.validateBeforeRelayStart()
        XCTAssertTrue(canStart)

        // Step 2: Use gating helper
        let passed = await gating.gatingPassed()
        XCTAssertTrue(passed)
    }

    func testOrchestratorPhase6Pattern() async {
        // Simulate orchestrator deciding socat fate

        // Step 1: Get phase 6 decision
        let (canRemove, error) = await gating.phase6Decision()

        // Step 2: If can remove, proceed with native relay
        if canRemove {
            // Native relay activated
            XCTAssertTrue(canRemove)
        } else {
            // Keep socat
            XCTFail("Should be able to remove socat with dev config")
        }

        XCTAssertEqual(error, "AMFI validation disabled")
    }

    // MARK: - Error Handling Tests

    func testAMFIGatingErrorEquality() {
        XCTAssertEqual(
            AMFIRelayGating.AMFIGatingError.signatureInvalid,
            AMFIRelayGating.AMFIGatingError.signatureInvalid
        )
        XCTAssertNotEqual(
            AMFIRelayGating.AMFIGatingError.signatureInvalid,
            AMFIRelayGating.AMFIGatingError.gatingDisabled
        )
    }

    // MARK: - Non-Existent Binary Tests

    func testValidateNonExistentBinary() async {
        // Development config should still return true (validation disabled)
        let result = await gating.validateForSocatRemoval(binaryPath: "/nonexistent/path")
        XCTAssertTrue(result.canRemoveSocat)
    }
}
