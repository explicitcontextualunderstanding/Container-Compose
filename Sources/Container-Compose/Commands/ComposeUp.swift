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
//  ComposeUp.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/19/25.
//

import ArgumentParser
import ContainerCommands
//import ContainerClient
import ContainerAPIClient
import ContainerCommands
import ContainerizationExtras
import Foundation
import Network
@preconcurrency import Rainbow
import Yams

/// Error thrown when container run operations fail.
public struct ContainerRunError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// Error thrown when a dependency does not become healthy in time.
public struct HealthcheckTimeoutError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// Error thrown when a dependency service fails (non-zero exit code or timeout).
public struct DependencyFailedError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// Error thrown when image pull operations fail.
public struct ImagePullError: Error, CustomStringConvertible {
    public let message: String
    public let isTransient: Bool
    public var description: String { message }
    public init(_ message: String, isTransient: Bool = false) {
        self.message = message
        self.isTransient = isTransient
    }
}

public struct ComposeUp: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "up",
        abstract: "Start containers with compose",
        discussion: """
        ENVIRONMENT VARIABLE SUBSTITUTION:
        • ${VAR}, ${VAR:-default}, ${VAR:?error} are resolved in all YAML values
        • Use $$ for literal $ (e.g., command: "echo $$HOME")
        • Variables are resolved from .env file and host environment

        SERVICE DISCOVERY:
        • __{SERVICE_NAME}_HOST__ resolves to container IP at runtime
        • __{SERVICE_NAME}_PORT__ resolves to first exposed port
        • Supports fuzzy matching (case-insensitive, strips hyphens/underscores)

        DEPENDS_ON HEALTHCHECKS:
        • condition: service_healthy waits for dependency healthchecks
        • Supports test: ["CMD-SHELL", "command"] format
        • Configurable interval, timeout, retries, start_period

        VOLUME MAPPING:
        • service.volumes generates -v flags automatically
        • Named volumes: volume_name:/container/path
        • Bind mounts: /host/path:/container/path or ./relative:/container/path

        MACOS LIMITATIONS:
        • Virtualization.framework has 63-character limit for container labels
        • Container names are PROJECT-SERVICE (or explicit container_name)
        • Exceeding limit causes 'Invalid argument' (Code 22)
        • Keep service and project names short
        """
    )

    @Argument(help: "Specify the services to start")
    var services: [String] = []

    @Flag(
        name: [.customShort("d"), .customLong("detach")],
        help: "Detaches from container logs. Note: If you do NOT detach, killing this process will NOT kill the container. To kill the container, run container-compose down")
    var detach: Bool = false

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFile: String? = nil

    private var foundFilename: String?
    var composePath: String {
        if let file = composeFile {
            return file.hasPrefix("/") ? file : "\(cwd)/\(file)"
        }
        return "\(cwd)/\(foundFilename ?? "compose.yml")"
    }

    @Flag(name: [.customShort("b"), .customLong("build")])
    var rebuild: Bool = false

    @Flag(name: .long, help: "Stop and recreate all containers, removing existing ones first. Use for clean startup after code changes.")
    var forceRecreate: Bool = false

    @Flag(name: .long, help: "If containers already exist and are running, don't recreate them")
    var noRecreate: Bool = false

    @Flag(name: .long, help: "Recover crashed or stopped containers without recreating them. Mutually exclusive with --build and --force-recreate.")
    var recover: Bool = false

    @Flag(name: .long, help: "Do not use cache")
    var noCache: Bool = false

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var logging: Flags.Logging

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }
    var envFilePath: String { "\(cwd)/\(process.envFile.first ?? ".env")" }  // Path to optional .env file

    private var fileManager: FileManager { FileManager.default }
    private var projectName: String?
    private var environmentVariables: [String: String] = [:]
    private var containerIps: [String: String] = [:]
    private var containerPorts: [String: String] = [:]
    private var containerConsoleColors: [String: NamedColor] = [:]
  // Services that were already present and running before this compose run. Used to
  // avoid blocking 'service_healthy' checks against externally managed containers.
  private var externallyPresentServices: Set<String> = []
  // Networks created by this compose run, for cleanup during compose down
  private var createdNetworks: [String] = []
  // Service PIDs for socket relay peer verification (Phase 5)
  private var servicePIDs: [String: pid_t] = [:]

  private static let availableContainerConsoleColors: Set<NamedColor> = [
        .blue, .cyan, .magenta, .lightBlack, .lightBlue, .lightCyan, .lightYellow, .yellow, .lightGreen, .green,
    ]

    public mutating func validate() throws {
        if forceRecreate && noRecreate {
            throw ValidationError("--force-recreate and --no-recreate are mutually exclusive")
        }
        if recover && rebuild {
            throw ValidationError("--recover and --build are mutually exclusive")
        }
        if recover && forceRecreate {
            throw ValidationError("--recover and --force-recreate are mutually exclusive")
        }
    }

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

        // Read compose.yml content
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
        environmentVariables = (try? loadEnvFile(path: envFilePath)) ?? [:]

        // Pre-decode ${VAR} substitution (Docker Compose compatible with $$ escaping)
        let resolvedYaml = try resolveYamlVariables(dockerComposeString, with: environmentVariables)
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: resolvedYaml)

        // Handle 'version' field
        if let version = dockerCompose.version {
            print("Info: Docker Compose file version parsed as: \(version)")
            print("Note: The 'version' field influences how a Docker Compose CLI interprets the file, but this custom 'container-compose' tool directly interprets the schema.")
        }

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

        // Get Services to use
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

        // Only force-recreate tears down existing containers first
        if forceRecreate {
            try await stopOldStuff(services.map({ $0.serviceName }), remove: true)
        }

        // Process top-level networks
        // This creates named networks defined in the docker-compose.yml
        if let networks = dockerCompose.networks {
            print("\n--- Processing Networks ---")
            for (networkName, networkConfig) in networks {
                try await self.setupNetwork(name: networkName, config: networkConfig)
            }
            print("--- Networks Processed ---\n")
        }

        // Process top-level volumes
        // This creates named volumes defined in the docker-compose.yml
        if let volumes = dockerCompose.volumes {
            print("\n--- Processing Volumes ---")
            for (volumeName, volumeConfig) in volumes {
                try await setupVolume(name: volumeName, config: volumeConfig)
            }
            print("--- Volumes Processed ---\n")
        }

        // Process each service defined in the docker-compose.yml
        print("\n--- Processing Services ---")

        print(services.map(\.serviceName))
        for (serviceName, service) in services {
            try await configService(service, serviceName: serviceName, from: dockerCompose, noRecreate: noRecreate)

// After starting this service, check if any subsequent services need it to be healthy
        let containerName = service.container_name ?? "\(projectName ?? "")-\(serviceName)"
        let remainingServices = Array(services.dropFirst(services.firstIndex(where: { $0.serviceName == serviceName })! + 1))
        for (futureName, futureService) in remainingServices {
            // Check for service_healthy condition
            if futureService.healthyDependencies.contains(serviceName) {
                // Find the healthcheck on the dependency (this service)
                guard let healthcheck = service.healthcheck else {
                    print("Warning: Service '\(futureName)' depends on '\(serviceName)' with condition service_healthy, but '\(serviceName)' has no healthcheck configured.")
                    continue
                }
                print("Service '\(futureName)' depends on '\(serviceName)' being healthy. Waiting...")
                try await waitForHealthy(
                    containerName: containerName,
                    dependencyName: serviceName,
                    healthcheck: healthcheck
                )
                print("Service '\(serviceName)' is healthy.")
            }
            
            // Check for service_completed_successfully condition
            if futureService.completedSuccessfullyDependencies.contains(serviceName) {
                print("Service '\(futureName)' depends on '\(serviceName)' completing successfully. Waiting...")
                try await waitForCompletedSuccessfully(
                    containerName: containerName,
                    dependencyName: serviceName
                )
                print("Service '\(serviceName)' completed successfully.")
            }
    }
  }

  // MARK: - Socket Relay Management

  // Start socket relays for services with publish_socket configuration
  print("\n--- Starting Socket Relays ---")
  let socketRelays = await startSocketRelays(for: services)
  print("--- Socket Relays Started ---\n")

  // Recovery summary: if any services were already running, emit a prominent banner
        // so the operator knows the system detected a crash-recovery scenario.
        if !externallyPresentServices.isEmpty {
            print("\n═══════════════════════════════════════════════════════")
            print(" RECOVERY MODE — \(externallyPresentServices.count) service(s) already running")
            print("═══════════════════════════════════════════════════════")
            for svc in externallyPresentServices.sorted() {
                print(" ✓ '\(svc)' — detected running, health-gates will be checked")
            }
            print("═══════════════════════════════════════════════════════\n")
        }

  // Write state file for compose down to use
  let state = ComposeDown.ComposeState(
    containers: services.map { $0.service.container_name ?? "\(projectName ?? "")-\($0.serviceName)" },
    networks: createdNetworks,
    socketRelays: socketRelays
  )
  let statePath = ComposeDown.stateFilePath(cwd: cwd)
  ComposeDown.writeStateFile(statePath, state: state)
  print("Info: State file written with \(state.containers.count) container(s), \(state.networks.count) network(s), and \(state.socketRelays.count) socket relay(s).")

        if !detach {
            await waitForever()
        }
    }

  func waitForever() async -> Never {
    for await _ in AsyncStream<Void>(unfolding: {}) {
      // This will never run
    }
    fatalError("unreachable")
  }

  // MARK: - Socket Relay Functions

/// Start socket relays for services with publish_socket configuration
private func startSocketRelays(for services: [(serviceName: String, service: Service)]) async -> [ComposeDown.SocketRelayState] {
    // Check if any services need socket relays
    let servicesWithSockets = services.filter { $0.service.publish_socket != nil }
    guard !servicesWithSockets.isEmpty else {
        print("Info: No socket relays configured")
        return []
    }

    // Ensure sandbox-resilient relay root directory exists
    do {
        try RelayConstants.ensureRelayRoot()
    } catch {
        print("Warning: Could not create relay root directory: \(error)")
    }

    // Initialize relay manager
    let eventLog = RelayEventLog()
    let relayManager = RelayManager(eventLog: eventLog)
    var socketRelays: [ComposeDown.SocketRelayState] = []

    // Start relays for each service
    for (serviceName, service) in servicesWithSockets {
      guard let socketConfig = service.publish_socket else { continue }

      // Parse publish_socket config: "containerPath:hostPath" or just "containerPath"
      let parts = socketConfig.split(separator: ":", omittingEmptySubsequences: false)
let hostSocketPath: String

if parts.count >= 2 {
    // Format: "containerPath:hostPath"
    hostSocketPath = String(parts[1])
} else {
    // Format: just "containerPath" - use sandbox-resilient default path
    hostSocketPath = RelayConstants.socketPath(for: serviceName, project: projectName).path
}

      // Get TCP port from service.ports (use first port mapping)
      let tcpPort: UInt16
      if let firstPort = service.ports?.first,
         let portRange = firstPort.range(of: ":"),
         let portNum = UInt16(firstPort[..<portRange.lowerBound]) {
        tcpPort = portNum
      } else {
        // Generate ephemeral port
        tcpPort = await findAvailablePort()
      }

      // Create relay configuration
      let relayId = "\(projectName ?? "")-\(serviceName)"
      let config = RelayManager.RelayConfiguration(
        id: relayId,
        tcpPort: tcpPort,
        unixSocketPath: hostSocketPath,
        description: "Socket relay for \(serviceName)"
      )

      do {
        print("Starting socket relay for \(serviceName): TCP:\(tcpPort) → \(hostSocketPath)")
        try await relayManager.startRelay(config)

        // Track the relay for state file
        let relayState = ComposeDown.SocketRelayState(
          id: relayId,
          tcpPort: tcpPort,
          unixSocketPath: hostSocketPath
        )
        socketRelays.append(relayState)

        print("✓ Socket relay started: \(relayId)")
      } catch {
        print("⚠️ Failed to start socket relay for \(serviceName): \(error)")
      }
    }

    return socketRelays
  }

  /// Find an available TCP port (ephemeral)
  private func findAvailablePort() async -> UInt16 {
    // Create a temporary socket to find an available port
    let socket = socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(socket) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = INADDR_ANY.bigEndian
    addr.sin_port = 0 // Let system assign port

    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
        Darwin.bind(socket, addrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    guard bindResult == 0 else {
      // Fallback to random port in high range
      return UInt16.random(in: 30000...65000)
    }

    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    var assignedAddr = sockaddr_in()
    let getResult = withUnsafeMutablePointer(to: &assignedAddr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
        getsockname(socket, addrPtr, &addrLen)
      }
    }

    guard getResult == 0 else {
      return UInt16.random(in: 30000...65000)
    }

    return assignedAddr.sin_port.bigEndian
  }

  private func getIPForContainer(_ containerName: String) async throws -> String? {
        let container = try await ClientContainer.get(id: containerName)
        let ip = container.networks.compactMap { $0.ipv4Address.address.description }.first

        return ip
    }

    /// Repeatedly checks `container list -a` until the given container is listed as `running`.
    /// - Parameters:
    ///   - containerName: The exact name of the container (e.g. "Assignment-Manager-API-db").
    ///   - timeout: Max seconds to wait before failing.
    ///   - interval: How often to poll (in seconds).
    private func waitUntilContainerIsRunning(_ containerName: String, timeout: TimeInterval = 30, interval: TimeInterval = 0.5) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            do {
                let container = try await ClientContainer.get(id: containerName)
                if container.status == .running {
                    print("Container '\(containerName)' is now running.")
                    return
                }
            } catch {
                // Container doesn't exist yet, keep polling
            }

            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        throw NSError(
            domain: "ContainerWait", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for container '\(containerName)' to be running."
            ])
    }

/// Error thrown when a dependency container cannot be found.
    public struct ContainerNotFoundError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
        public init(_ message: String) { self.message = message }
    }

    /// Captures the last N lines of container output for debugging failed health checks.
    private func captureContainerLogs(_ containerName: String, lines: Int = 50) async -> String {
        // Use actor to safely collect logs from concurrent callbacks
        actor LogCollector {
            private var output = ""
            func append(_ line: String) { output += line + "\n" }
            func getOutput() -> String { output }
        }
        let collector = LogCollector()
        do {
            _ = try await ContainerComposeCore.streamCommand(
                "container", args: ["logs", "--tail", "\(lines)", containerName], cwd: self.cwd,
                onStdout: { (msg: String) in Task { await collector.append(msg) } },
                onStderr: { (msg: String) in Task { await collector.append(msg) } }
            )
            let logOutput = await collector.getOutput()
            return logOutput.isEmpty ? "(No logs available)" : logOutput
        } catch {
            return "(Could not capture logs: \(error))"
        }
    }

    /// Waits for a container to pass its healthcheck by running the healthcheck command inside it.
    private func waitForHealthy(containerName: String, dependencyName: String, healthcheck: Healthcheck) async throws {
        guard let test = healthcheck.test, test.first != "NONE" else {
            return // No healthcheck or explicitly disabled
        }

        // Verify container exists before attempting health checks
        do {
            let _ = try await ClientContainer.get(id: containerName)
        } catch {
            // If the container is not found, give a clear, actionable error and do not hang.
            // Recommend using short-form depends_on for externally managed containers.
            throw ContainerNotFoundError(
                "Dependency container '\(containerName)' (service '\(dependencyName)') not found. "
                + "If this container was started outside container-compose, ensure it exists and is accessible. "
                + "For externally managed dependencies, replace long-form depends_on with the short-form (e.g., depends_on: [\"external-db\"]) or ensure the external container is named exactly as referenced."
            )
        }

        let startPeriodSeconds = Self.parseDuration(healthcheck.start_period) ?? 30
        let intervalSeconds = Self.parseDuration(healthcheck.interval) ?? 30
        let timeoutSeconds = Self.parseDuration(healthcheck.timeout) ?? 30
        let retries = healthcheck.retries ?? 3

        // Respect start_period: sleep initially before checking
        if startPeriodSeconds > 0 {
            print("  Waiting \(startPeriodSeconds)s start_period for '\(dependencyName)'...")
            try await Task.sleep(nanoseconds: UInt64(startPeriodSeconds * 1_000_000_000))
        }

        // Build the exec arguments from the healthcheck test
        // Apple container exec: container exec <id> <command> <args>... (no "--" separator)
        let execArgs: [String]
        if test.first == "CMD-SHELL" {
            // ["CMD-SHELL", "pg_isready -U postgres"] -> exec with /bin/sh -c
            guard test.count >= 2 else { return }
            let shellCommand = test.dropFirst().joined(separator: " ")
            execArgs = [containerName, "/bin/sh", "-c", shellCommand]
        } else if test.first == "CMD" {
            // ["CMD", "pg_isready", "-U", "postgres"] -> exec directly
            execArgs = [containerName] + Array(test.dropFirst())
        } else {
            // Unknown format, try treating as direct command
            execArgs = [containerName] + test
        }

        var consecutiveFailures = 0
        let deadline = Date().addingTimeInterval(
            TimeInterval(retries) * intervalSeconds + timeoutSeconds
        )

        while Date() < deadline {
            let exitCode = try await ContainerComposeCore.streamCommand(
                "container", args: ["exec"] + execArgs, cwd: self.cwd,
                onStdout: { _ in }, onStderr: { _ in }
            )

            if exitCode == 0 {
                return // Healthy!
            }

            consecutiveFailures += 1
            if consecutiveFailures >= retries {
                let containerLogs = await captureContainerLogs(containerName)
                throw HealthcheckTimeoutError(
                    "Dependency '\(dependencyName)' failed healthcheck after \(retries) retries.\n"
                    + "Container output (last 50 lines):\n\(containerLogs)"
                )
            }

            print("  Healthcheck for '\(dependencyName)' failed (attempt \(consecutiveFailures)/\(retries)). Retrying in \(intervalSeconds)s...")
            try await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
        }

        let containerLogs = await captureContainerLogs(containerName)
        throw HealthcheckTimeoutError(
            "Timed out waiting for dependency '\(dependencyName)' to become healthy.\n"
            + "Container output (last 50 lines):\n\(containerLogs)"
        )
    }
    
    /// Waits for a container to exit with exit code 0 (service_completed_successfully condition).
    /// - Parameters:
    ///   - containerName: The exact name of the container (e.g. "project-migrations").
    ///   - dependencyName: The service name for logging (e.g. "migrations").
    ///   - timeout: Max seconds to wait before failing.
    ///   - interval: How often to poll (in seconds).
    private func waitForCompletedSuccessfully(
        containerName: String,
        dependencyName: String,
        timeout: TimeInterval = 300,
        interval: TimeInterval = 1.0
    ) async throws {
        // Verify container exists before attempting to wait
        do {
            let _ = try await ClientContainer.get(id: containerName)
        } catch {
            throw ContainerNotFoundError(
                "Dependency container '\(containerName)' (service '\(dependencyName)') not found. "
                + "Cannot wait for service_completed_successfully condition."
            )
        }
        
        print("Service depends on '\(dependencyName)' to complete successfully. Waiting for exit code 0...")
        
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            do {
                let container = try await ClientContainer.get(id: containerName)
                
                // Check if container has stopped
                if container.status == .stopped {
                    // Container has stopped - we need to check if it succeeded
                    // Since Apple Container runtime doesn't expose exit code after stop,
                    // we assume success for now. In practice, init containers that complete
                    // successfully will stop cleanly.
                    // TODO: Find a way to get the actual exit code from stopped containers
                    print("Service '\(dependencyName)' has stopped.")
                    return
                }
                
                // Container is still running, wait and poll again
                print("  Waiting for '\(dependencyName)' to complete (status: \(container.status))...")
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                // Container might not exist yet or polling error, keep trying
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        
        throw DependencyFailedError(
            "Timed out waiting for dependency '\(dependencyName)' to complete. "
            + "Container did not exit within \(Int(timeout)) seconds."
        )
    }

/// Parses a duration string like "30s", "1m", "10" into seconds. Returns nil if unparseable.
    static func parseDuration(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        
        if trimmed.hasSuffix("s") {
            guard let val = Double(trimmed.dropLast()) else { return nil }
            return val
        } else if trimmed.hasSuffix("m") {
            guard let val = Double(trimmed.dropLast()) else { return nil }
            return val * 60
        } else if trimmed.hasSuffix("h") {
            guard let val = Double(trimmed.dropLast()) else { return nil }
            return val * 3600
        } else {
            // Bare number treated as seconds
            return Double(trimmed)
        }
    }
    
    /// Checks for known database paths that may have virtiofs performance/reliability issues on macOS
    /// Emits warnings to help users avoid known problematic configurations
    private static func checkVirtiofsDatabaseWarnings(destination: String, serviceName: String) {
        let databasePaths: [(String, String, String)] = [
            ("PostgreSQL", "/var/lib/postgresql/data", "Consider using a named volume or Docker Desktop for database workloads"),
            ("MySQL/MariaDB", "/var/lib/mysql", "Consider using a named volume or Docker Desktop for database workloads"),
            ("Redis", "/data", "Redis AOF files may have performance issues with virtiofs"),
            ("MongoDB", "/data/db", "MongoDB journal files may have performance issues with virtiofs"),
            ("SQLite", ".db", "SQLite database files may have locking issues with virtiofs"),
            ("BerkeleyDB", "/var/lib/berkeleydb", "Berkeley DB files may have locking issues with virtiofs")
        ]
        
        for (dbName, dbPath, recommendation) in databasePaths {
            if destination.contains(dbPath) {
                print("⚠️ [VIRTIOFS WARNING] Service '\(serviceName)' mounts to \(dbName) path: \(destination)")
                print("                      \(recommendation)")
                print("                      See: https://github.com/Mcrich23/Container-Compose/issues/virtiofs-db")
            }
        }
    }

    /// Error thrown when stopping/removing old containers fails.
    public struct StopOldStuffError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
        public init(_ message: String) { self.message = message }
    }

    private func stopOldStuff(_ services: [String], remove: Bool) async throws {
        guard let projectName else { return }
        let containers = services.map { "\(projectName)-\($0)" }
        var errors: [Error] = []

        for container in containers {
            print("Stopping container: \(container)")
            guard let container = try? await ClientContainer.get(id: container) else { continue }

            do {
                try await container.stop()
            } catch {
                print("Error Stopping Container: \(error)")
                errors.append(error)
            }
            if remove {
                do {
                    try await container.delete()
                } catch {
                    print("Error Removing Container: \(error)")
                    errors.append(error)
                }
            }
        }

        // If any errors occurred, throw a combined error
        if !errors.isEmpty {
            throw StopOldStuffError("Failed to stop/remove \(errors.count) container(s). Check logs for details.")
        }
    }

    // MARK: Compose Top Level Functions

    private mutating func updateEnvironmentWithServiceIP(_ serviceName: String, containerName: String, ports: [String]?) async throws {
        let ip = try await getIPForContainer(containerName)
        self.containerIps[serviceName] = ip

        // Extract the first container port from "hostPort:containerPort" mappings
        if let firstPort = ports?.first, firstPort.contains(":") {
            let containerPort = firstPort.split(separator: ":").last.map(String.init)
            self.containerPorts[serviceName] = containerPort
        }

        for (key, value) in environmentVariables.map({ ($0, $1) }) where value == serviceName {
            self.environmentVariables[key] = ip ?? value
        }
    }

    /// Error thrown when volume operations fail.
    public struct VolumeError: Error {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    private func setupVolume(name volumeName: String, config volumeConfig: Volume?) async throws {
        guard let projectName else {
            throw VolumeError("Cannot setup volume: projectName is nil")
        }
        let actualVolumeName = volumeConfig?.name ?? volumeName

        let volumeCreateArgs = Self.makeVolumeCreateArgs(name: actualVolumeName, config: volumeConfig)

    print("Ensuring volume: \(actualVolumeName)")

    // Check if volume already exists before attempting create
    let volumeCheck = try await ContainerComposeCore.streamCommand("container", args: ["volume", "inspect", actualVolumeName], cwd: self.cwd, onStdout: { _ in }, onStderr: { _ in })
    let volumeAlreadyExists = volumeCheck == 0

    if !volumeAlreadyExists {
      print("Executing container volume create: container volume create \(volumeCreateArgs.joined(separator: " "))")

      let exitCode = try await ContainerComposeCore.streamCommand("container", args: ["volume", "create"] + volumeCreateArgs, cwd: self.cwd, onStdout: { print($0) }, onStderr: { print($0) })

      guard exitCode == 0 else {
        throw VolumeConfigError.createFailed(
          name: actualVolumeName,
          exitCode: exitCode,
          stderr: "Volume create failed with exit code \(exitCode). See output above for details."
        )
      }
    } else {
      print("Volume '\(actualVolumeName)' already exists, skipping create")
    }

        let volumeUrl = URL.homeDirectory.appending(path: ".containers/Volumes/\(projectName)/\(actualVolumeName)")
        let volumePath = volumeUrl.path(percentEncoded: false)

        do {
            try fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true)
        } catch {
            print("Warning: Could not create directory at \(volumePath): \(error)")
        }
    }

    private mutating func setupNetwork(name networkName: String, config networkConfig: Network?) async throws {
        let actualNetworkName = networkConfig?.name ?? networkName

        if let externalNetwork = networkConfig?.external, externalNetwork.isExternal {
            print("Info: Network '\(networkName)' is declared as external.")
            print("This tool assumes external network '\(externalNetwork.name ?? actualNetworkName)' already exists and will not attempt to create it.")
        } else {
            let commands = Self.makeNetworkCreateArgs(name: actualNetworkName, config: networkConfig)

            print("Creating network: \(networkName) (Actual name: \(actualNetworkName))")
            print("Executing container network create: container network create \(commands.joined(separator: " "))")
            guard (try? await ClientNetwork.get(id: actualNetworkName)) == nil else {
                print("Network '\(networkName)' already exists")
                return
            }

            let networkCreate = try Application.NetworkCreate.parse(commands + logging.passThroughCommands())

            try await networkCreate.run()
            print("Network '\(networkName)' created")

            // Track created network for cleanup during compose down
            createdNetworks.append(actualNetworkName)
        }
    }

// MARK: Static Helpers for Testing

/// Resolves platform for build/run from service.platform.
    /// Note: Apple Container 0.11.0+ natively supports CONTAINER_DEFAULT_PLATFORM env var
    /// when --platform is not specified. We pass through service.platform if set.
    /// - Parameters:
    ///   - servicePlatform: Optional platform string from service configuration
    /// - Returns: Platform string for --platform flag, or nil to use upstream defaults
    public static func resolvePlatform(servicePlatform: String?) -> String? {
        // If service.platform is set, use it directly
        // Otherwise return nil to let upstream handle CONTAINER_DEFAULT_PLATFORM
        return servicePlatform
    }

    public static func makeNetworkCreateArgs(name: String, config: Network?) -> [String] {
        var commands = [name]

        if config?.isInternal == true {
            commands.insert("--internal", at: 0)
        }

        if let labels = config?.labels {
            for (key, value) in labels {
                commands.insert(contentsOf: ["--label", "\(key)=\(value)"], at: 0)
            }
        }

        if let ipamConfigs = config?.ipam?.config {
            for config in ipamConfigs {
                if let subnet = config.subnet {
                    commands.insert(contentsOf: ["--subnet", subnet], at: 0)
                }
            }
        }
        
        return commands
    }
    
    public static func makeVolumeCreateArgs(name: String, config: Volume?) -> [String] {
        var volumeCreateArgs = [name]

        if let labels = config?.labels {
            for (key, value) in labels {
                volumeCreateArgs.insert(contentsOf: ["--label", "\(key)=\(value)"], at: 0)
            }
        }

        if let opts = config?.driver_opts {
            for (key, value) in opts {
                volumeCreateArgs.insert(contentsOf: ["--opt", "\(key)=\(value)"], at: 0)
            }
        }
        
        return volumeCreateArgs
    }

    // MARK: Placeholder Resolution

    /// Normalizes a service name for fuzzy matching: lowercased, hyphens and underscores stripped.
    private static func normalizeServiceName(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    /// Resolves `__{SERVICE}_HOST__` and `__{SERVICE}_PORT__` placeholders in env var values.
    /// Uses fuzzy matching on service names (case-insensitive, strips hyphens/underscores).
    /// Unknown placeholders are left untouched (e.g. `DIALECTIC__LEVELS__*`).
    static func resolveServicePlaceholder(
        _ value: String,
        containerIps: [String: String],
        containerPorts: [String: String],
        knownServiceNames: [String]
    ) -> String {
        let pattern = #"__([A-Za-z0-9_-]+)_(HOST|PORT)__"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return value }

        let range = NSRange(value.startIndex..., in: value)
        let matches = regex.matches(in: value, range: range)

        guard !matches.isEmpty else { return value }

        // Build a lookup from normalized service name → actual service name
        let normalizedLookup: [String: String] = Dictionary(
            knownServiceNames.map { (normalizeServiceName($0), $0) },
            uniquingKeysWith: { $1 }
        )

        var result = value
        for match in matches.reversed() {
            guard
                let nameRange = Range(match.range(at: 1), in: value),
                let typeRange = Range(match.range(at: 2), in: value),
                let fullRange = Range(match.range, in: value)
            else { continue }

            let rawName = String(value[nameRange])
            let placeholderType = String(value[typeRange]).uppercased()
            let normalizedName = normalizeServiceName(rawName)

            let resolved: String? = if let actualServiceName = normalizedLookup[normalizedName] {
                switch placeholderType {
                case "HOST": containerIps[actualServiceName]
                case "PORT": containerPorts[actualServiceName]
                default: nil
                }
            } else {
                nil
            }

            if let resolved {
                result.replaceSubrange(fullRange, with: resolved)
            }
        }
        return result
    }

    // MARK: Compose Service Level Functions
    private mutating func configService(_ service: Service, serviceName: String, from dockerCompose: DockerCompose, noRecreate: Bool = false) async throws {
        guard let projectName else { throw ComposeError.invalidProjectName }

        var imageToRun: String
        
        // Handle 'build' configuration
        if let buildConfig = service.build {
            imageToRun = try await buildService(buildConfig, for: service, serviceName: serviceName)
        } else if let img = service.image {
            // Use specified image if no build config
            // Pull image if necessary
            try await pullImage(img, platform: service.platform, scheme: service.scheme)
            imageToRun = img
        } else {
            // Should not happen due to Service init validation, but as a fallback
            throw ComposeError.imageNotFound(serviceName)
        }

        // Combine environment variables from .env files and service environment
        var combinedEnv: [String: String] = environmentVariables

        if let envFiles = service.env_file {
            for envFile in envFiles {
                do {
                    let additionalEnvVars = try loadEnvFile(path: "\(cwd)/\(envFile)")
                    combinedEnv.merge(additionalEnvVars) { (current, _) in current }
                } catch let error as EnvFileError {
                    print("Warning: Could not load env file '\(envFile)': \(error)")
                    // Continue without the env file - non-fatal
                }
            }
        }

        if let serviceEnv = service.environment {
            combinedEnv.merge(serviceEnv) { (_, new) in new }  // Service env overrides .env files
        }

        // Resolve any remaining variables (safety net for edge cases; idempotent for already-resolved values)
        combinedEnv = combinedEnv.mapValues({ value in
            (try? resolveVariable(value, with: combinedEnv)) ?? value
        })

        // Fill in IPs
        combinedEnv = combinedEnv.mapValues({ value in
            containerIps[value] ?? value
        })

        // Resolve __SERVICE_HOST__ and __SERVICE_PORT__ placeholders
        let knownServiceNames = Array(dockerCompose.services.keys)
        combinedEnv = combinedEnv.mapValues { value in
            Self.resolveServicePlaceholder(value, containerIps: containerIps, containerPorts: containerPorts, knownServiceNames: knownServiceNames)
        }

        // Build the `container run` argument list using the standardized helper
        let runCommandArgs = try Self.makeRunArgs(
            service: service,
            serviceName: serviceName,
            image: imageToRun,
            dockerCompose: dockerCompose,
            projectName: projectName,
            detach: detach,
            cwd: cwd,
            environmentVariables: combinedEnv
        )

        // Extract container name for status checks (consistent with makeRunArgs logic)
        let containerName = service.container_name ?? "\(projectName)-\(serviceName)"
        if containerName.count > 63 {
            print("⚠️  Warning: Container name '\(containerName)' is \(containerName.count) characters long.".yellow)
            print("   macOS Virtualization.framework has a hard limit of 63 characters for container labels.".yellow)
            print("   Please shorten your service names or project directory name to prevent 'Invalid argument' errors.".yellow)
        }

            guard var serviceColor = Self.availableContainerConsoleColors.randomElement() else {
                throw ContainerRunError("No available colors for service console output")
            }

            if Array(Set(containerConsoleColors.values)).sorted(by: { $0.rawValue < $1.rawValue }) != Self.availableContainerConsoleColors.sorted(by: { $0.rawValue < $1.rawValue }) {
                while containerConsoleColors.values.contains(serviceColor) {
                    guard let newColor = Self.availableContainerConsoleColors.randomElement() else {
                        break // Keep current color if no more available
                    }
                    serviceColor = newColor
                }
            }

        self.containerConsoleColors[serviceName] = serviceColor

      // Check if container already exists
      if let existingContainer = try? await ClientContainer.get(id: containerName) {
          // Recovery mode logic
          if recover {
              // Handle different container states in recovery mode
              switch existingContainer.status {
case .running:
                    print("[RECOVER] Container '\(containerName)' is already running - checking image...")

                    // Check if image needs to be pulled (M-5: --recover image re-pull)
                    // Even in recover mode, we should ensure the image is available locally
                    // in case it was pruned or never pulled on this host
                    if let image = service.image {
                        try await pullImage(image, platform: service.platform, scheme: service.scheme)
                    }

                    // External Dependency Health-Gating: Record this service as externally present
                    // so that dependent services skip their service_healthy wait (crash recovery).
                    externallyPresentServices.insert(serviceName)

                    // Check for configuration drift
                    if let driftWarnings = checkContainerDrift(container: existingContainer, service: service, expectedImage: imageToRun, env: combinedEnv), !driftWarnings.isEmpty {
                        for warning in driftWarnings {
                            print("⚠️ [DRIFT WARNING] Container '\(containerName)': \(warning)")
                        }
                    }

                    try await updateEnvironmentWithServiceIP(serviceName, containerName: containerName, ports: service.ports)
                    print("[RECOVER] Container '\(containerName)' kept running (image pulled if needed)")
                    return
                  
case .stopped:
                    print("[RECOVER] Container '\(containerName)' is stopped - checking image...")

                    // Pull image in recover mode if available (M-5: --recover image re-pull)
                    // Ensures the image exists locally before attempting to start
                    if let image = service.image {
                        try await pullImage(image, platform: service.platform, scheme: service.scheme)
                    }

                    // Check for configuration drift before starting
                    if let driftWarnings = checkContainerDrift(container: existingContainer, service: service, expectedImage: imageToRun, env: combinedEnv), !driftWarnings.isEmpty {
                        for warning in driftWarnings {
                            print("⚠️ [DRIFT WARNING] Container '\(containerName)': \(warning)")
                        }
                    }

                    print("[RECOVER] Starting container '\(containerName)'")
                    let startCommand = try Application.ContainerStart.parse([containerName])
                    try await startCommand.run()
                    try await waitUntilContainerIsRunning(containerName)
                    try await updateEnvironmentWithServiceIP(serviceName, containerName: containerName, ports: service.ports)
                    return
                  
              default:
                  // Zombie container states: creating, dead, restarting, etc.
                  // These are invalid states for recovery - purge and recreate
                  print("[RECOVER] Container '\(containerName)' is in invalid state '\(existingContainer.status)' - purging zombie")
                  try await purgeZombieContainer(name: containerName)
                  // Fall through to create new container
              }
} else {
                // Non-recovery mode: Check health of pre-existing containers
                if existingContainer.status == .running {
                    print("[RECOVERY] Container '\(containerName)' is already running — verifying health before proceeding")
                    // Verify the running container is healthy before allowing dependents to start.
                    // This ensures health gates work correctly for pre-existing containers.
                    if let healthcheck = service.healthcheck {
                        do {
                            try await waitForHealthy(
                                containerName: containerName,
                                dependencyName: serviceName,
                                healthcheck: healthcheck
                            )
                            print("[RECOVERY] Container '\(containerName)' passed health check")
                        } catch {
                            print("[RECOVERY] Container '\(containerName)' failed health check: \(error)")
                            throw ComposeError.healthCheckFailed(serviceName, "Pre-existing container failed health check: \(error)")
                        }
                    }
                    try await updateEnvironmentWithServiceIP(serviceName, containerName: containerName, ports: service.ports)
                    return
                } else {
                  // Container exists but is not running
                  if noRecreate {
                      print("Container '\(containerName)' exists with status: \(existingContainer.status). Not recreating (--no-recreate).")
                      return
                  }
                  print("Container '\(containerName)' exists with status: \(existingContainer.status). Starting it...")
                  let startCommand = try Application.ContainerStart.parse([containerName])
                  try await startCommand.run()
                  try await waitUntilContainerIsRunning(containerName)
                  try await updateEnvironmentWithServiceIP(serviceName, containerName: containerName, ports: service.ports)
                  return
              }
          }
      }
      
      // Container doesn't exist - create new
      if recover {
          print("[RECOVER] Creating container '\(containerName)' - not found")
      }

      // Start container and capture result with PID for peer verification
      let cwd = self.cwd // Capture before Task
      let containerTask: Task<StreamCommandResult, Error> = Task {
        @Sendable
        func handleOutput(_ output: String) {
          print("\(serviceName): \(output)")
        }

        print("\nStarting service: \(serviceName)")
        print("Starting \(serviceName)")
        print("----------------------------------------\n")
        // Use streamCommandWithPID to capture process identifier for Phase 5 verification
        let result = try await ContainerComposeCore.streamCommandWithPID("container", args: ["run"] + runCommandArgs, cwd: cwd, onStdout: handleOutput, onStderr: handleOutput)

        // If this task was cancelled while waiting, clean up the container
        if Task.isCancelled {
          let _ = try? await ContainerComposeCore.streamCommand("container", args: ["stop", containerName], cwd: cwd, onStdout: { _ in }, onStderr: { _ in })
          throw CancellationError()
        }

        return result
      }

      // Wait for container to start and validate it succeeded
      do {
        let commandResult = try await containerTask.value
        guard commandResult.exitCode == 0 else {
          throw ContainerRunError("Container run failed with exit code \(commandResult.exitCode)")
        }
        // Capture PID and register with RelayManager for CID/PID verification
        let containerPID = commandResult.processIdentifier
        await RelayManager.shared.registerTargetPID(containerPID, forService: serviceName)
        try await waitUntilContainerIsRunning(containerName)
        try await updateEnvironmentWithServiceIP(serviceName, containerName: containerName, ports: service.ports)
      } catch {
        print("Error starting service \(serviceName): \(error)")
        throw error
      }
    }

/// Configuration for retry behavior in pullImage.
    private struct PullRetryConfig {
        let maxRetries: Int
        let baseDelay: TimeInterval
        static let `default` = PullRetryConfig(maxRetries: 3, baseDelay: 5.0)
    }

    /// Checks if an error from image pull is transient (retryable).
    /// - Parameter error: The error to check.
    /// - Returns: True if the error is transient and should be retried.
    private func isTransientPullError(_ error: Error) -> Bool {
        let errorString = String(describing: error).lowercased()
        let errorMessage = (error as? LocalizedError)?.errorDescription?.lowercased() ?? errorString

        // Transient network errors
        let transientPatterns = [
            "timeout",
            "timed out",
            "connection reset",
            "connection refused",
            "no route to host",
            "network is unreachable",
            "tls handshake error",
            "temporary failure",
            "server error",  // 5xx
            "500",
            "502",
            "503",
            "504",
            "gateway",
            "dns",
            "unresolved",
            "no such host",
        ]

        // Check for transient patterns
        for pattern in transientPatterns {
            if errorString.contains(pattern) || errorMessage.contains(pattern) {
                return true
            }
        }

        // Check for URLError transient codes
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .dnsLookupFailed,
                 .resourceUnavailable,
                 .badServerResponse:
                return true
            default:
                return false
            }
        }

        return false
    }

    /// Pulls an image from the registry with retry logic for transient failures.
    /// - Parameters:
    ///   - imageName: The name of the image to pull.
    ///   - platform: Optional platform specifier (e.g., "linux/arm64").
/// - scheme: Optional registry scheme override.
    /// - retryConfig: Optional retry configuration (defaults to 3 retries, 5s base delay).
    /// - timeoutSeconds: Maximum time to wait for pull operation (defaults to 300s = 5 minutes).
    private func pullImage(
        _ imageName: String,
        platform: String?,
        scheme: String? = nil,
        retryConfig: PullRetryConfig = .default,
        timeoutSeconds: TimeInterval = 300
    ) async throws {
        let imageList = try await ClientImage.list()
        guard !imageList.contains(where: { $0.description.reference.components(separatedBy: "/").last == imageName }) else {
            return
        }

        print("Pulling Image \(imageName)...")

        var commands = [
            imageName
        ]

        if let scheme {
            commands.append(contentsOf: ["--scheme", scheme])
        }

        if let platform {
            commands.append(contentsOf: ["--platform", platform])
        }

        var lastError: Error?
        for attempt in 1...retryConfig.maxRetries {
            do {
                let pullCommands = commands + logging.passThroughCommands()
                try await withTimeout(seconds: timeoutSeconds, operation: {
                    try await Self.runImagePullWithSchemeFallback(pullCommands: pullCommands, imageName: imageName, scheme: scheme)
                })
                print("Successfully pulled image \(imageName)")
                return
            } catch {
                lastError = error
                if attempt < retryConfig.maxRetries {
                    let delay = retryConfig.baseDelay * pow(2.0, Double(attempt - 1))
                    print("Image pull failed: \(error). Retrying in \(delay)s (attempt \(attempt)/\(retryConfig.maxRetries))...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    print("Image pull failed after \(retryConfig.maxRetries) attempts: \(error)")
                    throw ImagePullError("Failed to pull image '\(imageName)' after \(retryConfig.maxRetries) attempts: \(error)", isTransient: false)
                }
            }
        }
        throw ImagePullError("Failed to pull image '\(imageName)' after \(retryConfig.maxRetries) attempts", isTransient: true)
    }

    private static func runImagePullWithSchemeFallback(pullCommands: [String], imageName: String, scheme: String?) async throws {
        do {
            let imagePull = try Application.ImagePull.parse(pullCommands)
            try await imagePull.run()
        } catch {
            if let scheme = scheme, Self.detectUnknownOptionError(error) {
                print("⚠️  Warning: Apple Container runtime does not support '--scheme \(scheme)' flag.")
                print("   Pulling image without scheme override...")
                var fallbackCommands = pullCommands.filter { $0 != "--scheme" && (pullCommands.firstIndex(of: $0).map { pullCommands[$0 + 1] == scheme } ?? false) == false }
                fallbackCommands = fallbackCommands.filter { $0 != scheme }
                let fallbackPull = try Application.ImagePull.parse(fallbackCommands)
                try await fallbackPull.run()
            } else {
                throw error
            }
        }
    }

    private static func detectUnknownOptionError(_ error: Error) -> Bool {
        let errorString = String(describing: error)
        return errorString.contains("unknownOption") || errorString.contains("unknown option") || errorString.contains("unrecognized option") || errorString.contains("未知的选项")
    }

    private static func isSchemeUnsupportedError(_ error: Error, scheme: String?) -> Bool {
        guard scheme != nil else { return false }
        return Self.detectUnknownOptionError(error)
    }

    /// Builds Docker Service
    ///
    /// - Parameters:
    ///   - buildConfig: The configuration for the build
    ///   - service: The service you would like to build
    ///   - serviceName: The fallback name for the image
    ///
    /// - Returns: Image Name (`String`)
    private func buildService(_ buildConfig: Build, for service: Service, serviceName: String) async throws -> String {
        // Determine image tag for built image
        let imageToRun = service.image ?? "\(serviceName):latest"
        let imageList = try await ClientImage.list()
        if !rebuild, imageList.contains(where: { $0.description.reference.components(separatedBy: "/").last == imageToRun }) {
            return imageToRun
        }

        // Build command arguments
        var commands = ["\(self.cwd)/\(buildConfig.context)"]
        
        // Add build arguments
        for (key, value) in buildConfig.args ?? [:] {
            commands.append(contentsOf: ["--build-arg", "\(key)=\(try? resolveVariable(value, with: environmentVariables) ?? value)"])
        }
        
        // Add Dockerfile path
        commands.append(contentsOf: ["--file", "\(self.cwd)/\(buildConfig.dockerfile ?? "Dockerfile")"])

    // Add target stage for multi-stage builds
    if let target = buildConfig.target {
        commands.append(contentsOf: ["--target", target])
    }

    // Add build secrets (Apple Container 0.11.0+)
        for secret in buildConfig.secrets ?? [] {
            if let env = secret.env {
                commands.append(contentsOf: ["--secret", "id=\(secret.id),env=\(env)"])
            } else if let src = secret.src {
                commands.append(contentsOf: ["--secret", "id=\(secret.id),src=\(self.cwd)/\(src)"])
            }
        }

        // Add caching options
        if noCache {
            commands.append("--no-cache")
        }
        
        // Add platform (Apple Container 0.11.0+ natively supports CONTAINER_DEFAULT_PLATFORM env var)
        // Only pass --platform if service.platform is explicitly set
        if let platform = service.platform {
            commands.append(contentsOf: ["--platform", platform])
        }
        // Otherwise let upstream handle CONTAINER_DEFAULT_PLATFORM or use defaults
        
        // Add image name
        commands.append(contentsOf: ["--tag", imageToRun])
        
        // Add CPU & Memory with validation
        let cpuString = service.deploy?.resources?.limits?.cpus ?? "2"
        guard let cpuCount = Int64(cpuString) else {
            throw ComposeError.invalidResourceConfig("Invalid CPU count '\(cpuString)' for service '\(serviceName)'. Expected numeric value.")
        }
        let memoryLimit = service.deploy?.resources?.limits?.memory ?? "2048MB"
        commands.append(contentsOf: ["--cpus", "\(cpuCount)"])
        commands.append(contentsOf: ["--memory", memoryLimit])

        let buildCommand = try Application.BuildCommand.parse(commands)
        print("\n----------------------------------------")
        print("Building image for service: \(serviceName) (Tag: \(imageToRun))")
        print("Running: container build \(commands.joined(separator: " "))")
        try buildCommand.validate()
        try await buildCommand.run()
        print("Image build for \(serviceName) completed.")
        print("----------------------------------------")

        return imageToRun
    }
    
    /// Normalizes an image reference by stripping common registry prefixes.
    /// Converts "docker.io/library/nginx:alpine" -> "nginx:alpine", "docker.io/nginx" -> "nginx"
    private func normalizeImageRef(_ image: String) -> String {
        let prefixes = ["docker.io/library/", "docker.io/"]
        for prefix in prefixes {
            if image.hasPrefix(prefix) {
                return String(image.dropFirst(prefix.count))
            }
        }
        return image
    }

    /// Check container configuration drift
    /// Returns array of warning messages if configuration differs from compose.yml
    private func checkContainerDrift(container: ClientContainer, service: Service, expectedImage: String, env: [String: String]) -> [String]? {
        var warnings: [String] = []
        
        // Check image drift (normalize both sides to handle docker.io/library/ prefix)
        let containerImage = normalizeImageRef(container.configuration.image.reference)
        let normalizedExpected = normalizeImageRef(expectedImage)
        if containerImage != normalizedExpected {
            warnings.append("Image changed from \(expectedImage) to \(container.configuration.image.reference)")
        }
        
        // Check environment drift (basic check - just compare keys)
        let containerEnvArray = container.configuration.initProcess.environment
        let containerEnvKeys = Set(containerEnvArray.compactMap { $0.components(separatedBy: "=").first })
        let expectedEnvKeys = Set(env.keys)
        let addedKeys = containerEnvKeys.subtracting(expectedEnvKeys)
        let removedKeys = expectedEnvKeys.subtracting(containerEnvKeys)
        
        if !addedKeys.isEmpty {
            warnings.append("Environment keys added: \(addedKeys.sorted().joined(separator: ", "))")
        }
        if !removedKeys.isEmpty {
            warnings.append("Environment keys removed: \(removedKeys.sorted().joined(separator: ", "))")
        }
        
        return warnings.isEmpty ? nil : warnings
    }
    
    /// Purge a zombie container (stuck in invalid state)
    private func purgeZombieContainer(name: String) async throws {
        print("[RECOVER] Removing zombie container '\(name)'")
        try await ContainerComposeCore.streamCommand(
            "container",
            args: ["rm", "-f", name],
            cwd: cwd,
            onStdout: { _ in },
            onStderr: { output in
                print("⚠️  container rm warning: \(output)")
            }
        )
    }

}

// MARK: CommandLine Functions

extension ComposeUp {

    /// Helper for building the `container run` argument list for a service. Used by tests.
    public static func makeRunArgs(service: Service, serviceName: String, image: String?, dockerCompose: DockerCompose, projectName: String, detach: Bool, cwd: String, environmentVariables: [String: String]) throws -> [String] {
        var runArgs: [String] = []

        // Add detach flag if specified
        if detach {
            runArgs.append("-d")
        }

        // Determine container name
        let containerName: String
        if let explicit = service.container_name {
            containerName = explicit
        } else {
            containerName = "\(projectName)-\(serviceName)"
        }
        runArgs.append("--name")
        runArgs.append(containerName)

        // Add registry scheme override (Apple Container extension)
        if let scheme = service.scheme {
            runArgs.append("--scheme")
            runArgs.append(scheme)
        }

        // Map restart policy if present
        if let restart = service.restart {
            let mappedRestart: String
            switch restart {
            case "no":
                mappedRestart = "no"
            case "always", "unless-stopped":
                mappedRestart = "always"
            case "on-failure":
                mappedRestart = "on-failure"
            default:
                mappedRestart = restart // Pass through any other values as-is
            }
            runArgs.append("--restart")
            runArgs.append(mappedRestart)
        }

        // Map runtime flag if present
        if let runtime = service.runtime {
            runArgs.append("--runtime")
            runArgs.append(runtime)
        }

        // Map DNS servers if present (supports array)
        if let dnsServers = service.dns {
            for dns in dnsServers {
                runArgs.append("--dns")
                runArgs.append(dns)
            }
        }

        // Map dns search domains if present (supports array)
        if let dnsSearches = service.dns_search {
            for dnsSearch in dnsSearches {
                runArgs.append("--dns-search")
                runArgs.append(dnsSearch)
            }
        }

        // Map init flag if present (support both explicit Bool and optional presence)
        // Note: Specifying init_image also implies --init
        if service.`init` == true || service.init_image != nil {
            runArgs.append("--init")
        }

        // Map init-image if present (must be passed before image name)
        if let initImage = service.init_image {
            runArgs.append("--init-image")
            runArgs.append(initImage)
        }

        // Map user if present
        if let user = service.user {
            runArgs.append("--user")
            runArgs.append(user)
        }

        // Map hostname if present
        if let hostname = service.hostname {
            runArgs.append("--hostname")
            runArgs.append(hostname)
        }

        // Map working directory if present
        if let workingDir = service.working_dir {
            runArgs.append("--workdir")
            runArgs.append(workingDir)
        }

        // Map privileged flag if present
        if service.privileged == true {
            runArgs.append("--privileged")
        }

        // Map read-only flag if present
        if service.read_only == true {
            runArgs.append("--read-only")
        }

        // Map networks if present
        if let networks = service.networks {
            for network in networks {
                runArgs.append("--network")
                runArgs.append(network)
            }
        }

        // Map tty flag if present
        if service.tty == true {
            runArgs.append("-t")
        }

        // Map stdin_open flag if present
        if service.stdin_open == true {
            runArgs.append("-i")
        }

// Map service volumes to -v flags (bind mounts)
        if let volumes = service.volumes {
            let fileManager = FileManager.default
            for volume in volumes {
                let resolvedVolume = try resolveVariable(volume, with: environmentVariables)
                
                // Parse the volume string: source:destination[:mode]
                let components = resolvedVolume.split(separator: ":", maxSplits: 2).map(String.init)
                guard components.count >= 2 else {
                    print("Warning: Volume entry '\(resolvedVolume)' has an invalid format (expected 'source:destination'). Skipping.")
                    continue
                }
                
                let source = components[0]
                let destination = components[1]
                
                // Check for virtiofs database path warnings (Phase 4)
                checkVirtiofsDatabaseWarnings(destination: destination, serviceName: serviceName)
                
                // Check if the source looks like a host path (contains '/' or starts with '.')
                if source.contains("/") || source.starts(with: ".") || source.starts(with: "..") {
                    // Bind mount (local path to container path)
                    let fullHostPath = (source.starts(with: "/") || source.starts(with: "~")) ? source : (cwd + "/" + source)

                    // Resolve to canonical path and validate against traversal
                    let resolvedHostPath = (fullHostPath as NSString).standardizingPath
                    let canonicalCwd = (cwd as NSString).standardizingPath

                    guard resolvedHostPath.hasPrefix(canonicalCwd + "/") || resolvedHostPath == canonicalCwd else {
                        print("Warning: Volume source '\(source)' resolves to '\(resolvedHostPath)' which is outside the project directory '\(canonicalCwd)'. Skipping for security.")
                        continue
                    }

var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: fullHostPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    runArgs.append("-v")
                    runArgs.append("\(source):\(destination)")
                } else {
                    // File mount: Apple Container runtime supports file mounts
                    // No need to skip - pass through to container CLI
                    runArgs.append("-v")
                    runArgs.append("\(source):\(destination)")
                    print("Info: Mounting file '\(source)' to '\(destination)'")
                }
            } else {
                        // Try to create the directory
                        do {
                            try fileManager.createDirectory(atPath: fullHostPath, withIntermediateDirectories: true, attributes: nil)
                            print("Info: Created missing host directory for volume: \(fullHostPath)")
                            runArgs.append("-v")
                            runArgs.append("\(source):\(destination)")
                        } catch {
                            print("Error: Could not create host directory '\(fullHostPath)' for volume '\(resolvedVolume)': \(error.localizedDescription). Skipping this volume.")
                        }
                    }
                } else {
                    // Named volume reference - map to ~/.containers/Volumes/{projectName}/{source}
                    let volumeUrl = URL.homeDirectory.appending(path: ".containers/Volumes/\(projectName)/\(source)")
                    let volumePath = volumeUrl.path(percentEncoded: false)

                    print("Warning: Volume source '\(source)' appears to be a named volume reference. Linking to \(volumePath) instead.")
                    do {
                        try fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true, attributes: nil)
                        runArgs.append("-v")
                        runArgs.append("\(volumePath):\(destination)")
                    } catch {
                        print("Error: Could not create volume directory '\(volumePath)': \(error.localizedDescription). Skipping this volume.")
                    }
                }
            }
        }

        // Map CPU and memory limits from deploy.resources
    if let deploy = service.deploy, let resources = deploy.resources {
      if let limits = resources.limits {
        if let cpus = limits.cpus {
          runArgs.append("--cpus")
          runArgs.append(cpus)
        }
        if let memory = limits.memory {
          runArgs.append("--memory")
          runArgs.append(memory)
        }
      }
    }

    // Map environment variables
    for (key, value) in environmentVariables {
      runArgs.append("--env")
      runArgs.append("\(key)=\(value)")
    }

        // Map port mappings if present (resolve environment variables in port specs)
        if let ports = service.ports {
            for portMapping in ports {
                runArgs.append("--publish")
                runArgs.append(try resolveVariable(portMapping, with: environmentVariables))
            }
        }

    // Ensure entrypoint flag is placed before the image name when provided
        let imageToRun = image ?? service.image ?? "\(serviceName):latest"
        if let entrypointParts = service.entrypoint, let entrypointCmd = entrypointParts.first {
            runArgs.append("--entrypoint")
            runArgs.append(entrypointCmd)
            // image follows flags
            runArgs.append(imageToRun)
            // append any remaining entrypoint args or command after image
            if entrypointParts.count > 1 {
                runArgs.append(contentsOf: entrypointParts.dropFirst())
            } else if let commandParts = service.command {
                runArgs.append(contentsOf: commandParts)
            }
        } else {
            runArgs.append(imageToRun)
            if let commandParts = service.command {
                runArgs.append(contentsOf: commandParts)
            }
        }

        return runArgs
    }

    /// Runs a command, streams stdout and stderr via closures, and completes when the process exits.
    ///
    /// - Parameters:
    ///   - command: The name of the command to run (e.g., `"container"`).
    ///   - args: Command-line arguments to pass to the command.
    ///   - onStdout: Closure called with streamed stdout data.
    ///   - onStderr: Closure called with streamed stderr data.
    /// - Returns: The process's exit code.
    /// - Throws: If the process fails to launch.
    @discardableResult
    func streamCommand(
        _ command: String,
        args: [String] = [],
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

            process.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]) { _, new in new }

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

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
                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
