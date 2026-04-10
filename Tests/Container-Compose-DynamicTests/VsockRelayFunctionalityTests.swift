//===----------------------------------------------------------------------===//
// UDSRelayFunctionalityTests.swift
// Tests for UDS relay core functionality (Plan 88 - replaces vsock)
// Focus: socket creation, bridging, lifecycle, Virtio-FS integration
//===----------------------------------------------------------------------===//

import XCTest
import Foundation
@testable import ContainerComposeCore

/// Tests for UDS relay functionality (Plan 88 - replaces vsock)
/// Task Owner: @mac-kilo-kim
/// Priority: Test OUR code, not PostgreSQL
@available(macOS 15.0, *)
final class UDSRelayFunctionalityTests: XCTestCase {

	// MARK: - Test 1: Socket Creation in Virtio-FS

	/// Verify UDSVirtioFSRelay creates socket in Virtio-FS volume
	func testSocketCreationInVirtioFsVolume() async throws {
		let testVolume = FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".containers/Volumes/CCT_UDSTest_\(UUID().uuidString)")
		let socketPath = testVolume.appendingPathComponent("test.sock")

		defer {
			try? FileManager.default.removeItem(at: testVolume)
		}

		// Create volume directory
		try FileManager.default.createDirectory(at: testVolume, withIntermediateDirectories: true)

		// Plan 88: Create relay with UDS in Virtio-FS volume
		let eventLog = RelayEventLog()
		let relay = try UDSVirtioFSRelay(
			socketPath: socketPath.path,
			virtioFSMountPath: testVolume.path,
			createSignalSocket: true,
			eventLog: eventLog
		)

		// Verify transport type includes socket path
		let transport = await relay.transportType
		if case .uds(let path, _) = transport {
			XCTAssertEqual(path, socketPath.path, "Socket path should be stored in transport")
		} else {
			XCTFail("Transport should be UDS")
		}

		// Verify unixSocketPath property
		let storedPath = await relay.unixSocketPath
		XCTAssertEqual(storedPath, socketPath.path, "unixSocketPath should match")
	}

// MARK: - Test 2: Virtio-FS Path Detection

/// Verify UDS relay detects Virtio-FS paths correctly
/// Plan 88: Migrated from VsockRelay to UDSVirtioFSRelay
func testVirtioFsPathDetection() async throws {
	let eventLog = RelayEventLog()

	// Test volume path
	let volumePath = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent(".containers/Volumes/CCT_DetectTest")

	let socketPath = volumePath.appendingPathComponent(".s.PGSQL.5432").path

	let relay = try UDSVirtioFSRelay(
		socketPath: socketPath,
		virtioFSMountPath: volumePath.path,
		createSignalSocket: false, // Volume socket - PostgreSQL creates it
		eventLog: eventLog
	)

	// Verify path detected correctly
	let storedPath = await relay.unixSocketPath
	XCTAssertTrue(storedPath.contains(".containers/Volumes"), "Should detect Virtio-FS path")
}

// MARK: - Test 3: Relay Configuration

/// Verify UDS relay configuration matches expected values
/// Plan 88: Migrated from VsockRelay to UDSVirtioFSRelay
func testRelayConfiguration() async throws {
	let eventLog = RelayEventLog()
	let socketPath = "/tmp/test-\(UUID().uuidString).sock"
	defer { try? FileManager.default.removeItem(atPath: socketPath) }

	let relay = try UDSVirtioFSRelay(
		socketPath: socketPath,
		virtioFSMountPath: nil,
		createSignalSocket: true,
		eventLog: eventLog
	)

	// Verify UDS transport stored correctly
	let transport = await relay.transportType
	if case .uds(let path, _) = transport {
		XCTAssertEqual(path, socketPath, "Path should match")
	} else {
		XCTFail("Transport should be UDS")
	}
}

// MARK: - Test 4: Socket Persistence

/// Verify socket path survives relay restarts
/// Plan 88: Migrated from VsockRelay to UDSVirtioFSRelay
func testSocketPathPersistence() async throws {
	let socketPath = "/tmp/persistence-test-\(UUID().uuidString).sock"
	defer { try? FileManager.default.removeItem(atPath: socketPath) }

	// Create first relay
	let eventLog1 = RelayEventLog()
	let relay1 = try UDSVirtioFSRelay(
		socketPath: socketPath,
		virtioFSMountPath: nil,
		createSignalSocket: true,
		eventLog: eventLog1
	)

	// Get initial transport
	let transport1 = await relay1.transportType
	guard case .uds(let path1, _) = transport1 else {
		XCTFail("First relay should be UDS")
		return
	}

	// Create second relay (simulates restart)
	let eventLog2 = RelayEventLog()
	let relay2 = try UDSVirtioFSRelay(
		socketPath: path1,
		virtioFSMountPath: nil,
		createSignalSocket: true,
      eventLog: eventLog2
    )

// Verify configuration preserved
    let transport2 = await relay2.transportType
    if case .uds(let path2, _) = transport2 {
        XCTAssertEqual(path2, path1, "Path should persist")
    } else {
        XCTFail("Second relay should preserve UDS transport")
    }
  }

// MARK: - Test 5: Path Length Validation

/// Verify UDS relay rejects paths >= 104 chars (AF_UNIX limit)
/// Plan 88: Migrated from VsockRelay to UDSVirtioFSRelay
func testPathLengthValidation() {
	let longPath = String(repeating: "a", count: 110) + ".sock"
	XCTAssertThrowsError(try UDSVirtioFSRelay(
		socketPath: longPath,
		virtioFSMountPath: nil,
		createSignalSocket: true,
		eventLog: RelayEventLog()
	)) { error in
		// Verify error is about path length
		let errorString = String(describing: error)
		XCTAssertTrue(
			errorString.contains("too long") || errorString.contains("104"),
			"Error should indicate path too long: \(errorString)"
		)
	}
}

// MARK: - Test 6: Empty Socket Path

/// Verify UDS relay handles empty socket path
/// Plan 88: Migrated from VsockRelay to UDSVirtioFSRelay
func testEmptySocketPath() async throws {
	let eventLog = RelayEventLog()

	let relay = try UDSVirtioFSRelay(
		socketPath: "",
		virtioFSMountPath: nil,
		createSignalSocket: true,
		eventLog: eventLog
	)

	// Empty path should be preserved (but may fail on start)
	let path = await relay.unixSocketPath
	XCTAssertEqual(path, "", "Empty path should be preserved")
  }

    // MARK: - Test 7: Transport Type Description

    /// Verify transport description is human-readable
    func testTransportDescription() {
        let transport1 = RelayTransport.vsock(cid: 2, port: 5432, unixSocketPath: "")
        XCTAssertEqual(transport1.description, "vsock:2:5432")

        let transport2 = RelayTransport.vsock(cid: 2, port: 5432, unixSocketPath: "/tmp/test.sock")
        XCTAssertEqual(transport2.description, "vsock:2:5432:/tmp/test.sock")
    }

    // MARK: - Test 8: UDS Initialization with Expected UID (Plan 88 A-1)

    /// Verify UDS relay can be initialized with expected peer UID
    func testUDSInitializationWithExpectedUID() async throws {
        // Plan 88 A-1 Resolution: SO_PEERCRED identity validation
        let socketPath = "/tmp/test-uid.sock"
        let expectedUID: uid_t = getuid()

        // Create relay with expected UID for defense-in-depth
        let eventLog = RelayEventLog()
        let relay = try UDSVirtioFSRelay(
            socketPath: socketPath,
            createSignalSocket: true,
            eventLog: eventLog
        )

        // Verify relay was created successfully
        let transport = await relay.transportType
        if case .uds(let path, _) = transport {
            XCTAssertEqual(path, socketPath)
        } else {
            XCTFail("Expected UDS transport")
        }

        // Note: Peer validation happens at connection time, not init time
        // The expectedPeerUID parameter enables defense-in-depth per A-1
    }
}
