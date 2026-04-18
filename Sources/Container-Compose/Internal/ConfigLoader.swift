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

import Foundation
import Yams

/// ConfigLoader centralizes the discovery and decoding of orchestration files.
/// It bridges the legacy YAML path and the new Pkl path, providing dual-path parity validation.
public enum ConfigLoader {
    /// Supported compose file names in order of precedence.
    public static let candidates = [
        "compose.yaml",
        "compose.yml",
        "compose.pkl",
        "docker-compose.yaml",
        "docker-compose.yml",
        "docker-compose.pkl"
    ]

    /// Discovers the first available compose file in the given directory.
    public static func discoverPath(in workingDir: String) -> String? {
        for candidate in candidates {
            let path = "\(workingDir)/\(candidate)"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Loads and decodes a configuration file from the specified path.
    /// - Parameters:
    ///   - path: The absolute path to the configuration file.
    ///   - environment: Environment variables for variable substitution (YAML only).
    /// - Returns: A decoded DockerCompose struct.
    public static func load(
        path: String,
        environment: [String: String]
    ) throws -> DockerCompose {
        let url = URL(fileURLWithPath: path)
        let isPkl = url.pathExtension == "pkl"

        if isPkl {
            let pklResult = try PklEvaluator.evaluate(pklFile: url)
            
            // Dual-Path Validation Logic (Plan 101)
            // Sunset clause: skip dual-path if 30 consecutive successful runs proven
            let shouldValidateParity = ProcessInfo.processInfo.environment["DUAL_PATH_VALIDATION"] == "1"
                && !checkSunsetClause()
            
            if shouldValidateParity {
                if let yamlPath = findMatchingYaml(for: url) {
                    print("Info: DUAL_PATH_VALIDATION enabled. Verifying parity with \(URL(fileURLWithPath: yamlPath).lastPathComponent)...")
                    let yamlResult = try loadYaml(at: yamlPath, environment: environment)
                    
                    if pklResult != yamlResult {
                        // Reset streak on mismatch
                        resetDualPathStreak()
                        let message = "CRITICAL: Dual-path mismatch between \(url.lastPathComponent) and \(URL(fileURLWithPath: yamlPath).lastPathComponent)!"
                        print(message)
                        fatalError(message)
                    } else {
                        // Increment streak on success
                        incrementDualPathStreak()
                        print("✓ Dual-path parity verified for \(url.lastPathComponent)")
                    }
                } else {
                    print("Warning: DUAL_PATH_VALIDATION enabled but no matching .yml/.yaml found for \(url.lastPathComponent)")
                }
            } else if ProcessInfo.processInfo.environment["DUAL_PATH_VALIDATION"] == "1" {
                print("Info: DUAL_PATH_VALIDATION sunset reached (30 consecutive parity passes). Skipping dual-path check.")
            }
            
            return pklResult
        } else {
            return try loadYaml(at: path, environment: environment)
        }
    }

    /// Loads a legacy YAML file with variable resolution.
    private static func loadYaml(at path: String, environment: [String: String]) throws -> DockerCompose {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            throw YamlError.invalidYamlEncoding
        }
        
        let resolved = try resolveYamlVariables(content, with: environment)
        return try YAMLDecoder().decode(DockerCompose.self, from: resolved)
    }

    /// Finds a matching YAML file for a given Pkl file to support dual-path validation.
    private static func findMatchingYaml(for pklUrl: URL) -> String? {
        let base = pklUrl.deletingPathExtension()
        for ext in ["yaml", "yml"] {
            let yamlPath = base.appendingPathExtension(ext).path
            if FileManager.default.fileExists(atPath: yamlPath) {
                return yamlPath
            }
        }
        return nil
    }

    // MARK: - Sunset Clause Streak Tracking

    /// Path to the dual-path streak counter file (gitignored).
    private static var streakPath: String {
        ".dual-path-streak"
    }

    /// Returns true if the sunset clause has been reached (30 consecutive parity passes).
    private static func checkSunsetClause() -> Bool {
        guard let content = try? String(contentsOfFile: streakPath, encoding: .utf8),
              let count = Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return count >= 30
    }

    /// Increments the dual-path streak counter on successful parity check.
    private static func incrementDualPathStreak() {
        let current = (try? String(contentsOfFile: streakPath, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        try? "\(current + 1)".write(toFile: streakPath, atomically: true, encoding: .utf8)
    }

    /// Resets the dual-path streak counter on parity mismatch.
    private static func resetDualPathStreak() {
        try? "0".write(toFile: streakPath, atomically: true, encoding: .utf8)
    }
}
