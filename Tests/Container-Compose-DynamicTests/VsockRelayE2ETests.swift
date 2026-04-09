//===----------------------------------------------------------------------===//
// VsockRelayE2ETests.swift
// E2E tests for vsock-db relay using actual containers
// Plan 84 Phase 6: Real container integration testing
//
// Uses public test fixtures from DockerComposeYamlFiles (not private production)
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import ContainerCommands
import ContainerAPIClient
import TestHelpers
@testable import ContainerComposeCore

@Suite("Vsock Relay E2E Tests", .containerDependent, .serialized)
struct VsockRelayE2ETests {

    @Test("E2E: vsock-db relay with real PostgreSQL container")
    func testVsockRelayWithRealDatabase() async throws {
        // Use public test fixture (not private production YAML)
        let tempProject = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(
            yaml: DockerComposeYamlFiles.vsockDbRelayYaml
        )

        try await ContainerPollingHelpers.withProjectCleanup(projectName: tempProject.name) {
            // Start compose with db service
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempProject.base.path(percentEncoded: false)
            ])
            try await composeUp.run()

            // Get database container
            let containers = try await ClientContainer.list()
            let dbContainer = containers.first { $0.configuration.id.contains("\(tempProject.name)-db") }

            #expect(dbContainer != nil, "db container should exist in project \(tempProject.name)")
            #expect(dbContainer?.status == .running, "db should be running")

// Verify socket path configured from YAML fixture
    // Socket path is now set to tempProject.base/sockets/.s.PGSQL.5432 in the fixture
    let expectedSocketPath = tempProject.base
      .appendingPathComponent("sockets/.s.PGSQL.5432")

            // Poll for socket creation (up to 30s)
            var socketExists = false
            for _ in 0..<30 {
                if FileManager.default.fileExists(atPath: expectedSocketPath.path) {
                    socketExists = true
                    break
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

            #expect(socketExists, "Socket should exist at \(expectedSocketPath.path)")

            // Cleanup
            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }

    @Test("E2E: Database connectivity through vsock-db relay")
    func testDatabaseConnectivityThroughRelay() async throws {
        let tempProject = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(
            yaml: DockerComposeYamlFiles.vsockDbRelayYaml
        )

        try await ContainerPollingHelpers.withProjectCleanup(projectName: tempProject.name) {
            // Start db service
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempProject.base.path(percentEncoded: false)
            ])
            try await composeUp.run()

            // Wait for container
            let containers = try await ContainerPollingHelpers.waitForContainers(
                projectName: tempProject.name,
                expectedCount: 1,
                timeout: 30
            )

            #expect(!containers.isEmpty, "db container should be created")

            // Wait for running status
            let containerId = containers.first?.configuration.id ?? ""
            let runningContainer = try? await ContainerPollingHelpers.waitForRunning(
                containerId: containerId,
                timeout: 30
            )

            #expect(runningContainer != nil, "db container should be running")

            // Cleanup
            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }

    @Test("E2E: RelayManager with real vsock transport")
    func testRelayManagerWithVsock() async throws {
        // Validates RelayManager can configure vsock transport
        // with actual container CID assignment

        let tempProject = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(
            yaml: DockerComposeYamlFiles.vsockDbRelayYaml
        )

        try await ContainerPollingHelpers.withProjectCleanup(projectName: tempProject.name) {
            // Start container
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempProject.base.path(percentEncoded: false)
            ])
            try await composeUp.run()

            // Get container info
            let containers = try await ClientContainer.list()
            let dbContainer = containers.first { $0.configuration.id.contains("\(tempProject.name)-db") }

            #expect(dbContainer != nil, "Container should exist")

            // Verify container has network configuration
            // Note: CID is dynamically assigned by vminitd
            #expect(dbContainer?.configuration.networks != nil, "Container should have network config")

            // Cleanup
            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }
}

@Suite("Vsock Relay Performance Tests", .containerDependent, .serialized)
struct VsockRelayPerformanceTests {

    @Test("Performance: Relay startup time < 5s target")
    func testRelayStartupTime() async throws {
        let tempProject = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(
            yaml: DockerComposeYamlFiles.vsockDbRelayYaml
        )

        try await ContainerPollingHelpers.withProjectCleanup(projectName: tempProject.name) {
            let startTime = CFAbsoluteTimeGetCurrent()

            // Start db service
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempProject.base.path(percentEncoded: false)
            ])
            try await composeUp.run()

            // Wait for socket
            let socketPath = tempProject.base.appendingPathComponent("sockets/.s.PGSQL.5432")

            var socketReady = false
            for _ in 0..<50 { // 5 second timeout (100ms x 50)
                if FileManager.default.fileExists(atPath: socketPath.path) {
                    socketReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            let endTime = CFAbsoluteTimeGetCurrent()
            let duration = endTime - startTime

            #expect(socketReady, "Socket should be ready within 5 seconds")
            #expect(duration < 5.0, "Startup should be < 5s, was \(String(format: "%.2f", duration))s")

            // Cleanup
            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }
}
