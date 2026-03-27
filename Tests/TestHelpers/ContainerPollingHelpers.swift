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

import ContainerAPIClient
import Foundation
import Testing

/// Errors thrown by container polling helpers
public enum ContainerPollingError: Error, CustomStringConvertible {
    case timeout(operation: String, container: String, waited: TimeInterval)
    case networkNotFound(container: String)
    case containerNotFound(id: String)

    public var description: String {
        switch self {
        case .timeout(let operation, let container, let waited):
            return "\(operation) timed out for container '\(container)' after \(waited)s"
        case .networkNotFound(let container):
            return "No networks found for container '\(container)'"
        case .containerNotFound(let id):
            return "Container '\(id)' not found"
        }
    }
}

/// Polling helpers for container runtime state verification
public struct ContainerPollingHelpers {

    /// Default polling interval (500ms)
    public static let defaultInterval: UInt64 = 500_000_000

    /// Default timeout (30 seconds)
    public static let defaultTimeout: TimeInterval = 30

    /// Waits for a container's networks to be populated by the runtime API.
    ///
    /// The Apple Container runtime populates networks asynchronously after container start.
    /// This helper polls until networks are available or timeout.
    ///
    /// - Parameters:
    ///   - containerId: The container ID to check
    ///   - timeout: Maximum time to wait (default: 30s)
    ///   - interval: Polling interval in nanoseconds (default: 500ms)
    /// - Returns: The container with populated networks
    /// - Throws: ContainerPollingError if timeout or container not found
    public static func waitForNetworks(
        containerId: String,
        timeout: TimeInterval = defaultTimeout,
        interval: UInt64 = defaultInterval
    ) async throws -> ClientContainer {
        let startTime = Date()
        let deadline = startTime.addingTimeInterval(timeout)

        while Date() < deadline {
            do {
                let container = try await ClientContainer.get(id: containerId)

                // Networks populated? Return immediately
                if !container.networks.isEmpty {
                    return container
                }

                // Container exists but networks not yet populated - keep polling
            } catch {
                // Container may not exist yet - keep polling
            }

            try await Task.sleep(nanoseconds: interval)
        }

        throw ContainerPollingError.timeout(
            operation: "waitForNetworks",
            container: containerId,
            waited: timeout
        )
    }

    /// Waits for all containers in a project to have their networks populated.
    ///
    /// - Parameters:
    ///   - projectName: The project name prefix to filter containers
    ///   - expectedCount: Number of containers expected (optional validation)
    ///   - timeout: Maximum time to wait per container
    /// - Returns: Array of containers with populated networks
    public static func waitForAllNetworks(
        projectName: String,
        expectedCount: Int? = nil,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> [ClientContainer] {
        // First wait for containers to exist
        let containers = try await waitForContainers(
            projectName: projectName,
            expectedCount: expectedCount,
            timeout: timeout
        )

        // Then wait for each to have networks
        var result: [ClientContainer] = []
        for container in containers {
            let updated = try await waitForNetworks(
                containerId: container.configuration.id,
                timeout: timeout
            )
            result.append(updated)
        }

        return result
    }

    /// Waits for containers matching a project name to exist.
    ///
    /// - Parameters:
    ///   - projectName: The project name prefix to filter
    ///   - expectedCount: Expected number of containers (nil = any count)
    ///   - timeout: Maximum time to wait
    ///   - interval: Polling interval
    /// - Returns: Array of matching containers
    public static func waitForContainers(
        projectName: String,
        expectedCount: Int? = nil,
        timeout: TimeInterval = defaultTimeout,
        interval: UInt64 = defaultInterval
    ) async throws -> [ClientContainer] {
        let startTime = Date()
        let deadline = startTime.addingTimeInterval(timeout)

        while Date() < deadline {
            let containers = try await ClientContainer.list()
                .filter { $0.configuration.id.contains(projectName) }

            if let expected = expectedCount {
                if containers.count == expected {
                    return containers
                }
            } else if !containers.isEmpty {
                return containers
            }

            try await Task.sleep(nanoseconds: interval)
        }

        let actualCount = try await ClientContainer.list()
            .filter { $0.configuration.id.contains(projectName) }
            .count

        let expectedStr = expectedCount.map(String.init) ?? "any"
        throw ContainerPollingError.timeout(
            operation: "waitForContainers(expected: \(expectedStr), found: \(actualCount))",
            container: projectName,
            waited: timeout
        )
    }

    /// Waits for a container to reach running status.
    ///
    /// - Parameters:
    ///   - containerId: Container ID to check
    ///   - timeout: Maximum time to wait
    /// - Returns: Running container
    public static func waitForRunning(
        containerId: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> ClientContainer {
        let startTime = Date()
        let deadline = startTime.addingTimeInterval(timeout)

        while Date() < deadline {
            do {
                let container = try await ClientContainer.get(id: containerId)
                // ContainerStatus is inferred from usage patterns in codebase
                if container.status.rawValue == "running" {
                    return container
                }
            } catch {
                // Container may not exist yet
            }

            try await Task.sleep(nanoseconds: defaultInterval)
        }

        throw ContainerPollingError.timeout(
            operation: "waitForRunning",
            container: containerId,
            waited: timeout
        )
    }
}

/// Swift Testing helpers for container assertions
public struct ContainerTestHelpers {

    /// Asserts that a container has at least one network, with descriptive failure.
    ///
    /// - Parameters:
    ///   - container: Container to check
    ///   - sourceLocation: Source location for test failure
    public static func assertHasNetworks(
        _ container: ClientContainer,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            !container.networks.isEmpty,
            "Container '\(container.configuration.id)' should have networks populated",
            sourceLocation: sourceLocation
        )
    }

    /// Gets the first IP address from a container's networks, or fails the test.
    ///
    /// - Parameters:
    ///   - container: Container with networks
    ///   - sourceLocation: Source location for test failure
    /// - Returns: IP address string
    public static func getIPAddress(
        from container: ClientContainer,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> String {
        // Networks are populated via ipv4Address property (ComposeUp.swift:258 pattern)
        // $0.ipv4Address is CIDRv4 (non-optional), access .address.description
        let ips = container.networks.compactMap { $0.ipv4Address.address.description }

        guard let firstIP = ips.first else {
            #expect(
                false,
                "Container '\(container.configuration.id)' has no network IPs. Networks: \(container.networks)",
                sourceLocation: sourceLocation
            )
            return ""
        }

        return firstIP
    }

    /// Asserts that a container is a member of a specific network by hostname.
    ///
    /// - Parameters:
    ///   - container: Container to check
    ///   - networkName: Expected network hostname
    ///   - sourceLocation: Source location for test failure
    public static func assertNetworkMembership(
        _ container: ClientContainer,
        network: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let hostnames = container.networks.map { $0.hostname }
        #expect(
            hostnames.contains(network),
            "Container '\(container.configuration.id)' should be on network '\(network)'. Found: \(hostnames)",
            sourceLocation: sourceLocation
        )
    }
}
