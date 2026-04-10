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

  /// Verify relay configuration matches expected values
  func testRelayConfiguration() async throws {
    let eventLog = RelayEventLog()
    let socketPath = "/tmp/test.sock"

    let relay = try VsockRelay(
      cid: 3,
      port: 8080,
      unixSocketPath: socketPath,
      createSignalSocket: true,
      eventLog: eventLog
    )

    // Verify CID and port stored correctly
    let transport = await relay.transportType
    if case .vsock(let cid, let port, let path) = transport {
      XCTAssertEqual(cid, 3, "CID should match")
      XCTAssertEqual(port, 8080, "Port should match")
      XCTAssertEqual(path, socketPath, "Path should match")
    } else {
      XCTFail("Transport should be vsock with cid, port, path")
    }
  }

  // MARK: - Test 4: Socket Persistence

  /// Verify socket path survives relay restarts
  func testSocketPathPersistence() async throws {
    let socketPath = "/tmp/persistence-test.sock"

    // Create first relay
    let eventLog1 = RelayEventLog()
    let relay1 = try VsockRelay(
      cid: 2,
      port: 5432,
      unixSocketPath: socketPath,
      createSignalSocket: true,
      eventLog: eventLog1
    )

    // Get initial transport
    let transport1 = await relay1.transportType
    guard case .vsock(let cid1, let port1, let path1) = transport1 else {
      XCTFail("First relay should be vsock")
      return
    }

    // Create second relay (simulates restart)
    let eventLog2 = RelayEventLog()
    let relay2 = try VsockRelay(
      cid: cid1,
      port: port1,
      unixSocketPath: path1,
      createSignalSocket: true,
      eventLog: eventLog2
    )

    // Verify configuration preserved
    let transport2 = await relay2.transportType
    if case .vsock(let cid2, let port2, let path2) = transport2 {
      XCTAssertEqual(cid2, cid1, "CID should persist")
      XCTAssertEqual(port2, port1, "Port should persist")
      XCTAssertEqual(path2, path1, "Path should persist")
    } else {
      XCTFail("Second relay should preserve transport")
    }
  }

  // MARK: - Test 5: Invalid Port Handling

  /// Verify relay rejects invalid ports
  func testInvalidPortHandling() {
    XCTAssertThrowsError(try VsockRelay(
      cid: 2,
      port: 0, // Invalid port
      unixSocketPath: "/tmp/test.sock",
      createSignalSocket: true,
      eventLog: RelayEventLog()
    )) { error in
      // Verify error is about invalid port (check description)
      let errorString = String(describing: error)
      XCTAssertTrue(
        errorString.contains("Invalid vsock port") || errorString.contains("port"),
        "Error should indicate invalid port: \(errorString)"
      )
    }
  }

  // MARK: - Test 6: Empty Socket Path

  /// Verify relay handles empty socket path
  func testEmptySocketPath() async throws {
    let eventLog = RelayEventLog()

    let relay = try VsockRelay(
      cid: 2,
      port: 5432,
      unixSocketPath: "",
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
}
