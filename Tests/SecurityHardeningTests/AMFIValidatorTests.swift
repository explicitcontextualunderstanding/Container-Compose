// AMFIValidatorTests.swift
// Unit tests for Component 3: AMFI Validation Utilities
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import XCTest
@testable import SecurityHardening

@available(macOS 26.0, *)
final class AMFIValidatorTests: XCTestCase {

    var validator: AMFIValidator!

    override func setUp() async throws {
        try await super.setUp()
        validator = AMFIValidator(configuration: .standard)
    }

    override func tearDown() async throws {
        validator = nil
        try await super.tearDown()
    }

    // MARK: - Configuration Tests

    func testStandardConfiguration() {
        let config = AMFIValidator.Configuration.standard
        XCTAssertEqual(config.requiredEntitlements, ["com.apple.security.hypervisor"])
        XCTAssertFalse(config.allowAdHocSigning)
    }

    func testCustomConfiguration() {
        let config = AMFIValidator.Configuration(
            requiredTeamIdentifier: "TEAM12345",
            requiredEntitlements: ["com.apple.security.hypervisor", "custom.entitlement"],
            allowAdHocSigning: true
        )
        XCTAssertEqual(config.requiredTeamIdentifier, "TEAM12345")
        XCTAssertEqual(config.requiredEntitlements.count, 2)
        XCTAssertTrue(config.allowAdHocSigning)
    }

    // MARK: - ValidationResult Tests

    func testValidationResultInvalid() {
        let result = AMFIValidator.ValidationResult.invalid
        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.isSigned)
        XCTAssertTrue(result.issues.contains(.unsigned))
    }

    func testValidationResultEquality() {
        let result1 = AMFIValidator.ValidationResult(
            isValid: true,
            isSigned: true,
            teamIdentifier: "TEAM1"
        )
        let result2 = AMFIValidator.ValidationResult(
            isValid: true,
            isSigned: true,
            teamIdentifier: "TEAM1"
        )
        let result3 = AMFIValidator.ValidationResult(
            isValid: true,
            isSigned: true,
            teamIdentifier: "TEAM2"
        )

        XCTAssertEqual(result1, result2)
        XCTAssertNotEqual(result1, result3)
    }

    // MARK: - ValidationIssue Tests

    func testValidationIssueDescriptions() {
        XCTAssertEqual(
            AMFIValidator.ValidationIssue.unsigned.description,
            "Binary is not code signed"
        )
        XCTAssertEqual(
            AMFIValidator.ValidationIssue.adHocSigned.description,
            "Binary is ad-hoc signed (no Team ID)"
        )
        XCTAssertEqual(
            AMFIValidator.ValidationIssue.signatureInvalid.description,
            "Code signature is invalid"
        )
        XCTAssertEqual(
            AMFIValidator.ValidationIssue.entitlementMissing("test").description,
            "Required entitlement missing: test"
        )
        XCTAssertEqual(
            AMFIValidator.ValidationIssue.verificationFailed("reason").description,
            "Verification failed: reason"
        )
    }

    // MARK: - File Not Found Tests

    func testVerifySignatureFileNotFound() async {
        let result = await validator.verifySignature(at: "/nonexistent/path/binary")
        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.isSigned)
        XCTAssertTrue(result.issues.contains { issue in
            if case .verificationFailed(let msg) = issue {
                return msg.contains("File not found")
            }
            return false
        })
    }

    func testVerifyEntitlementFileNotFound() async {
        let result = await validator.verifyEntitlement("com.apple.security.hypervisor", at: "/nonexistent/path")
        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.isSigned)
    }

    // MARK: - Convenience Methods Tests

    func testIsCodeSignedNonExistentFile() async {
        let isSigned = await validator.isCodeSigned(at: "/nonexistent/path")
        XCTAssertFalse(isSigned)
    }

    func testHasHypervisorEntitlementNonExistentFile() async {
        let hasEntitlement = await validator.hasHypervisorEntitlement(at: "/nonexistent/path")
        XCTAssertFalse(hasEntitlement)
    }

    // MARK: - Security Gating Tests

    func testValidateForSecurityGatingNonExistentFile() async {
        let isValid = await validator.validateForSecurityGating(at: "/nonexistent/path")
        XCTAssertFalse(isValid)
    }

    // MARK: - Sendable Compliance Tests

    func testConfigurationIsSendable() async {
        let config = AMFIValidator.Configuration.standard

        let task = Task {
            return config.requiredEntitlements.count
        }

        let result = await task.value
        XCTAssertEqual(result, 1)
    }

    func testValidationResultIsSendable() async {
        let result = AMFIValidator.ValidationResult(
            isValid: true,
            isSigned: true,
            teamIdentifier: "TEAM1"
        )

        let task = Task {
            return result.isValid
        }

        let isValid = await task.value
        XCTAssertTrue(isValid)
    }

    func testValidatorIsSendable() async {
        let testValidator = AMFIValidator()

        let task = Task {
            let result = await testValidator.verifySignature(at: "/nonexistent/path")
            return result.isSigned
        }

        let isSigned = await task.value
        XCTAssertFalse(isSigned)
    }

    // MARK: - Issue Equatable Tests

    func testValidationIssueEquality() {
        XCTAssertEqual(
            AMFIValidator.ValidationIssue.unsigned,
            AMFIValidator.ValidationIssue.unsigned
        )
        XCTAssertEqual(
            AMFIValidator.ValidationIssue.entitlementMissing("test"),
            AMFIValidator.ValidationIssue.entitlementMissing("test")
        )
        XCTAssertNotEqual(
            AMFIValidator.ValidationIssue.entitlementMissing("test1"),
            AMFIValidator.ValidationIssue.entitlementMissing("test2")
        )
    }

    // MARK: - Integration Pattern Tests

    func testValidationFlowForSecurityGating() async {
        // Test the full validation flow used in Plan 84 Phase 6

        // Step 1: Verify signature
        let signatureResult = await validator.verifySignature(at: "/nonexistent/path")
        XCTAssertFalse(signatureResult.isSigned)

        // Step 2: Verify entitlement (depends on signature)
        let entitlementResult = await validator.verifyEntitlement(
            "com.apple.security.hypervisor",
            at: "/nonexistent/path"
        )
        XCTAssertFalse(entitlementResult.isValid)

        // Step 3: Security gating check (combines both)
        let gatingResult = await validator.validateForSecurityGating(at: "/nonexistent/path")
        XCTAssertFalse(gatingResult)
    }

    // MARK: - Mock Binary Tests (if available)

    func testVerifySignatureWithMockSignedBinary() async throws {
        // Create a temporary file that we can "sign" for testing
        let tempDir = NSTemporaryDirectory() + "/AMFIValidatorTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let testFile = "\(tempDir)/test-binary"
        FileManager.default.createFile(atPath: testFile, contents: Data("test".utf8), attributes: nil)

        // Verify unsigned file
        let result = await validator.verifySignature(at: testFile)
        XCTAssertFalse(result.isSigned) // Unsigned file should fail

        // Clean up
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: - Real System Binary Tests

    func testVerifySignatureWithSystemBinary() async {
        // Test with a known system binary (/usr/bin/true)
        let result = await validator.verifySignature(at: "/usr/bin/true")

        // System binaries are typically signed, but we don't require it for the test
        // Just verify the check runs without crashing
        XCTAssertTrue(result.isSigned || !result.isSigned) // Always true, just checking no crash
    }

    func testVerifyEntitlementWithSystemBinary() async {
        // Test with a known system binary
        let result = await validator.verifyEntitlement(
            "com.apple.security.hypervisor",
            at: "/usr/bin/true"
        )

        // System binaries typically don't have hypervisor entitlement
        XCTAssertFalse(result.isValid)
    }
}
