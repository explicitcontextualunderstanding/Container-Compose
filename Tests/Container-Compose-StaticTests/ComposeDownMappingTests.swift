//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import XCTest
@testable import ContainerComposeCore
import Foundation

final class ComposeDownMappingTests: XCTestCase {

    // MARK: - DownResult Data Model

    func testDownResultAllClean() throws {
        let result = ComposeDown.DownResult(
            stopped: ["svc-a", "svc-b"],
            timeouts: [],
            errors: []
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.isSuccess)
    }

    func testDownResultWithTimeouts() throws {
        let result = ComposeDown.DownResult(
            stopped: ["svc-a"],
            timeouts: ["svc-b"],
            errors: []
        )
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.isSuccess)
    }

    func testDownResultWithErrors() throws {
        let result = ComposeDown.DownResult(
            stopped: ["svc-a"],
            timeouts: [],
            errors: ["svc-b"]
        )
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertFalse(result.isSuccess)
    }

    func testDownResultTimeoutsAndErrorsTakesWorst() throws {
        let result = ComposeDown.DownResult(
            stopped: ["svc-a"],
            timeouts: ["svc-b"],
            errors: ["svc-c"]
        )
        // errors (exit 2) is worse than timeouts (exit 1)
        XCTAssertEqual(result.exitCode, 2)
    }

    // MARK: - ContainerState File (Idempotent Teardown)

    func testStateFileRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCT_StateFile_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let stateFile = tmpDir.appendingPathComponent(".container-compose.state")
        let containers = ["proj-svc-a", "proj-svc-b", "proj-svc-c"]

        // Write state
        ComposeDown.writeStateFile(stateFile, containerNames: containers)

        // Read state
        let readBack = ComposeDown.readStateFile(stateFile)
        XCTAssertEqual(readBack.containers, containers)
    }

    func testStateFileMissingReturnsEmpty() throws {
        let stateFile = URL(fileURLWithPath: "/tmp/CCT_nonexistent_\(UUID().uuidString).state")
        let result = ComposeDown.readStateFile(stateFile)
        XCTAssertTrue(result.containers.isEmpty)
    }

    func testStateFileOverwrite() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCT_StateFile_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let stateFile = tmpDir.appendingPathComponent(".container-compose.state")

        ComposeDown.writeStateFile(stateFile, containerNames: ["a", "b"])
        ComposeDown.writeStateFile(stateFile, containerNames: ["c", "d"])

        let readBack = ComposeDown.readStateFile(stateFile)
        XCTAssertEqual(readBack.containers, ["c", "d"])
    }

    func testRemoveStateFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCT_StateFile_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let stateFile = tmpDir.appendingPathComponent(".container-compose.state")
        ComposeDown.writeStateFile(stateFile, containerNames: ["a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path))

        ComposeDown.removeStateFile(stateFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path))
    }

    func testRemoveStateFileNonexistentIsNoop() throws {
        let stateFile = URL(fileURLWithPath: "/tmp/CCT_nonexistent_\(UUID().uuidString).state")
        // Should not throw
        ComposeDown.removeStateFile(stateFile)
    }

    // MARK: - State File Path Derivation

    func testStateFilePathFromCWD() throws {
        let path = ComposeDown.stateFilePath(cwd: "/tmp/myproject")
        XCTAssertEqual(path.lastPathComponent, ".container-compose.state")
        XCTAssertTrue(path.path.contains("/tmp/myproject"))
    }

    // MARK: - Timeout Flag Parsing

    func testComposeDownTimeoutDefault() throws {
        let cmd = try ComposeDown.parse([])
        XCTAssertEqual(cmd.timeoutSeconds, 30)
    }

    func testComposeDownTimeoutCustom() throws {
        let cmd = try ComposeDown.parse(["--timeout-seconds", "60"])
        XCTAssertEqual(cmd.timeoutSeconds, 60)
    }

    func testComposeDownTimeoutShort() throws {
        let cmd = try ComposeDown.parse(["--timeout-seconds", "5"])
        XCTAssertEqual(cmd.timeoutSeconds, 5)
    }

    func testComposeDownConfiguration() throws {
        XCTAssertEqual(ComposeDown.configuration.commandName, "down")
        XCTAssertTrue(ComposeDown.configuration.abstract.contains("Stop"))
    }

    // MARK: - DownResult Summary Formatting

    func testDownResultSummaryAllClean() throws {
        let result = ComposeDown.DownResult(
            stopped: ["a", "b", "c"],
            timeouts: [],
            errors: []
        )
        let summary = result.summary
        XCTAssertTrue(summary.contains("3 stopped"))
        XCTAssertFalse(summary.contains("timeout"))
        XCTAssertFalse(summary.contains("error"))
    }

    func testDownResultSummaryWithTimeouts() throws {
        let result = ComposeDown.DownResult(
            stopped: ["a"],
            timeouts: ["b"],
            errors: []
        )
        let summary = result.summary
        XCTAssertTrue(summary.contains("1 stopped"))
        XCTAssertTrue(summary.contains("1 timeout"))
    }

    func testDownResultSummaryWithErrors() throws {
        let result = ComposeDown.DownResult(
            stopped: ["a"],
            timeouts: [],
            errors: ["b"]
        )
        let summary = result.summary
        XCTAssertTrue(summary.contains("1 error"))
    }

    func testDownResultSummaryEmpty() throws {
        let result = ComposeDown.DownResult(
            stopped: [],
            timeouts: [],
            errors: []
        )
        let summary = result.summary
        XCTAssertTrue(summary.contains("0 stopped"))
    }
}
