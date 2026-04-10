//===----------------------------------------------------------------------===//
// UDSRelayFunctionalityTests.swift
// Tests for UDS relay core functionality (Plan 88)
// Focus: socket creation, bridging, lifecycle, Virtio-FS integration
//===----------------------------------------------------------------------===//

import XCTest
import Foundation
@testable import ContainerComposeCore

@available(macOS 15.0, *)
final class UDSRelayFunctionalityTests: XCTestCase {

    func testSocketCreationInVirtioFsVolume() async throws {
        let testVolume = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".containers/Volumes/CCT_UDSTest_\(UUID().uuidString)")
        let socketPath = testVolume.appendingPathComponent("test.sock")

        defer { try? FileManager.default.removeItem(at: testVolume) }

        try FileManager.default.createDirectory(at: testVolume, withIntermediateDirectories: true)

        let eventLog = RelayEventLog()
        let relay = try UDSVirtioFSRelay(
            socketPath: socketPath.path,
            virtioFSMountPath: testVolume.path,
            createSignalSocket: true,
            eventLog: eventLog
        )

        let transport = await relay.transportType
        if case .uds(let path, _) = transport {
            XCTAssertEqual(path, socketPath.path, "Socket path should be stored in transport")
        } else {
            XCTFail("Transport should be UDS")
        }

        let storedPath = await relay.unixSocketPath
        XCTAssertEqual(storedPath, socketPath.path, "unixSocketPath should match")
    }

    func testVirtioFsPathDetection() async throws {
        let eventLog = RelayEventLog()

        let volumePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".containers/Volumes/CCT_DetectTest")

        let socketPath = volumePath.appendingPathComponent(".s.PGSQL.5432").path

        let relay = try UDSVirtioFSRelay(
            socketPath: socketPath,
            virtioFSMountPath: volumePath.path,
            createSignalSocket: false,
            eventLog: eventLog
        )

        let storedPath = await relay.unixSocketPath
        XCTAssertTrue(storedPath.contains(".containers/Volumes"), "Should detect Virtio-FS path")
    }

    func testRelayConfiguration() async throws {
        let eventLog = RelayEventLog()
        let socketPath = "/tmp/test.sock"

        let relay = try UDSVirtioFSRelay(
            socketPath: socketPath,
            createSignalSocket: true,
            eventLog: eventLog
        )

        let transport = await relay.transportType
        if case .uds(let path, _) = transport {
            XCTAssertEqual(path, socketPath, "Path should match")
        } else {
            XCTFail("Transport should be UDS")
        }
    }

    func testSocketPathPersistence() async throws {
        let socketPath = "/tmp/persistence-test.sock"

        let eventLog1 = RelayEventLog()
        let relay1 = try UDSVirtioFSRelay(
            socketPath: socketPath,
            createSignalSocket: true,
            eventLog: eventLog1
        )

        let transport1 = await relay1.transportType
        guard case .uds(let path1, _) = transport1 else {
            XCTFail("First relay should be UDS")
            return
        }

        let eventLog2 = RelayEventLog()
        let relay2 = try UDSVirtioFSRelay(
            socketPath: path1,
            createSignalSocket: true,
            eventLog: eventLog2
        )

        let transport2 = await relay2.transportType
        if case .uds(let path2, _) = transport2 {
            XCTAssertEqual(path2, path1, "Path should persist")
        } else {
            XCTFail("Second relay should preserve transport")
        }
    }

    func testSocketPathTooLong() {
        let longPath = String(repeating: "a", count: 110) + ".sock"
        XCTAssertThrowsError(try UDSVirtioFSRelay(
            socketPath: longPath,
            createSignalSocket: true,
            eventLog: RelayEventLog()
        )) { error in
            guard case UDSError.socketPathTooLong = error else {
                return XCTFail("Expected socketPathTooLong error, got: \(error)")
            }
        }
    }

    func testEmptySocketPath() async throws {
        let eventLog = RelayEventLog()

        let relay = try UDSVirtioFSRelay(
            socketPath: "",
            createSignalSocket: true,
            eventLog: eventLog
        )

        let path = await relay.unixSocketPath
        XCTAssertEqual(path, "", "Empty path should be preserved")
    }

    func testTransportDescription() {
        let transport1 = RelayTransport.uds(path: "/tmp/test.sock")
        XCTAssertTrue(transport1.description.contains("uds"), "Description should contain 'uds'")
    }
}
