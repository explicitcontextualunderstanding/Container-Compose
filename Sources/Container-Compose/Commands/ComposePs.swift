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

import ArgumentParser
import ContainerAPIClient
import ContainerizationExtras
import Foundation
import Yams

public struct ComposePs: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "ps",
        abstract: "List containers in a compose project"
    )

    @Argument(help: "Service name to filter (optional, lists all if not specified)")
    var service: String?

    @Option(name: [.customShort("f"), .customLong("file")], help: "Path to docker-compose.yml file")
    var file: String?

    @Option(name: .long, help: "Working directory")
    var cwd: String?

    @Option(name: .long, help: "Output format (table or json)")
    var format: PsFormat?

    @Flag(name: .long, help: "Output in JSON format (shorthand for --format json)")
    var json: Bool = false

    private var workingDir: String { cwd ?? FileManager.default.currentDirectoryPath }

    // MARK: - Data Model

    public enum PsState: String, Codable, Sendable {
        case running
        case stopped
        case stopping
        case unknown
        case missing
    }

    public struct PsStatus: Codable, Sendable {
        public let service: String
        public let container: String
        public let state: PsState
        public let id: String?
        public let ip: String?
        public let ports: [String]?
        public let started: Date?

        public init(service: String, container: String, state: PsState, id: String?, ip: String?, ports: [String]?, started: Date?) {
            self.service = service
            self.container = container
            self.state = state
            self.id = id
            self.ip = ip
            self.ports = ports
            self.started = started
        }
    }

    public enum PsFormat: String, EnumerableFlag, ExpressibleByArgument, Sendable {
        case table
        case json
    }

    public struct ContainerInfo: Sendable {
        public let name: String      // container name (matches compose naming)
        public let id: String        // full container ID (may be different from name)
        public let state: PsState
        public let ip: String?
        public let ports: [String]
        public let startedDate: Date?

        public init(name: String, id: String, state: PsState, ip: String?, ports: [String], startedDate: Date?) {
            self.name = name
            self.id = id
            self.state = state
            self.ip = ip
            self.ports = ports
            self.startedDate = startedDate
        }
    }

    // MARK: - Run (Cycle 4)

    public mutating func run() async throws {
        let workingDir = cwd ?? FileManager.default.currentDirectoryPath

        // Discovery and loading via centralized Loader
        let composePath: String
        if let filePath = file {
            composePath = filePath.hasPrefix("/") ? filePath : "\(workingDir)/\(filePath)"
        } else if let discovered = ConfigLoader.discoverPath(in: workingDir) {
            composePath = discovered
        } else {
            throw ComposePsError.composeFileNotFound(workingDir)
        }

        let dockerCompose = try ConfigLoader.load(path: composePath, environment: [:])

        let projectName: String
        if let name = dockerCompose.name {
            projectName = name
        } else {
            projectName = try deriveProjectName(cwd: workingDir)
        }

        // Build services list
        var services: [(name: String, service: Service)] = []
        for (serviceName, serviceOpt) in dockerCompose.services {
            guard let service = serviceOpt else { continue }
            services.append((serviceName, service))
        }

        // Validate service filter
        if let filter = service {
            guard services.contains(where: { $0.name == filter }) else {
                throw ComposePsError.serviceNotFound(filter)
            }
        }

        // List all containers and convert to ContainerInfo
        let allContainers = try await ClientContainer.list()
        let containerInfos: [ContainerInfo] = allContainers.map { container in
            let ip: String? = container.networks.first.map { String(describing: $0.ipv4Address).split(separator: "/").first.map(String.init) ?? String(describing: $0.ipv4Address) }
            let ports: [String] = container.configuration.publishedPorts.map { port in
                let hostAddr = String(describing: port.hostAddress)
                return "\(hostAddr):\(port.hostPort)->\(port.containerPort)/\(port.proto)"
            }
            let state: ComposePs.PsState = switch container.status {
            case .running: .running
            case .stopped: .stopped
            case .stopping: .stopping
            default: .unknown
            }
            return ContainerInfo(
                name: container.configuration.id,
                id: container.configuration.id,
                state: state,
                ip: ip,
                ports: ports,
                startedDate: container.startedDate
            )
        }

        let statuses = ComposePs.matchServicesToContainers(
            services: services,
            projectName: projectName,
            containers: containerInfos,
            serviceFilter: service
        )

        // Output
        if json || format == .json {
            let output = try ComposePs.formatPsJSON(statuses)
            print(output)
        } else {
            print(ComposePs.formatPsTable(statuses))
            print(ComposePs.formatSummary(statuses))
        }
    }

    /// Static helper for tests: list services and return PsStatus array
    public static func listServices(cwd: String, serviceFilter: String? = nil) async throws -> [PsStatus] {
        guard let composePath = ConfigLoader.discoverPath(in: cwd) else {
            throw ComposePsError.composeFileNotFound(cwd)
        }
        let dockerCompose = try ConfigLoader.load(path: composePath, environment: [:])

        let projectName: String
        if let name = dockerCompose.name {
            projectName = name
        } else {
            projectName = try deriveProjectName(cwd: cwd)
        }

        var services: [(name: String, service: Service)] = []
        for (serviceName, serviceOpt) in dockerCompose.services {
            guard let service = serviceOpt else { continue }
            services.append((serviceName, service))
        }

        let allContainers = try await ClientContainer.list()
        let containerInfos: [ContainerInfo] = allContainers.map { container in
            let ip: String? = container.networks.first.map { String(describing: $0.ipv4Address).split(separator: "/").first.map(String.init) ?? String(describing: $0.ipv4Address) }
            let ports: [String] = container.configuration.publishedPorts.map { port in
                let hostAddr = String(describing: port.hostAddress)
                return "\(hostAddr):\(port.hostPort)->\(port.containerPort)/\(port.proto)"
            }
            let state: ComposePs.PsState = switch container.status {
            case .running: .running
            case .stopped: .stopped
            case .stopping: .stopping
            default: .unknown
            }
            return ContainerInfo(
                name: container.configuration.id,
                id: container.configuration.id,
                state: state,
                ip: ip,
                ports: ports,
                startedDate: container.startedDate
            )
        }

        return matchServicesToContainers(services: services, projectName: projectName, containers: containerInfos, serviceFilter: serviceFilter)
    }

    // MARK: - Matching Logic (Cycle 2)

    public static func matchServicesToContainers(
        services: [(name: String, service: Service)],
        projectName: String,
        containers: [ContainerInfo],
        serviceFilter: String?
    ) -> [PsStatus] {
        // Build lookup by container name — also index by stripped name
        // Apple Container adds CCT_<runId>_ prefix (e.g., CCT_t97107_test_...-nginx)
        let containerMap = Dictionary(uniqueKeysWithValues: containers.map { ($0.name, $0) })
        var strippedMap: [String: ContainerInfo] = [:]
        for container in containers {
            let name = container.name
            // Strip CCT_orphan_ prefix
            if name.hasPrefix("CCT_orphan_") {
                strippedMap[String(name.dropFirst("CCT_orphan_".count))] = container
            }
            // Strip CCT_<runId>_ prefix (CCT_ followed by non-underscore chars then _)
            if name.hasPrefix("CCT_"), let secondUnderscore = name.dropFirst(4).firstIndex(of: "_") {
                let stripped = String(name[name.index(after: secondUnderscore)...])
                strippedMap[stripped] = container
            }
        }

        return services.compactMap { (serviceName, service) -> PsStatus? in
            // Apply service filter
            if let filter = serviceFilter {
                guard serviceName == filter else { return nil }
            }

      // Determine expected container name
      let containerName = service.container_name ?? "\(projectName)-\(serviceName)"

      // Try exact match, then stripped prefix matches
      let actualContainer: ContainerInfo? = containerMap[containerName]
        ?? strippedMap[containerName]
        ?? containerMap["CCT_orphan_\(containerName)"]

      guard let container = actualContainer else {
        // No matching container → missing
        return PsStatus(
          service: serviceName,
          container: containerName,
          state: .missing,
          id: nil, ip: nil, ports: nil, started: nil
        )
      }

            // Truncate ID to 12 chars
            let truncatedID = container.id.count > 12
                ? String(container.id.prefix(12))
                : (container.id.isEmpty ? nil : container.id)

            return PsStatus(
                service: serviceName,
                container: containerName,
                state: container.state,
                id: truncatedID,
                ip: container.ip,
                ports: container.ports.isEmpty ? nil : container.ports,
                started: container.startedDate
            )
        }
    }

    // MARK: - Formatting (Cycle 3)

    public static func formatPsTable(_ statuses: [PsStatus]) -> String {
        var lines: [String] = []

        // Header
        lines.append(String(format: "%-20@ %-12@ %-12@ %-18@ %-25@ %-10@",
            "SERVICE" as NSString, "STATE" as NSString, "ID" as NSString, "IP" as NSString, "PORTS" as NSString, "STARTED" as NSString))
        lines.append(String(repeating: "-", count: 97))

        // Data rows
        for status in statuses {
            let rawId = status.id ?? "-"
            let id = (rawId.count > 12 ? String(rawId.prefix(12)) : rawId) as NSString
            let ip = (status.ip ?? "-") as NSString
            let ports = (status.ports.map { $0.joined(separator: ", ") } ?? "-") as NSString
            let started = (status.started.map { formatRelativeTime($0) } ?? "-") as NSString
            lines.append(String(format: "%-20@ %-12@ %-12@ %-18@ %-25@ %-10@",
                status.service as NSString, status.state.rawValue as NSString, id, ip, ports, started))
        }

        return lines.joined(separator: "\n")
    }

    public static func formatSummary(_ statuses: [PsStatus]) -> String {
        let total = statuses.count
        let running = statuses.filter { $0.state == .running }.count
        let stopped = statuses.filter { $0.state == .stopped }.count
        let missing = statuses.filter { $0.state == .missing }.count

        var parts = ["\(running)/\(total) services running"]
        var extras: [String] = []
        if stopped > 0 { extras.append("\(stopped) stopped") }
        if missing > 0 { extras.append("\(missing) missing") }

        if !extras.isEmpty {
            parts.append("(\(extras.joined(separator: ", ")))")
        }
        return parts.joined(separator: " ")
    }

    public static func formatPsJSON(_ statuses: [PsStatus]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(statuses)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    public static func formatRelativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 0 { return "just now" }
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}

// MARK: - Error Types

public enum ComposePsError: Error, CustomStringConvertible {
    case serviceNotFound(String)
    case composeFileNotFound(String)

    public var description: String {
        switch self {
        case .serviceNotFound(let name):
            return "Service '\(name)' not found in compose file"
        case .composeFileNotFound(let cwd):
            return "No compose file found in \(cwd)"
        }
    }
}
