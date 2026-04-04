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
//  ComposeDown.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/19/25.
//

import ArgumentParser
import ContainerCommands
import ContainerAPIClient
import Foundation
import Yams

public struct ComposeDown: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "down",
        abstract: "Stop containers with compose"
    )

    @Argument(help: "Specify the services to stop")
    var services: [String] = []

    @OptionGroup
    var process: Flags.Process

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFile: String? = nil

    @Option(name: .long, help: "Per-service stop timeout in seconds (default: 30)")
    var timeoutSeconds: Int = 30

    private var foundFilename: String?
    private var composePath: String {
        if let file = composeFile {
            return file.hasPrefix("/") ? file : "\(cwd)/\(file)"
        }
        return "\(cwd)/\(foundFilename ?? "compose.yml")"
    }

    private var fileManager: FileManager { FileManager.default }
    private var projectName: String?

    // MARK: - Result Model

    /// Tracks the outcome of stopping each service for exit code calculation.
    public struct DownResult: Sendable {
        public let stopped: [String]
        public let timeouts: [String]
        public let errors: [String]

        public init(stopped: [String], timeouts: [String], errors: [String]) {
            self.stopped = stopped
            self.timeouts = timeouts
            self.errors = errors
        }

        /// Worst-case exit code: 0=all clean, 1=some timeouts, 2=fatal errors.
        public var exitCode: Int32 {
            if !errors.isEmpty { return 2 }
            if !timeouts.isEmpty { return 1 }
            return 0
        }

        public var isSuccess: Bool { exitCode == 0 }

        public var summary: String {
            var parts: [String] = []
            if !stopped.isEmpty {
                parts.append("\(stopped.count) stopped")
            }
            if !timeouts.isEmpty {
                parts.append("\(timeouts.count) timeout")
            }
            if !errors.isEmpty {
                parts.append("\(errors.count) error")
            }
            if parts.isEmpty {
                return "0 stopped"
            }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - State File (Idempotent Teardown)

    /// Path to the state file for a given working directory.
    public static func stateFilePath(cwd: String) -> URL {
        URL(fileURLWithPath: cwd).appendingPathComponent(".container-compose.state")
    }

    /// Read owned container names from the state file. Returns empty array if file doesn't exist.
    public static func readStateFile(_ url: URL) -> [String] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        return content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Write owned container names to the state file.
    public static func writeStateFile(_ url: URL, containerNames: [String]) {
        let content = containerNames.joined(separator: "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Remove the state file. No-op if it doesn't exist.
    public static func removeStateFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Run

    public mutating func run() async throws {

        // Skip CWD scanning if -f was explicitly provided
        if composeFile == nil {
            // Check for supported filenames and extensions
            let filenames = [
                "compose.yml",
                "compose.yaml",
                "docker-compose.yml",
                "docker-compose.yaml",
            ]
            for filename in filenames {
                if fileManager.fileExists(atPath: "\(cwd)/\(filename)") {
                    foundFilename = filename
                    break
                }
            }
        }

        // Read docker-compose.yml content
        guard let yamlData = fileManager.contents(atPath: composePath) else {
            let path = URL(fileURLWithPath: composePath)
                .deletingLastPathComponent()
                .path
            throw YamlError.composeFileNotFound(path)
        }

      // Decode the YAML file into the DockerCompose struct
      guard let dockerComposeString = String(data: yamlData, encoding: .utf8) else {
          throw YamlError.invalidYamlEncoding
      }

      // Load .env file early so vars are available for pre-decode substitution
      let envFilePath = "\(cwd)/.env"
      let environmentVariables = (try? loadEnvFile(path: envFilePath)) ?? [:]

      // Pre-decode ${VAR} substitution (Docker Compose compatible with $$ escaping)
      let resolvedYaml = try resolveYamlVariables(dockerComposeString, with: environmentVariables)
      let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: resolvedYaml)

        // Determine project name for container naming
        if let name = dockerCompose.name {
            projectName = name
            print("Info: Docker Compose project name parsed as: \(name)")
            print(
                "Note: The 'name' field currently only affects container naming (e.g., '\(name)-serviceName'). Full project-level isolation for other resources (networks, implicit volumes) is not implemented by this tool."
            )
        } else {
            projectName = try deriveProjectName(cwd: cwd)
            print("Info: No 'name' field found in docker-compose.yml. Using directory name as project name: \(projectName)")
        }

        var services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap({ serviceName, service in
            guard let service else { return nil }
            return (serviceName, service)
        })
        services = try Service.topoSortConfiguredServices(services)

        // Filter for specified services
        if !self.services.isEmpty {
            services = services.filter({ serviceName, service in
                self.services.contains(where: { $0 == serviceName }) || self.services.contains(where: { service.dependedBy.contains($0) })
            })
        }

        let result = try await stopOldStuff(services, remove: false)

        // Report summary
        print("Summary: \(result.summary)")

        // Exit with appropriate code
        if !result.isSuccess {
            throw ComposeDownError.teardownIncomplete(result)
        }
    }

    private func stopOldStuff(_ services: [(serviceName: String, service: Service)], remove: Bool) async throws -> DownResult {
        guard let projectName else { return DownResult(stopped: [], timeouts: [], errors: []) }

        var stopped: [String] = []
        var timeouts: [String] = []
        var errors: [String] = []
        var ownedContainerNames: [String] = []

        for (serviceName, service) in services {
            // Respect explicit container_name, otherwise use default pattern
            let containerName: String
            if let explicitContainerName = service.container_name {
                containerName = explicitContainerName
            } else {
                containerName = "\(projectName)-\(serviceName)"
            }

            ownedContainerNames.append(containerName)

            print("Stopping container: \(containerName)")
            guard let container = try? await ClientContainer.get(id: containerName) else {
                print("Warning: Container '\(containerName)' not found, skipping.")
                continue
            }

            // Stop with per-service timeout
            let didStop = try await stopWithTimeout(container: container, name: containerName, timeout: timeoutSeconds)
            if didStop {
                print("Successfully stopped container: \(containerName)")
                stopped.append(containerName)
            } else {
                print("Warning: Timeout stopping container: \(containerName) (force-stopped)")
                timeouts.append(containerName)
            }

            if remove {
                do {
                    try await container.delete()
                    print("Successfully removed container: \(containerName)")
                } catch {
                    print("Error Removing Container: \(error)")
                    errors.append(containerName)
                }
            }
        }

        // Write state file so a subsequent `down` can resume
        let statePath = ComposeDown.stateFilePath(cwd: cwd)
        if ownedContainerNames.isEmpty {
            // No services to manage — remove state file if it exists (idempotent no-op)
            ComposeDown.removeStateFile(statePath)
        } else {
            ComposeDown.writeStateFile(statePath, containerNames: ownedContainerNames)
        }

        return DownResult(stopped: stopped, timeouts: timeouts, errors: errors)
    }

    /// Stop a container with a timeout. Returns true if stopped gracefully, false if timed out.
    private func stopWithTimeout(container: ClientContainer, name: String, timeout: Int) async throws -> Bool {
        let timeoutNs = UInt64(timeout) * 1_000_000_000

        return try await withThrowingTaskGroup(of: Bool.self) { group in
            // Primary: try graceful stop
            group.addTask {
                try await container.stop()
                return true
            }

            // Timeout: cancel after N seconds
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                return false
            }

            // Wait for first result
            let graceful = try await group.next() ?? false
            group.cancelAll()

            if graceful {
                return true
            }

            // Timed out — attempt force stop
            print("Graceful stop timed out for \(name), attempting force stop...")
            do {
                try await container.delete(force: true)
                return false // stopped but not gracefully
            } catch {
                print("Force stop also failed for \(name): \(error)")
                return false
            }
        }
    }
}

// MARK: - Error Types

public enum ComposeDownError: Error, CustomStringConvertible {
    case teardownIncomplete(ComposeDown.DownResult)

    public var description: String {
        switch self {
        case .teardownIncomplete(let result):
            return "Teardown incomplete: \(result.summary)"
        }
    }
}
