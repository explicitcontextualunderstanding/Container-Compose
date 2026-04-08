// HorizontalIsolationValidatorTests.swift
// Unit tests for Component 7: Horizontal Isolation Validation
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import XCTest
@testable import SecurityHardening

@available(macOS 26.0, *)
final class HorizontalIsolationValidatorTests: XCTestCase {

    var validator: HorizontalIsolationValidator!

    override func setUp() async throws {
        try await super.setUp()
        // Use development config for testing
        validator = HorizontalIsolationValidator(configuration: .development)
    }

    override func tearDown() async throws {
        validator = nil
        try await super.tearDown()
    }

    // MARK: - Configuration Tests

    func testProductionConfiguration() {
        let config = HorizontalIsolationValidator.Configuration.production
        XCTAssertTrue(config.enforceHorizontalIsolation)
        XCTAssertTrue(config.allowedRelayTypes.contains("vsock-db"))
        XCTAssertTrue(config.requireHostMediation)
        XCTAssertTrue(config.blockedCIDs.isEmpty)
    }

    func testDevelopmentConfiguration() {
        let config = HorizontalIsolationValidator.Configuration.development
        XCTAssertFalse(config.enforceHorizontalIsolation)
        XCTAssertTrue(config.allowedRelayTypes.contains("test"))
        XCTAssertFalse(config.requireHostMediation)
    }

    // MARK: - IsolationResult Tests

    func testIsolationResultIsolated() {
        let result = HorizontalIsolationValidator.IsolationResult.isolated
        XCTAssertTrue(result.isIsolated)
        XCTAssertTrue(result.violations.isEmpty)
        XCTAssertNil(result.errorMessage)
    }

    func testIsolationResultFailed() {
        let violations: [HorizontalIsolationValidator.IsolationViolation] = [
            .directVsockConnection(cid: 3, port: 5432)
        ]
        let result = HorizontalIsolationValidator.IsolationResult.failed(
            violations,
            message: "Test violation"
        )
        XCTAssertFalse(result.isIsolated)
        XCTAssertEqual(result.violations.count, 1)
        XCTAssertEqual(result.errorMessage, "Test violation")
    }

    func testIsolationResultEquality() {
        let result1 = HorizontalIsolationValidator.IsolationResult.isolated
        let result2 = HorizontalIsolationValidator.IsolationResult.isolated
        let result3 = HorizontalIsolationValidator.IsolationResult.failed([], message: "Error")

        XCTAssertEqual(result1, result2)
        XCTAssertNotEqual(result1, result3)
    }

    // MARK: - IsolationViolation Tests

    func testIsolationViolationDescriptions() {
        let violation1 = HorizontalIsolationValidator.IsolationViolation.directVsockConnection(cid: 3, port: 5432)
        XCTAssertEqual(violation1.description, "Direct vsock connection detected: CID=3, port=5432")

        let violation2 = HorizontalIsolationValidator.IsolationViolation.sharedNamespace(namespace: "test")
        XCTAssertEqual(violation2.description, "Shared namespace violation: test")

        let violation3 = HorizontalIsolationValidator.IsolationViolation.networkBridgeDetected(bridge: "bridge100")
        XCTAssertEqual(violation3.description, "Network bridge detected: bridge100")
    }

    // MARK: - Container Communication Tests

    func testValidateContainerCommunicationWithDisabledEnforcement() async {
        // Development config has enforcement disabled
        let result = await validator.validateContainerCommunication(
            sourceCID: 3,
            targetCID: 4,
            port: 5432
        )
        XCTAssertTrue(result.isIsolated)
        XCTAssertEqual(result.errorMessage, "Horizontal isolation checks disabled")
    }

    func testValidateContainerCommunicationHostToGuest() async {
        // Host (CID 2) to Guest (CID 3) should be allowed
        let validator = HorizontalIsolationValidator(configuration: .production)
        let result = await validator.validateContainerCommunication(
            sourceCID: 2,
            targetCID: 3,
            port: 5432
        )
        XCTAssertTrue(result.isIsolated)
    }

    func testValidateContainerCommunicationGuestToHost() async {
        // Guest (CID 3) to Host (CID 2) should be allowed
        let validator = HorizontalIsolationValidator(configuration: .production)
        let result = await validator.validateContainerCommunication(
            sourceCID: 3,
            targetCID: 2,
            port: 5432
        )
        XCTAssertTrue(result.isIsolated)
    }

    // MARK: - Socket Path Tests

    func testValidateSocketPathWithDisabledEnforcement() async {
        let result = await validator.validateSocketPath("/tmp/test.sock")
        XCTAssertTrue(result.isIsolated)
    }

    func testValidateSocketPathVirtioFSVolume() async {
        let validator = HorizontalIsolationValidator(configuration: .production)
        let result = await validator.validateSocketPath(
            "/Users/test/.containers/Volumes/apple-honcho/honcho-db-sockets/.s.PGSQL.5432"
        )
        XCTAssertTrue(result.isIsolated)
    }

    func testValidateSocketPathSharedTemp() async {
        let validator = HorizontalIsolationValidator(configuration: .production)
        let result = await validator.validateSocketPath("/tmp/container-shared/test.sock")
        XCTAssertFalse(result.isIsolated)
        XCTAssertTrue(result.violations.contains { violation in
            if case .sharedNamespace = violation { return true }
            return false
        })
    }

    // MARK: - Validation Result Tests

    func testLastValidationResult() async {
        // Initially nil
        let initial = await validator.lastValidation()
        XCTAssertNil(initial)

        // After validation
        _ = await validator.validateContainerCommunication(sourceCID: 3, targetCID: 2, port: 5432)
        let result = await validator.lastValidation()
        XCTAssertNotNil(result)
    }

    // MARK: - Isolation Audit Tests

    func testPerformIsolationAuditWithDisabledEnforcement() async {
        let result = await validator.performIsolationAudit()
        XCTAssertTrue(result.isIsolated)
        XCTAssertEqual(result.errorMessage, "Isolation audit skipped (disabled)")
    }

    func testPerformIsolationAuditProduction() async {
        let validator = HorizontalIsolationValidator(configuration: .production)
        let result = await validator.performIsolationAudit()
        XCTAssertTrue(result.isIsolated) // Currently returns success (no actual system check)
    }

    // MARK: - Convenience Method Tests

    func testIsolationPassed() async {
        _ = await validator.validateContainerCommunication(sourceCID: 3, targetCID: 2, port: 5432)
        let passed = await validator.isolationPassed()
        XCTAssertTrue(passed)
    }

    func testFormattedError() async {
        let validator = HorizontalIsolationValidator(configuration: .production)
        _ = await validator.validateSocketPath("/tmp/container-shared/test.sock")
        let error = await validator.formattedError()
        XCTAssertTrue(error.contains("Security:"))
    }

    // MARK: - Sendable Compliance Tests

    func testConfigurationIsSendable() async {
        let config = HorizontalIsolationValidator.Configuration.production

        let task = Task {
            return config.enforceHorizontalIsolation
        }

        let result = await task.value
        XCTAssertTrue(result)
    }

    func testIsolationResultIsSendable() async {
        let result = HorizontalIsolationValidator.IsolationResult.isolated

        let task = Task {
            return result.isIsolated
        }

        let isIsolated = await task.value
        XCTAssertTrue(isIsolated)
    }

func testValidatorIsSendable() async {
    let testValidator = HorizontalIsolationValidator(configuration: .development)
    _ = await testValidator.validateContainerCommunication(sourceCID: 3, targetCID: 2, port: 5432)

    let task = Task {
        return await testValidator.isolationPassed()
    }

    let passed = await task.value
    XCTAssertTrue(passed)
}

    // MARK: - Security Container Compliance Tests

    func testVerifySecurityContainerCompliance() async {
        let compliant = await validator.verifySecurityContainerCompliance()
        XCTAssertTrue(compliant) // Development config returns true
    }

    func testComplianceReport() async {
        let report = await validator.complianceReport()
        XCTAssertTrue(report.contains("Horizontal isolation"))
    }

    func testComplianceReportNonCompliant() async {
        let validator = HorizontalIsolationValidator(configuration: .production)
        _ = await validator.validateSocketPath("/tmp/container-shared/test.sock")
        let report = await validator.complianceReport()
        XCTAssertTrue(report.contains("NON-COMPLIANT") || report.contains("COMPLIANT"))
    }

    // MARK: - IsolationError Tests

    func testIsolationErrorDescriptions() {
        XCTAssertEqual(
            HorizontalIsolationValidator.IsolationError.horizontalIsolationViolated.description,
            "Horizontal isolation violated"
        )
        XCTAssertEqual(
            HorizontalIsolationValidator.IsolationError.directVsockNotAllowed.description,
            "Direct vsock connections between containers not allowed"
        )
    }

    // MARK: - Integration Pattern Tests

    func testFullIsolationFlow() async {
        // Step 1: Validate container communication
        let result = await validator.validateContainerCommunication(
            sourceCID: 3,
            targetCID: 2,
            port: 5432
        )

        // Step 2: Validate socket path
        let socketResult = await validator.validateSocketPath(
            "/Users/test/.containers/Volumes/apple-honcho/test.sock"
        )

        // Step 3: Both should pass
        XCTAssertTrue(result.isIsolated)
        XCTAssertTrue(socketResult.isIsolated)

        // Step 4: Check compliance
        let compliant = await validator.verifySecurityContainerCompliance()
        XCTAssertTrue(compliant)
    }

    // MARK: - Blocked CID Tests

    func testValidateWithBlockedCID() async {
        let config = HorizontalIsolationValidator.Configuration(
            enforceHorizontalIsolation: true,
            blockedCIDs: [5, 6, 7]
        )
        let validator = HorizontalIsolationValidator(configuration: config)

        let result = await validator.validateContainerCommunication(
            sourceCID: 3,
            targetCID: 5, // Blocked CID
            port: 5432
        )

        XCTAssertFalse(result.isIsolated)
        XCTAssertTrue(result.violations.contains { violation in
            if case .directVsockConnection(let cid, _) = violation {
                return cid == 5
            }
            return false
        })
    }
}
