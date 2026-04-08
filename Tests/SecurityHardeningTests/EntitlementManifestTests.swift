// EntitlementManifestTests.swift
// Unit tests for Component 1: Entitlement Manifest Design
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import XCTest
@testable import SecurityHardening

@available(macOS 26.0, *)
final class EntitlementManifestTests: XCTestCase {

    // MARK: - Manifest Creation Tests

    func testStandardManifestHasCorrectPorts() {
        let manifest = EntitlementManifest.standard()

        XCTAssertTrue(manifest.hypervisor)
        XCTAssertTrue(manifest.isPortEntitled(5432))
        XCTAssertTrue(manifest.isPortEntitled(8000))
        XCTAssertEqual(manifest.entitledPorts.sorted(), [5432, 8000])
    }

    func testManifestFiltersOutFalsePorts() {
        let manifest = EntitlementManifest(
            hypervisor: true,
            vsockPorts: [
                5432: true,
                8000: false,
                9000: true
            ]
        )

        XCTAssertEqual(manifest.entitledPorts.sorted(), [5432, 9000])
        XCTAssertFalse(manifest.isPortEntitled(8000))
    }

    func testNoHypervisorNoPortEntitlement() {
        let manifest = EntitlementManifest(
            hypervisor: false,
            vsockPorts: [5432: true]
        )

        XCTAssertFalse(manifest.isPortEntitled(5432))
    }

    // MARK: - EntitlementValidator Tests

    func testValidatorAcceptsEntitledPort() throws {
        let manifest = EntitlementManifest.standard()
        let validator = EntitlementValidator()

        XCTAssertNoThrow(try validator.validatePort(5432, against: manifest))
    }

    func testValidatorRejectsNonEntitledPort() {
        let manifest = EntitlementManifest.standard()
        let validator = EntitlementValidator()

        XCTAssertThrowsError(try validator.validatePort(9999, against: manifest)) { error in
            XCTAssertEqual(error as? EntitlementError, .portNotEntitled(port: 9999))
        }
    }

    func testValidatorRejectsWithoutHypervisor() {
        let manifest = EntitlementManifest(hypervisor: false, vsockPorts: [5432: true])
        let validator = EntitlementValidator()

        XCTAssertThrowsError(try validator.validatePort(5432, against: manifest)) { error in
            XCTAssertEqual(error as? EntitlementError, .hypervisorNotEntitled)
        }
    }

    func testValidatorRejectsWildcard() {
        let manifest = EntitlementManifest(hypervisor: true, vsockPorts: [0: true])
        let validator = EntitlementValidator()

        XCTAssertThrowsError(try validator.validateNoWildcards(manifest)) { error in
            XCTAssertEqual(error as? EntitlementError, .wildcardNotAllowed)
        }
    }

    func testValidatorAcceptsNoWildcard() throws {
        let manifest = EntitlementManifest.standard()
        let validator = EntitlementValidator()

        XCTAssertNoThrow(try validator.validateNoWildcards(manifest))
    }

    func testValidatorRejectsInvalidPortRange() {
        let manifest = EntitlementManifest(hypervisor: true, vsockPorts: [0: true])
        let validator = EntitlementValidator()

        XCTAssertThrowsError(try validator.validatePort(0, against: manifest)) { error in
            XCTAssertEqual(error as? EntitlementError, .invalidPortRange(port: 0))
        }
    }

    // MARK: - InfoPlistEntitlements Tests

    func testInfoPlistReadsHypervisorEntitlement() {
        // Mock bundle with test entitlements
        let testDict: [String: Any] = [
            "com.apple.security.hypervisor": true,
            "com.apple.security.vsock.port.5432": true,
            "com.apple.security.vsock.port.8000": true
        ]

        let manifest = createManifestFromTestDict(testDict)

        XCTAssertTrue(manifest.hypervisor)
        XCTAssertTrue(manifest.isPortEntitled(5432))
        XCTAssertTrue(manifest.isPortEntitled(8000))
    }

    func testInfoPlistGeneratesValidXML() {
        let manifest = EntitlementManifest.standard()
        let reader = InfoPlistEntitlements()
        let xml = reader.generatePlistXML(for: manifest)

        XCTAssertTrue(xml.contains("com.apple.security.hypervisor"))
        XCTAssertTrue(xml.contains("<true/>"))
        XCTAssertTrue(xml.contains("com.apple.security.vsock.port.5432"))
        XCTAssertTrue(xml.contains("com.apple.security.vsock.port.8000"))
    }

    func testInfoPlistIgnoresInvalidPortKeys() {
        let testDict: [String: Any] = [
            "com.apple.security.hypervisor": true,
            "com.apple.security.vsock.port.abc": true,  // Invalid
            "com.apple.security.vsock.port.": true,      // Missing port number
            "com.apple.security.vsock.port.5432": true   // Valid
        ]

        let manifest = createManifestFromTestDict(testDict)

        XCTAssertEqual(manifest.entitledPorts, [5432])
    }

    // MARK: - Sendable Compliance Tests

    func testManifestIsSendable() async {
        let manifest = EntitlementManifest.standard()

        // Compile-time check: manifest can be captured in @Sendable closure
        let task = Task {
            return manifest.isPortEntitled(5432)
        }

        let result = await task.value
        XCTAssertTrue(result)
    }

    func testValidatorIsSendable() async {
        let validator = EntitlementValidator()
        let manifest = EntitlementManifest.standard()

        let task = Task {
            return (try? validator.validatePort(5432, against: manifest)) != nil
        }

        let result = await task.value
        XCTAssertTrue(result)
    }

    // MARK: - Strict Scoping Tests (SECURITY_CONTAINER.md requirement)

    func testStrictScopingRejectsWildcardPattern() {
        // SECURITY_CONTAINER.md: "Do not use wildcard entitlements for vSock ports"
        let wildcardManifest = EntitlementManifest(
            hypervisor: true,
            vsockPorts: [
                0: true  // Wildcard pattern (port 0 is reserved/invalid)
            ]
        )

        let validator = EntitlementValidator()

        XCTAssertThrowsError(try validator.validateNoWildcards(wildcardManifest))
    }

    func testStrictScopingRequiresExplicitPorts() throws {
        // SECURITY_CONTAINER.md: "Specify exact port IDs to minimize the blast radius"
        let manifest = EntitlementManifest(
            hypervisor: true,
            vsockPorts: [
                5432: true,  // Database
                8000: true   // Hub
            ]
        )

        let validator = EntitlementValidator()

        // Should pass - explicit ports only
        XCTAssertNoThrow(try validator.validateNoWildcards(manifest))

        // Verify only these specific ports are entitled
        XCTAssertTrue(manifest.isPortEntitled(5432))
        XCTAssertTrue(manifest.isPortEntitled(8000))
        XCTAssertFalse(manifest.isPortEntitled(5433))
        XCTAssertFalse(manifest.isPortEntitled(7999))
    }

    // MARK: - Helper Methods

    private func createManifestFromTestDict(_ dict: [String: Any]) -> EntitlementManifest {
        let hypervisor = dict["com.apple.security.hypervisor"] as? Bool ?? false
        var ports: [UInt32: Bool] = [:]

        for (key, value) in dict {
            if key.hasPrefix("com.apple.security.vsock.port."),
               let portStr = key.split(separator: ".").last,
               let port = UInt32(portStr),
               let enabled = value as? Bool {
                ports[port] = enabled
            }
        }

        return EntitlementManifest(hypervisor: hypervisor, vsockPorts: ports)
    }
}
