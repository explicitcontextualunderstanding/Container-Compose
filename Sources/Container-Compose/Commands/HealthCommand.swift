//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ArgumentParser
import Foundation
import ContainerizationExtras
import ContainerAPIClient
import Yams

/// Error thrown when health check operations fail.
public struct HealthCheckError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    
    public init(_ message: String) {
        self.message = message
    }
}

public struct HealthCommand: AsyncParsableCommand {
    public init() {}
    
    public static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Check health status of service containers"
    )
    
    @Argument(help: "Service name to check (optional, checks all if not specified)")
    var service: String?
    
    @Option(name: .shortAndLong, help: "Path to docker-compose.yml file")
    var file: String?
    
    @Option(name: .long, help: "Working directory")
    var cwd: String?
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    @Flag(name: .long, help: "Watch health status continuously")
    var watch: Bool = false
    
    public mutating func run() async throws {
        let workingDir = cwd ?? FileManager.default.currentDirectoryPath
        let composePath = try deriveComposePath(from: file, cwd: workingDir)
        
        // Load configuration using the centralized Loader (handles substitution and Pkl evaluation)
        let dockerCompose = try ConfigLoader.load(path: composePath, environment: [:])

 let projectName: String
 if let name = dockerCompose.name {
 projectName = name
 } else {
 projectName = try deriveProjectName(cwd: workingDir)
 }
        
        // Get services to check
        let servicesToCheck: [(String, Service)]
        if let serviceName = service {
            guard let svc = dockerCompose.services[serviceName]?.flatMap({ $0 }) else {
                throw HealthCheckError("Service '\(serviceName)' not found in compose file")
            }
            servicesToCheck = [(serviceName, svc)]
        } else {
            servicesToCheck = dockerCompose.services.compactMap { name, svc in
                guard let svc = svc.flatMap({ $0 }) else { return nil }
                return (name, svc)
            }
        }
        
        if watch {
            try await watchHealth(services: servicesToCheck, projectName: projectName, jsonOutput: json)
        } else {
            try await checkHealthOnce(services: servicesToCheck, projectName: projectName, jsonOutput: json)
        }
    }
    
    private func checkHealthOnce(services: [(String, Service)], projectName: String, jsonOutput: Bool) async throws {
        var healthResults: [HealthStatus] = []
        
        for (serviceName, service) in services {
            let baseName = service.container_name ?? "\(projectName)-\(serviceName)"
            let runId = ProcessInfo.processInfo.environment["CCT_RUN_ID"] ?? "orphan"
            
            // Try standard name and CCT_ prefixed version
            var status: HealthStatus?
            let candidates = [
                "CCT_\(runId)_\(baseName)",
                "CCT_orphan_\(baseName)",
                baseName
            ]
            
            for containerName in candidates {
                if let s = try? await checkServiceHealth(containerName: containerName, serviceName: serviceName, service: service) {
                    if s.status != .missing {
                        status = s
                        break
                    }
                }
            }
            
            let finalStatus = status ?? HealthStatus(
                service: serviceName,
                container: baseName,
                status: .missing,
                healthCheck: service.healthcheck != nil,
                message: "Container not found (tried: \(candidates.joined(separator: ", ")))"
            )
            
            healthResults.append(finalStatus)
        }
        
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(healthResults)
            print(String(data: data, encoding: .utf8) ?? "")
        } else {
            printHealthTable(results: healthResults)
        }
    }
    
    private func watchHealth(services: [(String, Service)], projectName: String, jsonOutput: Bool) async throws {
        print("Watching health status (Ctrl+C to stop)...")
        
        while true {
            do {
                // Clear screen for continuous update
                if !jsonOutput {
                    print("\u{1B}[2J\u{1B}[H") // Clear screen and move cursor to top
                }
                
                try await checkHealthOnce(services: services, projectName: projectName, jsonOutput: jsonOutput)
                
                // Wait before next check
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            } catch {
                print("Error checking health: \(error)")
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    
    private func checkServiceHealth(containerName: String, serviceName: String, service: Service) async throws -> HealthStatus {
        // Check if container exists
        guard let container = try? await ClientContainer.get(id: containerName) else {
            return HealthStatus(
                service: serviceName,
                container: containerName,
                status: .missing,
                healthCheck: service.healthcheck != nil,
                message: "Container not found"
            )
        }
        
        // Check if service has healthcheck configured
        guard let healthcheck = service.healthcheck, healthcheck.test != nil else {
            // No healthcheck configured - return running status only
            return HealthStatus(
                service: serviceName,
                container: containerName,
                status: container.status == .running ? .running : .stopped,
                healthCheck: false,
                message: "No healthcheck configured"
            )
        }
        
        // Run healthcheck if container is running
        guard container.status == .running else {
            return HealthStatus(
                service: serviceName,
                container: containerName,
                status: .stopped,
                healthCheck: true,
                message: "Container not running (status: \(container.status))"
            )
        }
        
        // Execute healthcheck command
        print("[DIAGNOSTIC] Executing healthcheck for \(containerName)...")
        let healthy = try await executeHealthcheck(containerName: containerName, healthcheck: healthcheck)
        print("[DIAGNOSTIC] Healthcheck result for \(containerName): \(healthy)")
        
        return HealthStatus(
            service: serviceName,
            container: containerName,
            status: healthy ? .healthy : .unhealthy,
            healthCheck: true,
            message: healthy ? "Health check passed" : "Health check failed"
        )
    }
    
    private func executeHealthcheck(containerName: String, healthcheck: Healthcheck) async throws -> Bool {
        guard let test = healthcheck.test, test.first != "NONE" else {
            return true // No healthcheck or explicitly disabled
        }
        
        // Build exec arguments
        let execArgs: [String]
        if test.first == "CMD-SHELL" {
            guard test.count >= 2 else { return false }
            let shellCommand = test.dropFirst().joined(separator: " ")
            execArgs = [containerName, "/bin/sh", "-c", shellCommand]
        } else if test.first == "CMD" {
            execArgs = [containerName] + Array(test.dropFirst())
        } else {
            execArgs = [containerName] + test
        }
        
        // Execute healthcheck
        let exitCode = try await ContainerComposeCore.streamCommand(
            "container",
            args: ["exec"] + execArgs,
            cwd: cwd ?? FileManager.default.currentDirectoryPath,
            onStdout: { _ in },
            onStderr: { _ in }
        )
        
        return exitCode == 0
    }
    
    private func printHealthTable(results: [HealthStatus]) {
        // Print header
        print("\nSERVICE HEALTH STATUS")
        print(String(repeating: "-", count: 80))
        let sHeaderPadded = "SERVICE".padding(toLength: 20, withPad: " ", startingAt: 0)
        let cHeaderPadded = "CONTAINER".padding(toLength: 30, withPad: " ", startingAt: 0)
        let stHeaderPadded = "STATUS".padding(toLength: 12, withPad: " ", startingAt: 0)
        let chHeaderPadded = "CHECK".padding(toLength: 8, withPad: " ", startingAt: 0)
        print("\(sHeaderPadded) \(cHeaderPadded) \(stHeaderPadded) \(chHeaderPadded)")
        print(String(repeating: "-", count: 80))
        
        // Print results
        for result in results {
            let statusIcon = result.status.icon
            let statusStr = result.status.rawValue
            let checkStr = result.healthCheck ? "yes" : "no"
            
            // Use standard interpolation for stability
            let servicePadded = result.service.padding(toLength: 20, withPad: " ", startingAt: 0)
            let containerPadded = result.container.padding(toLength: 30, withPad: " ", startingAt: 0)
            let statusPadded = statusStr.padding(toLength: 12, withPad: " ", startingAt: 0)
            let checkPadded = checkStr.padding(toLength: 8, withPad: " ", startingAt: 0)
            
            print("\(servicePadded) \(containerPadded) \(statusIcon) \(statusPadded) \(checkPadded)")
        }
        
        print(String(repeating: "-", count: 80))
        
        // Summary
        let healthy = results.filter { $0.status == .healthy }.count
        let unhealthy = results.filter { $0.status == .unhealthy }.count
        let stopped = results.filter { $0.status == .stopped }.count
        let missing = results.filter { $0.status == .missing }.count
        
        print("\nSummary: \(healthy) healthy, \(unhealthy) unhealthy, \(stopped) stopped, \(missing) missing")
    }
    
    private func deriveComposePath(from file: String?, cwd: String) throws -> String {
        if let file = file {
            return file.hasPrefix("/") ? file : "\(cwd)/\(file)"
        }
        
        guard let path = ConfigLoader.discoverPath(in: cwd) else {
            throw HealthCheckError("No compose file found in \(cwd)")
        }
        return path
    }
}

public struct HealthStatus: Codable {
    public let service: String
    public let container: String
    public let status: HealthStatusEnum
    public let healthCheck: Bool
    public let message: String
    
    public enum HealthStatusEnum: String, Codable {
        case healthy
        case unhealthy
        case running
        case stopped
        case missing
        
        var icon: String {
            switch self {
            case .healthy: return "✓"
            case .unhealthy: return "✗"
            case .running: return "●"
            case .stopped: return "○"
            case .missing: return "?"
            }
        }
    }
}
