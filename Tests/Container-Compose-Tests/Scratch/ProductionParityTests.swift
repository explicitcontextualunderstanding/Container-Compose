import XCTest
import Foundation
import TestHelpers
@testable import ContainerComposeCore

final class ProductionParityTests: XCTestCase {
    func testHonchoHermesParity() async throws {
        // Must have DUAL_PATH_VALIDATION=1 for parity check to run inside ConfigLoader.load
        setenv("DUAL_PATH_VALIDATION", "1", 1)
        setenv("HONCHO_DB_PASSWORD", "dummy", 1)
        
        let projectDir = URL(fileURLWithPath: "/Users/kieranlal/workspace/Container-Compose")
        
        // This file was created by me in Turn 63
        let pklPath = projectDir.appendingPathComponent("examples/honcho-hermes.pkl")
        // This is the original YAML I read in Turn 44
        let yamlPath = projectDir.appendingPathComponent("examples/honcho-hermes.yml")
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: pklPath.path), "Pkl file should exist at \(pklPath.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: yamlPath.path), "YAML file should exist at \(yamlPath.path)")
        
        print("Comparing \(pklPath.lastPathComponent) and \(yamlPath.lastPathComponent)...")
        
        let pklConfig = try ConfigLoader.load(path: pklPath.path, environment: ProcessInfo.processInfo.environment)
        let yamlConfig = try ConfigLoader.load(path: yamlPath.path, environment: ProcessInfo.processInfo.environment)
        
        if pklConfig != yamlConfig {
            print("❌ Parity Mismatch Detected!")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            
            let pklData = try encoder.encode(pklConfig)
            let yamlData = try encoder.encode(yamlConfig)
            
            print("--- PKL JSON ---")
            print(String(data: pklData, encoding: .utf8)!)
            print("--- YAML JSON ---")
            print(String(data: yamlData, encoding: .utf8)!)
            
            XCTFail("Byte-for-byte parity mismatch between Pkl and YAML")
        } else {
            print("✓ Parity confirmed for honcho-hermes stack")
        }
    }
}
