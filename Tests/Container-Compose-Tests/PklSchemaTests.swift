import XCTest
import Foundation
@testable import ContainerComposeCore

/// Resolve schema path relative to this source file's directory.
/// Tests run from .build/ but schemas live at repo root/Schemas/.
private func schemaPath(_ name: String) -> String {
    let thisFile = #file // .../Tests/ComposePklTests/PklSchemaTests.swift
    let testDir = (thisFile as NSString).deletingLastPathComponent          // .../Tests/ComposePklTests
    let testsDir = (testDir as NSString).deletingLastPathComponent          // .../Tests
    let repoRoot = (testsDir as NSString).deletingLastPathComponent         // .../
    return (repoRoot as NSString).appendingPathComponent("Sources/Container-Compose/Internal/Schemas/\(name)")
}

/// Resolve fixture path relative to this source file's directory.
private func fixturePath(_ name: String) -> String {
    let thisFile = #file
    let testDir = (thisFile as NSString).deletingLastPathComponent
    let testsDir = (testDir as NSString).deletingLastPathComponent
    let repoRoot = (testsDir as NSString).deletingLastPathComponent
    return (repoRoot as NSString).appendingPathComponent("Tests/PklFixtures/\(name)")
}

/// Resolve pkl binary path.
private func pklBinaryPath() -> String {
    if let env = ProcessInfo.processInfo.environment["PKL_EXEC"],
       FileManager.default.fileExists(atPath: env) { return env }
    for candidate in ["/opt/homebrew/bin/pkl", "/usr/local/bin/pkl"] {
        if FileManager.default.fileExists(atPath: candidate) { return candidate }
    }
    return "/usr/local/bin/pkl" // fallback
}

/// Evaluates a Pkl file and returns JSON data.
private func pklEval(path: String, env: [String: String] = [:]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pklBinaryPath())
    process.arguments = ["eval", path, "--format", "json"]
    var envVars = ProcessInfo.processInfo.environment
    envVars["HOST_MAX_CPU"] = env["HOST_MAX_CPU"] ?? "8"
    envVars["HOST_MAX_MEMORY"] = env["HOST_MAX_MEMORY"] ?? "8192"
    envVars.merge(env) { _, new in new }
    process.environment = envVars
    let pipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = pipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        throw NSError(domain: "PklEval", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: String(data: err, encoding: .utf8) ?? "pkl eval failed"])
    }
    return pipe.fileHandleForReading.readDataToEndOfFile()
}

// MARK: - Cycle 1: HonchoPod.pkl Tests

final class PklSchemaTests: XCTestCase {

    /// The structured manifest loaded from Pkl.
    struct Manifest: Codable {
        let tests: [TestEntry]
    }

    struct TestEntry: Codable {
        let name: String
        let fixture: String
        let rung: Int
        let description: String?
        let legacy_test_links: [String]?
        let requires_parity: Bool
        let expected_failure: Bool
    }

    func testManifestLadder() throws {
        let manifestData = try pklEval(path: fixturePath("test-manifest.pkl"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)

        // Group tests by rung
        let groupedByRung = Dictionary(grouping: manifest.tests, by: { $0.rung })
        let sortedRungs = groupedByRung.keys.sorted()

        for rungLevel in sortedRungs {
            guard let tests = groupedByRung[rungLevel] else { continue }
            
            XCTContext.runActivity(named: "Rung \(rungLevel)") { activity in
                for test in tests {
                    XCTContext.runActivity(named: "Test: \(test.name)") { _ in
                        if test.expected_failure {
                            // Negative test: Pkl should reject invalid input
                            let threw = (try? pklEval(path: fixturePath(test.fixture))) == nil
                            XCTAssertTrue(threw, "[\(test.name)] Expected constraint violation but evaluation succeeded")
                        } else {
                            do {
                                let data = try pklEval(path: fixturePath(test.fixture))
                                XCTAssertNotNil(data, "[\(test.name)] Should produce JSON output")

                                // If parity is required, validate against DockerCompose struct
                                if test.requires_parity {
                                    let decoder = JSONDecoder()
                                    XCTAssertNoThrow(
                                        try decoder.decode(DockerCompose.self, from: data),
                                        "[\(test.name)] Output should be valid DockerCompose JSON"
                                    )
                                }
                            } catch {
                                XCTFail("[\(test.name)] Unexpected failure: \(error)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testSchemaPathResolves() {
        let path = schemaPath("HonchoPod.pkl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Schema path should exist: \(path)")
    }
}
