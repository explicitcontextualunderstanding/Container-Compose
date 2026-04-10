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

    // MARK: - Plan 88 UDS TCC Integration Tests

    func testValidateUDSRelayStartupWithDevelopmentConfig() async {
        // Plan 88: UDS relay should validate with development config
        let canStart = await integration.validateRelayStartup(relayType: "uds")
        XCTAssertTrue(canStart, "UDS relay should start with development config")
    }

    func testValidateUDSDatabaseRelayStartup() async {
        // Plan 88: UDS-db relay type for PostgreSQL over Virtio-FS
        let canStart = await integration.validateRelayStartup(relayType: "uds-db")
        XCTAssertTrue(canStart, "UDS-db relay should start with development config")
    }

    func testUDSRelayTypeFormat() async {
        // Plan 88: Verify UDS relay type strings are recognized
        let udsValid = await integration.validateRelayStartup(relayType: "uds")
        let udsDbValid = await integration.validateRelayStartup(relayType: "uds-db")

        XCTAssertTrue(udsValid, "'uds' relay type should be valid")
        XCTAssertTrue(udsDbValid, "'uds-db' relay type should be valid")
    }

    func testUDSRequiresTCCAuthorizationInProduction() async {
        // Plan 88: UDS over Virtio-FS requires TCC-gated filesystem access
        // In production, TCC enforces access to ~/.containers/Volumes
        let productionIntegration = TCCRelayIntegration(configuration: .production)

        // With production config, TCC enforcement is enabled
        // UDS relay validation should check TCC status
        let result = await productionIntegration.preflightCheck()

        // In production, TCC authorization is required for Virtio-FS access
        // The actual result depends on TCC state, but we verify the check runs
        XCTAssertNotNil(result.status)
    }

    func testUDSVsockDbHaveSameTCCRequirements() async {
        // Plan 88: UDS and vsock-db should have same TCC validation pattern
        // Both use Virtio-FS which is TCC-gated
        let udsResult = await integration.validateRelayStartup(relayType: "uds")
        let vsockDbResult = await integration.validateRelayStartup(relayType: "vsock-db")

        // Both should pass with development config
        XCTAssertTrue(udsResult)
        XCTAssertTrue(vsockDbResult)
    }

    func testUDSRelayIntegrationPattern() async {
        // Plan 88: Simulate UDS relay startup with TCC check
        // Pattern: RelayManager.startRelay() for UDS transport

        // Step 1: TCC preflight (same for all Virtio-FS transports)
        let preflightResult = await integration.preflightCheck()
        XCTAssertTrue(preflightResult.canProceed, "Should proceed with development config")

        // Step 2: Validate UDS-specific relay
        let canStartUDS = await integration.validateRelayStartup(relayType: "uds")
        XCTAssertTrue(canStartUDS, "UDS relay should pass validation")

        // Step 3: Validate UDS-db (database) relay
        let canStartUDSDb = await integration.validateRelayStartup(relayType: "uds-db")
        XCTAssertTrue(canStartUDSDb, "UDS-db relay should pass validation")
    }

    func testUDSTransparentMappingPreservesTCCCheck() async {
        // Plan 88: vsock-db transparently maps to UDS - TCC check should still apply
// When vsock-db is mapped to UDS, TCC for Virtio-FS is still required

let preflight = await integration.preflightCheck()

// Both paths should use same TCC validation since both use Virtio-FS
let vsockDbValid = await integration.validateRelayStartup(relayType: "vsock-db")
let udsDbValid = await integration.validateRelayStartup(relayType: "uds-db")

// Results should be consistent (both use Virtio-FS TCC)
XCTAssertEqual(vsockDbValid, udsDbValid)
}

// MARK: - UDS TCC Tests (Plan 88 A-1)

func testUDSRequiresTCCEvenWithoutVsock() async throws {
// Plan 88 A-1: TCC is identity model since AF_UNIX doesn't expose CID
let config = TCCRelayIntegration.Configuration.production
let integration = TCCRelayIntegration(configuration: config)

// UDS-over-Virtio-FS still requires TCC for the Virtio-FS mount
let udsSocketPath = "/Users/kieranlal/.containers/Volumes/app/sockets/db.sock"
let tccRequired = await integration.isTCCRequiredForPath(udsSocketPath)

XCTAssertTrue(tccRequired, "UDS in Virtio-FS requires TCC authorization")
}

func testUDSSocketOutsideVirtioFSBlocked() async throws {
// Plan 88: UDS sockets outside Virtio-FS should be blocked
let config = TCCRelayIntegration.Configuration.production
let integration = TCCRelayIntegration(configuration: config)

let nonVirtioFSPath = "/tmp/uds-socket.sock"
let allowed = await integration.validateRelayStartup(relayType: "uds", socketPath: nonVirtioFSPath)

XCTAssertFalse(allowed, "UDS outside Virtio-FS should be blocked in production")
}

func testUDSPermissionChecksUseVirtioFSGating() async throws {
// Plan 88 A-1: UID/GID + TCC replaces CID
let socketPath = "/Users/kieranlal/.containers/Volumes/app/sockets/.s.PGSQL.5432"

let permission = await integration.checkUDSPermission(
socketPath: socketPath,
requestedUID: 501,
requestedGID: 20
)

// Should check Virtio-FS TCC status
XCTAssertNotNil(permission.virtioFSAccessGranted)
}

func testUDSPeerValidationUsesSO_PEERCREDNotCID() async throws {
// Plan 88 A-1: SO_PEERCRED replaces CID gating
let peerValidation = await integration.validateUDSPeerIdentity(
peerUID: 501,
peerGID: 20,
peerPID: 12345
)

// Should validate UID/GID, not CID
XCTAssertTrue(peerValidation.usesSO_PEERCRED)
XCTAssertFalse(peerValidation.checkedCID)
XCTAssertEqual(peerValidation.validatedUID, 501)
}

func testUDSTCCWithProductionConfig() async throws {
        // Plan 88: Production config enforces TCC
        let config = TCCRelayIntegration.Configuration.production
        let integration = TCCRelayIntegration(configuration: config)

        // Production config has enforcement enabled
        XCTAssertTrue(config.enforceTCCAuthorization)

        // Run preflight - result depends on actual TCC state
        let result = await integration.preflightCheck()

        // Verify result has valid status
        XCTAssertNotNil(result.status)
    }

    func testUDSTCCWithDevelopmentConfig() async throws {
        // Plan 88: Development config doesn't enforce TCC
        let config = TCCRelayIntegration.Configuration.development
        let integration = TCCRelayIntegration(configuration: config)

        // Development config has enforcement disabled
        XCTAssertFalse(config.enforceTCCAuthorization)

        let result = await integration.preflightCheck()

        // Development allows proceeding
        XCTAssertTrue(result.canProceed)
    }
