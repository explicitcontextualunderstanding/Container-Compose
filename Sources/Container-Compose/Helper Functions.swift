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

//
//  Helper Functions.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation
import Yams
import Rainbow
import ContainerCommands

/// Error thrown when loading environment files fails.
public enum EnvFileError: Error {
    case fileNotFound(path: String)
    case readFailed(path: String, underlying: Error)
}

/// Loads environment variables from a .env file.
/// - Parameters:
///   - path: The full path to the .env file.
///   - strict: If true, throws errors for missing files. If false, returns empty dict for missing files.
/// - Returns: A dictionary of key-value pairs representing environment variables.
/// - Throws: EnvFileError if strict mode and file cannot be read.
public func loadEnvFile(path: String, strict: Bool = false) throws -> [String: String] {
    var envVars: [String: String] = [:]
    let fileURL = URL(fileURLWithPath: path)

    // Check if file exists
    if !FileManager.default.fileExists(atPath: path) {
        if strict {
            throw EnvFileError.fileNotFound(path: path)
        }
        return envVars
    }

    do {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Ignore empty lines and comments
            if !trimmedLine.isEmpty && !trimmedLine.starts(with: "#") {
                // Parse key=value pairs
                if let eqIndex = trimmedLine.firstIndex(of: "=") {
                    let key = String(trimmedLine[..<eqIndex])
                    let value = String(trimmedLine[trimmedLine.index(after: eqIndex)...])
                    envVars[key] = value
                }
            }
        }
    } catch {
        throw EnvFileError.readFailed(path: path, underlying: error)
    }
    return envVars
}

/// Resolves environment variables within a string (e.g., ${VAR:-default}, ${VAR:?error}).
/// This function supports default values and error-on-missing variable syntax.
/// - Parameters:
///   - value: The string possibly containing environment variable references.
///   - envVars: A dictionary of environment variables to use for resolution.
/// - Returns: The string with all recognized environment variables resolved.
public func resolveVariable(_ value: String, with envVars: [String: String]) -> String {
    var resolvedValue = value
    // Regex to find ${VAR}, ${VAR:-default}, ${VAR:?error}
    let regex = try! NSRegularExpression(pattern: #"\$\{([A-Za-z0-9_]+)(:?-(.*?))?(:\?(.*?))?\}"#, options: [])
    
    // Combine process environment with loaded .env file variables, prioritizing process environment
    let combinedEnv = ProcessInfo.processInfo.environment.merging(envVars) { (current, _) in current }
    
    // Loop to resolve all occurrences of variables in the string
    while let match = regex.firstMatch(in: resolvedValue, options: [], range: NSRange(resolvedValue.startIndex..<resolvedValue.endIndex, in: resolvedValue)) {
        guard let varNameRange = Range(match.range(at: 1), in: resolvedValue) else { break }
        let varName = String(resolvedValue[varNameRange])
        
        if let envValue = combinedEnv[varName] {
            // Variable found in environment, replace with its value
            resolvedValue.replaceSubrange(Range(match.range(at: 0), in: resolvedValue)!, with: envValue)
        } else if let defaultValueRange = Range(match.range(at: 3), in: resolvedValue) {
            // Variable not found, but default value is provided, replace with default
            let defaultValue = String(resolvedValue[defaultValueRange])
            resolvedValue.replaceSubrange(Range(match.range(at: 0), in: resolvedValue)!, with: defaultValue)
        } else if match.range(at: 5).location != NSNotFound, let errorMessageRange = Range(match.range(at: 5), in: resolvedValue) {
            // Variable not found, and error-on-missing syntax used, print error and exit
            let errorMessage = String(resolvedValue[errorMessageRange])
            fputs("Error: Missing required environment variable '\(varName)': \(errorMessage)\n", stderr)
            Application.exit(withError: "Error: Missing required environment variable '\(varName)': \(errorMessage)\n")
        } else {
            // Variable not found and no default/error specified, leave as is and break loop to avoid infinite loop
            break
        }
    }
    return resolvedValue
}

/// Resolves `${VAR}` substitutions in raw YAML text with Docker Compose-compatible `$$` escaping.
/// - `$$` is replaced with a sentinel before resolution, then restored as a literal `$` afterward.
/// - Supports `${VAR}`, `${VAR:-default}`, and `${VAR:?error}` syntax.
/// - Parameters:
///   - yaml: The raw YAML string potentially containing variable references.
///   - envVars: A dictionary of environment variables to use for resolution.
/// - Returns: The YAML string with all variable references resolved.
public func resolveYamlVariables(_ yaml: String, with envVars: [String: String]) -> String {
    // 1. Replace $$ with sentinel to preserve literal $ for shell interpreters
    var yaml = yaml.replacingOccurrences(of: "$$", with: "\u{0000}DOLLAR\u{0000}")
    // 2. Resolve all ${VAR} / ${VAR:-default} / ${VAR:?error}
    yaml = resolveVariable(yaml, with: envVars)
    // 3. Restore sentinel → single $
    yaml = yaml.replacingOccurrences(of: "\u{0000}DOLLAR\u{0000}", with: "$")
    return yaml
}

/// Error thrown when project name derivation fails
public struct ProjectNameError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// Derives a project name from the current working directory.
/// Sanitizes the name to ensure compatibility with container naming conventions.
///
/// Container names must:
/// - Start with a letter or number
/// - Contain only letters, numbers, underscores, periods, or hyphens
/// - Not start with a period
///
/// - Parameter cwd: The current working directory path.
/// - Returns: A sanitized project name suitable for container naming.
/// - Throws: ProjectNameError if the path cannot be processed
public func deriveProjectName(cwd: String) throws -> String {
    // Validate input
    guard !cwd.isEmpty else {
        throw ProjectNameError("Cannot derive project name from empty path")
    }

    // Get the last path component
    var projectName = URL(fileURLWithPath: cwd).lastPathComponent

    // Handle path ending in separator (edge case)
    if projectName.isEmpty {
        // Fall back to full path's last component
        let normalizedPath = (cwd as NSString).standardizingPath
        let components = normalizedPath.split(separator: "/")
        projectName = components.last.map(String.init) ?? "project"
    }

    // Apply sanitization rules:
    // 1. Replace the FIRST dot (for hidden directories like .devcontainers)
    // 2. Replace other invalid characters with underscore
    // 3. Ensure it starts with a letter or number

    var sanitized = ""
    var replacedFirstDot = false
    for (_, char) in projectName.enumerated() {
        if char == "." && !replacedFirstDot {
            // Replace first dot with underscore
            sanitized.append("_")
            replacedFirstDot = true
        } else if char.isLetter || char.isNumber || char == "_" || char == "-" || char == "." {
            // Valid character (dots after first are preserved)
            sanitized.append(char)
        } else {
            // Invalid character - replace with underscore
            sanitized.append("_")
        }
    }

    // Ensure it starts with a letter, number, or underscore (all valid for container names)
    if let first = sanitized.first, !first.isLetter && !first.isNumber && first != "_" {
        sanitized = "_" + sanitized
    }

    // Final validation
    guard !sanitized.isEmpty else {
        return "project"
    }

    return sanitized
}

extension String: @retroactive Error {}

/// A structure representing the result of a command-line process execution.
public struct CommandResult {
    /// The standard output captured from the process.
    public let stdout: String

    /// The standard error output captured from the process.
    public let stderr: String

    /// The exit code returned by the process upon termination.
    public let exitCode: Int32
}

extension NamedColor: @retroactive Codable {

}

/// Error thrown when command execution times out.
public struct CommandTimeoutError: Error {
    public let command: String
    public let timeout: TimeInterval
}

/// Executes a command and streams its output.
/// - Parameters:
///   - command: The command to execute.
///   - args: The arguments to pass to the command.
///   - cwd: The current working directory.
///   - timeout: Maximum time to wait for command completion (default: 300 seconds).
///   - onStdout: Callback for standard output.
///   - onStderr: Callback for standard error.
/// - Returns: The process's exit code.
/// - Throws: Error if process fails to start, or CommandTimeoutError if timeout exceeded.
@discardableResult
public func streamCommand(
    _ command: String,
    args: [String] = [],
    cwd: String,
    timeout: TimeInterval = 300,
    onStdout: @escaping (@Sendable (String) -> Void),
    onStderr: @escaping (@Sendable (String) -> Void)
) async throws -> Int32 {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Preserve original PATH while adding common locations
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let additionalPaths = "/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin"
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": originalPath.isEmpty ? additionalPaths : "\(additionalPaths):\(originalPath)"
        ]) { _, new in new }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // Use async task for timeout instead of Timer to avoid Sendable issues
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
            // After timeout, throw - we'll check below
            throw CommandTimeoutError(command: command, timeout: timeout)
        }

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let string = String(data: data, encoding: .utf8) {
                onStdout(string)
            }
        }

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let string = String(data: data, encoding: .utf8) {
                onStderr(string)
            }
        }

        process.terminationHandler = { proc in
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            // Ensure handles are closed
            try? stdoutHandle.close()
            try? stderrHandle.close()

            continuation.resume(returning: proc.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            timeoutTask.cancel()
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            try? stdoutHandle.close()
            continuation.resume(throwing: error)
        }
    }
}
