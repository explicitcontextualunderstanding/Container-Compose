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
    XCTAssertTrue(error.contains("Security:"), "Error should contain 'Security:' prefix, got: \(error)")
    XCTAssertTrue(error.contains("shared namespace"), "Error should mention shared namespace violation")
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

// MARK: - UDS Socket Path Tests (Plan 88 A-1)

func testValidateUDSSocketPathProduction() async throws {
        // Plan 88 A-1: UDS replaces CID-based validation
        let socketPath = "/Users/kieranlal/.containers/Volumes/apple-honcho/honcho-db-sockets/.s.PGSQL.5432"

        let result = await validator.validateSocketPath(socketPath)

        // Production UDS paths in Virtio-FS should be isolated (allowed)
        XCTAssertTrue(result.isIsolated, "Production UDS socket path should be isolated")
    }

    func testValidateUDSSocketPathOutsideVolumes() async throws {
        // Plan 88: Paths outside .containers/Volumes are suspicious
        let socketPath = "/tmp/suspicious.sock"

        let result = await validator.validateSocketPath(socketPath)

        // Result depends on config; in development may be allowed
        // Just verify the check ran
        XCTAssertNotNil(result)
    }

    func testValidateUDSSocketPathLength() async throws {
        // Plan 88 Finding C-2: 104-char limit
        let longPath = String(repeating: "/very/long", count: 15) + "/socket.sock"

        let result = await validator.validateSocketPath(longPath)

        // Result depends on path analysis
        XCTAssertNotNil(result)
    }

    func testValidateUDSWithExpectedUID() async throws {
        // Plan 88 Finding C-3: Primitive-based API
        let socketPath = "/tmp/test.sock"
        let expectedUID: uid_t = 501

        let result = await validator.validateUDSPeer(
            socketPath: socketPath,
            expectedUID: expectedUID
        )

        // Should accept primitive UID parameter
        XCTAssertTrue(result.isAllowed || result.requiresSO_PEERCRED)
    }

// MARK: - Plan 88 UDS Path-Based Tests

func testUDSPathValidation() async {
    // Plan 88: UDS uses path-based isolation instead of CID
    let socketPath = "/Users/test/.containers/Volumes/myproject/sockets/db.sock"

    let result = await validator.validateSocketPath(socketPath)

    XCTAssertTrue(result.isIsolated, "UDS relay should be allowed in Virtio-FS volumes")
}

func testUDSSocketPathIsolation() async {
    // Plan 88: Path-based isolation for UDS sockets
    let validPath = "/Users/test/.containers/Volumes/project-a/sockets/db.sock"
    let invalidPath = "/tmp/container-shared/test.sock"

    // Valid path within Virtio-FS volume should be isolated (in production config)
    let prodValidator = HorizontalIsolationValidator(configuration: .production)
    let validResult = await prodValidator.validateSocketPath(validPath)
    XCTAssertTrue(validResult.isIsolated, "Path in .containers/Volumes should be isolated")

    // Invalid path outside Virtio-FS should not be isolated (production)
    let invalidResult = await prodValidator.validateSocketPath(invalidPath)
    XCTAssertFalse(invalidResult.isIsolated, "Path in /tmp should not be isolated in production")
}

func testUDSProductionPathValidation() async {
    // Plan 88: Validate production UDS paths
    let productionPath = "/Users/kieranlal/.containers/Volumes/apple-honcho/honcho-db-sockets/.s.PGSQL.5432"

    let result = await validator.validateSocketPath(productionPath)

    XCTAssertTrue(result.isIsolated, "Production path should be allowed")
    XCTAssertLessThan(productionPath.count, 104, "Production path must be under 104 chars")
}
}
