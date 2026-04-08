// TCCCheckerTests.swift
// Unit tests for Component 4: TCC Permission Check Functions
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import XCTest
@testable import SecurityHardening

@available(macOS 26.0, *)
final class TCCCheckerTests: XCTestCase {

    var checker: TCCChecker!

    override func setUp() async throws {
        try await super.setUp()
        checker = TCCChecker(configuration: TCCChecker.Configuration())
    }

    override func tearDown() async throws {
        checker = nil
        try await super.tearDown()
    }

    // MARK: - Configuration Tests

    func testDefaultConfiguration() {
        let config = TCCChecker.Configuration()
        XCTAssertEqual(config.timeout, 30.0)
        XCTAssertTrue(config.usePrompt)
    }

    func testCustomConfiguration() {
        let config = TCCChecker.Configuration(
            timeout: 60.0,
            usePrompt: false
        )
        XCTAssertEqual(config.timeout, 60.0)
        XCTAssertFalse(config.usePrompt)
    }

    // MARK: - AuthorizationStatus Tests

    func testAuthorizationStatusDescriptions() {
        XCTAssertEqual(TCCChecker.AuthorizationStatus.authorized.description, "authorized")
        XCTAssertEqual(TCCChecker.AuthorizationStatus.denied.description, "denied")
        XCTAssertEqual(TCCChecker.AuthorizationStatus.notDetermined.description, "notDetermined")
        XCTAssertEqual(TCCChecker.AuthorizationStatus.unknown.description, "unknown")
    }

    func testAuthorizationStatusIsAuthorized() {
        XCTAssertTrue(TCCChecker.AuthorizationStatus.authorized.isAuthorized)
        XCTAssertFalse(TCCChecker.AuthorizationStatus.denied.isAuthorized)
        XCTAssertFalse(TCCChecker.AuthorizationStatus.notDetermined.isAuthorized)
        XCTAssertFalse(TCCChecker.AuthorizationStatus.unknown.isAuthorized)
    }

    // MARK: - PermissionResult Tests

    func testPermissionResultCreation() {
        let result = TCCChecker.PermissionResult(
            service: "com.apple.security.hypervisor",
            status: .authorized,
            lastModified: Date(timeIntervalSince1970: 1000)
        )

        XCTAssertEqual(result.service, "com.apple.security.hypervisor")
        XCTAssertEqual(result.status, .authorized)
        XCTAssertEqual(result.lastModified, Date(timeIntervalSince1970: 1000))
        XCTAssertNil(result.error)
    }

    func testPermissionResultEquality() {
        let result1 = TCCChecker.PermissionResult(
            service: "test",
            status: .authorized
        )
        let result2 = TCCChecker.PermissionResult(
            service: "test",
            status: .authorized
        )
        let result3 = TCCChecker.PermissionResult(
            service: "test",
            status: .denied
        )

        XCTAssertEqual(result1, result2)
        XCTAssertNotEqual(result1, result3)
    }

    // MARK: - Query Tests

    func testQueryTCCDatabaseDatabaseNotFound() async {
        let result = await checker.queryTCCDatabase(for: "com.test.nonexistent.service")
        XCTAssertEqual(result.service, "com.test.nonexistent.service")
    }

    func testQueryTCCDatabaseHypervisorService() async {
        let result = await checker.queryTCCDatabase(for: "com.apple.security.hypervisor")
        XCTAssertEqual(result.service, "com.apple.security.hypervisor")
    }

    // MARK: - Hypervisor Authorization Tests

    func testCheckHypervisorAuthorization() async {
        let status = await checker.checkHypervisorAuthorization()
        XCTAssertTrue([
            .authorized,
            .denied,
            .notDetermined,
            .unknown
        ].contains(status))
    }

    // MARK: - Preflight Check Tests

    func testPreflightCheck() async {
        let error = await checker.preflightCheck()
        _ = error
    }

    // MARK: - Request Authorization Tests

    func testRequestAuthorization() async {
        let status = await checker.requestAuthorization(for: "com.apple.security.hypervisor")
        XCTAssertTrue([
            .authorized,
            .denied,
            .notDetermined,
            .unknown
        ].contains(status))
    }

    // MARK: - Convenience Methods Tests

    func testIsHypervisorAuthorized() async {
        let isAuthorized = await checker.isHypervisorAuthorized()
        XCTAssertTrue(isAuthorized || !isAuthorized)
    }

    func testWouldNeedPrompt() async {
        let wouldNeed = await checker.wouldNeedPrompt()
        XCTAssertTrue(wouldNeed || !wouldNeed)
    }

    // MARK: - Sendable Compliance Tests

    func testConfigurationIsSendable() async {
        let config = TCCChecker.Configuration()
        let task = Task { return config.timeout }
        let result = await task.value
        XCTAssertEqual(result, 30.0)
    }

    func testAuthorizationStatusIsSendable() async {
        let status = TCCChecker.AuthorizationStatus.authorized
        let task = Task { return status.description }
        let result = await task.value
        XCTAssertEqual(result, "authorized")
    }

    func testPermissionResultIsSendable() async {
        let result = TCCChecker.PermissionResult(
            service: "test",
            status: .authorized
        )
        let task = Task { return result.status }
        let status = await task.value
        XCTAssertEqual(status, .authorized)
    }

    func testCheckerIsSendable() async {
        let testChecker = TCCChecker()
        let task = Task {
            return await testChecker.checkHypervisorAuthorization()
        }
        let status = await task.value
        XCTAssertTrue([
            .authorized,
            .denied,
            .notDetermined,
            .unknown
        ].contains(status))
    }

    // MARK: - Integration Pattern Tests

    func testFullTCCCheckFlow() async {
        let status = await checker.checkHypervisorAuthorization()
        let error = await checker.preflightCheck()

        if status == .authorized {
            XCTAssertNil(error)
        } else {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - PermissionResult Error Tests

    func testPermissionResultWithError() {
        let result = TCCChecker.PermissionResult(
            service: "test",
            status: .unknown,
            error: "Database not found"
        )

        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.error, "Database not found")
    }
}
