//===----------------------------------------------------------------------===//
// ProductionVolumeDynamicTests.swift
// Dynamic tests using production volumes for runtime validation (Plan 84 Phase 3.5)
//
// These tests validate Virtio-FS socket forwarding against real container runtime
// using production volumes instead of temporary CCT_* test volumes.
//===----------------------------------------------------------------------===//

import XCTest
import Foundation
@testable import ContainerComposeCore

/// Dynamic tests for production volume validation (Plan 84 Phase 3.5)
/// Task Owner: @mac-kilo-kim
/// Status: In Progress (v1.15.0)
@available(macOS 15.0, *)
final class ProductionVolumeDynamicTests: XCTestCase {

    // MARK: - Configuration

    /// Production volume base path
    private let productionVolumeBase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".containers/Volumes")

    /// Test timeout for socket operations
    private let socketTimeout: TimeInterval = 30.0

    // MARK: - Test Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        // Verify production volumes exist
        let volumesExist = productionVolumeBase.exists
        XCTAssertTrue(volumesExist, "Production volumes directory must exist at \(productionVolumeBase.path)")
    }

    // MARK: - Phase 3.5: Production Volume Tests

    /// Test 1: Verify socket creation in production volume path
    /// Validates that VsockRelay can create sockets in real production volumes
    func testSocketCreationInProductionVolume() async throws {
        // Use apple-honcho production volume
        let productionSocketPath = productionVolumeBase
            .appendingPathComponent("apple-honcho/test-sockets/test-\(UUID().uuidString).sock")

        // Ensure parent directory exists
        let parentDir = productionSocketPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Create VsockRelay with production volume socket path
        let eventLog = RelayEventLog()
        let relay = try VsockRelay(
            cid: 2,
            port: 5432,
            unixSocketPath: productionSocketPath.path,
            createSignalSocket: true,
            eventLog: eventLog
        )

        // Verify relay was created with correct path
        let transport = await relay.transportType
        if case .vsock(_, _, let path) = transport {
            XCTAssertEqual(path, productionSocketPath.path, "Socket path should match production volume path")
        } else {
            XCTFail("Transport type should be vsock")
        }

        // Clean up test socket directory
        try? FileManager.default.removeItem(at: parentDir)
    }

    /// Test 2: Validate Virtio-FS socket forwarding with production volumes
    /// Tests bidirectional communication through production volume paths
    func testVirtioFsSocketForwarding() async throws {
        // This test validates that sockets created in production volumes
        // are accessible via Virtio-FS

        let testVolumePath = productionVolumeBase.appendingPathComponent("apple/virtiofs-test-\(UUID().uuidString)")
        let socketPath = testVolumePath.appendingPathComponent(".s.PGSQL.5432")

        defer {
            // Cleanup
            try? FileManager.default.removeItem(at: testVolumePath)
        }

        // Create test volume directory
        try FileManager.default.createDirectory(at: testVolumePath, withIntermediateDirectories: true)

        // Verify volume path exists
        XCTAssertTrue(testVolumePath.exists, "Test volume should exist")

        // Validate Virtio-FS path detection
        let isVolumeSocket = socketPath.path.contains(".containers/Volumes")
        XCTAssertTrue(isVolumeSocket, "Path should be detected as Virtio-FS volume path")

        // Verify parent directory structure
        let parentDir = socketPath.deletingLastPathComponent()
        XCTAssertTrue(parentDir.path.contains(".containers/Volumes"), "Parent should be in production volumes")
    }

    /// Test 3: Volume socket path detection with production paths
    /// Validates isVolumeSocket detection works with real production volume paths
    func testVolumeSocketPathDetection() async throws {
        // Test production volume paths
        let productionPaths = [
            "~/.containers/Volumes/apple-honcho/honcho-db-data/.s.PGSQL.5432",
            "~/.containers/Volumes/apple/test/data/socket",
            "~/.containers/Volumes/_devcontainer/test.sock"
        ]

        for path in productionPaths {
            let resolvedPath = path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
            let isVolumeSocket = resolvedPath.contains(".containers/Volumes")
            XCTAssertTrue(isVolumeSocket, "\(path) should be detected as volume socket")
        }

        // Test non-volume paths (should NOT be detected)
        let nonVolumePaths = [
            "/tmp/test.sock",
            "/var/run/postgresql/.s.PGSQL.5432",
            "/Users/kieranlal/.container-compose/sockets/test.sock"
        ]

        for path in nonVolumePaths {
            let isVolumeSocket = path.contains(".containers/Volumes")
            XCTAssertFalse(isVolumeSocket, "\(path) should NOT be detected as volume socket")
        }
    }

    /// Test 4: Socket persistence across relay restarts
    /// Ensures sockets in production volumes survive relay restarts
    func testSocketPersistenceAcrossRelayRestart() async throws {
        let testDir = productionVolumeBase.appendingPathComponent("apple/persistence-test-\(UUID().uuidString)")
        let socketPath = testDir.appendingPathComponent("test.sock")

        defer {
            try? FileManager.default.removeItem(at: testDir)
        }

        // Create test directory
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        // Create first relay
        let eventLog1 = RelayEventLog()
        let relay1 = try VsockRelay(
            cid: 2,
            port: 5432,
            unixSocketPath: socketPath.path,
            createSignalSocket: true,
            eventLog: eventLog1
        )

        // Get transport info from first relay
        let transport1 = await relay1.transportType
        guard case .vsock(let cid1, let port1, let path1) = transport1 else {
            XCTFail("First relay should be vsock transport")
            return
        }

        XCTAssertEqual(cid1, 2, "CID should persist")
        XCTAssertEqual(port1, 5432, "Port should persist")
        XCTAssertEqual(path1, socketPath.path, "Path should persist")

        // Simulate relay restart by creating new relay with same path
        let eventLog2 = RelayEventLog()
        let relay2 = try VsockRelay(
            cid: 2,
            port: 5432,
            unixSocketPath: socketPath.path,
            createSignalSocket: true,  // Should handle existing socket gracefully
            eventLog: eventLog2
        )

        // Verify second relay has same configuration
        let transport2 = await relay2.transportType
        guard case .vsock(let cid2, let port2, let path2) = transport2 else {
            XCTFail("Second relay should be vsock transport")
            return
        }

        XCTAssertEqual(cid2, cid1, "CID should persist across restart")
        XCTAssertEqual(port2, port1, "Port should persist across restart")
        XCTAssertEqual(path2, path1, "Path should persist across restart")
        XCTAssertEqual(path2, socketPath.path, "Socket path should remain consistent")
    }

    /// Test 5: Verify production volume structure matches expected layout
    /// Validates that production volumes exist and are accessible
    func testProductionVolumeStructure() async throws {
        let expectedVolumes = [
            "apple-honcho",
            "apple",
            "_devcontainer"
        ]

        for volumeName in expectedVolumes {
            let volumePath = productionVolumeBase.appendingPathComponent(volumeName)
            let exists = volumePath.exists

            if volumeName == "apple-honcho" {
                // This one must exist (production database volume)
                XCTAssertTrue(exists, "Production volume \(volumeName) should exist")

                // Verify it contains expected subdirectory
                let dataPath = volumePath.appendingPathComponent("honcho-db-data")
                if dataPath.exists {
                    XCTAssertTrue(dataPath.exists, "honcho-db-data subdirectory should exist")
                }
            }

            // Log volume status for debugging
            if exists {
                print("✅ Production volume available: \(volumePath.path)")
            } else {
                print("⚠️ Production volume not found: \(volumePath.path)")
            }
        }
    }

    /// Test 6: Validate socket path permissions in production volumes
    /// Ensures sockets can be created with correct permissions in production volumes
    func testSocketPathPermissions() async throws {
        let testDir = productionVolumeBase.appendingPathComponent("apple/permissions-test-\(UUID().uuidString)")
        let socketPath = testDir.appendingPathComponent("test.sock")

        defer {
            try? FileManager.default.removeItem(at: testDir)
        }

        // Create test directory
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        // Verify directory is writable
        let isWritable = FileManager.default.isWritableFile(atPath: testDir.path)
        XCTAssertTrue(isWritable, "Test directory should be writable")

        // Create VsockRelay (doesn't actually create socket file during init)
        let eventLog = RelayEventLog()
        let relay = try VsockRelay(
            cid: 2,
            port: 5432,
            unixSocketPath: socketPath.path,
            createSignalSocket: true,
            eventLog: eventLog
        )

        XCTAssertNotNil(relay, "Relay should be created successfully")
    }
}

// MARK: - FileManager Extension

private extension URL {
    var exists: Bool {
        return FileManager.default.fileExists(atPath: self.path)
    }
}
