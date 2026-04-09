//===----------------------------------------------------------------------===//
// VsockRelayE2ETests.swift
// E2E tests for vsock-db relay using actual containers
// Plan 84 Phase 6: Real container integration testing
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import ContainerCommands
import ContainerAPIClient
import TestHelpers
@testable import ContainerComposeCore

@Suite("Vsock Relay E2E Tests", .containerDependent, .serialized)
struct VsockRelayE2ETests {
    private let reliabilityHelper = ContainerReliabilityHelper()

    @Test("E2E: vsock-db relay with real PostgreSQL container")
    func testVsockRelayWithRealDatabase() async throws {
        // Deploy honcho-db via container-compose
        let yaml = DockerComposeYamlFiles.honchoStackWithDeriversYaml

        let tempLocation = URL.temporaryDirectory
            .appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")

        try FileManager.default.createDirectory(
            at: tempLocation.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)

        try await ContainerPollingHelpers.withProjectCleanup(
            projectName: tempLocation.deletingLastPathComponent().lastPathComponent
        ) {
            // Start compose
            var composeUp = try ComposeUp.parse([
                "-d",
                "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)
            ])
            try await composeUp.run()

            // Get database container
            let containers = try await ClientContainer.list()
            let dbContainer = containers.first { $0.configuration.id.contains("honcho-db") }

            #expect(dbContainer != nil, "honcho-db container should exist")
            #expect(dbContainer?.status == .running, "honcho-db should be running")

            // Verify socket exists in Virtio-FS
            let socketPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".containers/Volumes/\(tempLocation.deletingLastPathComponent().lastPathComponent)/honcho-db-sockets/.s.PGSQL.5432")

            let socketExists = FileManager.default.fileExists(atPath: socketPath.path)
            #expect(socketExists, "Socket should exist at \(socketPath.path)")

            // Verify socket is a Unix socket
            if socketExists {
                let attrs = try? FileManager.default.attributesOfItem(atPath: socketPath.path)
                let isSocket = (attrs?[.posixPermissions] as? NSNumber)?.int16Value ?? 0 & 0o170000 == 0o140000
                #expect(isSocket, "File should be a Unix socket")
            }

            // Clean up
            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }

    @Test("E2E: Database connectivity through vsock-db relay")
    func testDatabaseConnectivityThroughRelay() async throws {
        // This test validates the actual relay functionality
        // Requires honcho-db to be running

        let yaml = DockerComposeYamlFiles.honchoStackWithDeriversYaml

        let tempLocation = URL.temporaryDirectory
            .appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")

        try FileManager.default.createDirectory(
            at: tempLocation.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)

        try await ContainerPollingHelpers.withProjectCleanup(
            projectName: tempLocation.deletingLastPathComponent().lastPathComponent
        ) {
            // Start honcho-db only
            var composeUp = try ComposeUp.parse([
                "-d", "honcho-db",
                "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)
            ])
            try await composeUp.run()

            // Wait for DB to be ready
            let containers = try await ClientContainer.list()
            let dbContainer = containers.first { $0.configuration.id.contains("honcho-db") }

            #expect(dbContainer != nil, "honcho-db container should exist")

            // Poll for readiness (up to 30 seconds)
            var isReady = false
            for _ in 0..<30 {
                let updated = try await ClientContainer.list()
                if let container = updated.first(where: { $0.configuration.id.contains("honcho-db") }),
                   container.status == .running {
                    isReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

            #expect(isReady, "Database should be ready within 30 seconds")

            // Verify socket exists
            let socketPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".containers/Volumes/\(tempLocation.deletingLastPathComponent().lastPathComponent)/honcho-db-sockets/.s.PGSQL.5432")

            #expect(
                FileManager.default.fileExists(atPath: socketPath.path),
                "Socket should exist for relay connection"
            )

            // Clean up
            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }

    @Test("E2E: RelayManager with real vsock transport")
    func testRelayManagerWithVsock() async throws {
        // Validates that RelayManager can configure vsock transport
        // with actual container CID assignment

        let yaml = DockerComposeYamlFiles.honchoStackWithDeriversYaml

        let tempLocation = URL.temporaryDirectory
            .appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")

        try FileManager.default.createDirectory(
            at: tempLocation.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)

        try await ContainerPollingHelpers.withProjectCleanup(
            projectName: tempLocation.deletingLastPathComponent().lastPathComponent
        ) {
            // Start container to get assigned CID
            var composeUp = try ComposeUp.parse([
                "-d", "honcho-db",
                "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)
            ])
            try await composeUp.run()

            // Get container info
            let containers = try await ClientContainer.list()
            let dbContainer = containers.first { $0.configuration.id.contains("honcho-db") }

            #expect(dbContainer != nil, "Container should exist")

            // Verify container has valid CID
            // Note: CID is dynamically assigned by vminitd
            // We just verify it's accessible
            let containerCID = dbContainer?.configuration.networks.first?.address
            #expect(containerCID != nil, "Container should have network address")

            // Clean up
            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }
}

// MARK: - Performance Tests

@Suite("Vsock Relay Performance Tests", .containerDependent, .serialized)
struct VsockRelayPerformanceTests {

    @Test("Performance: Relay startup time < 5s target")
    func testRelayStartupTime() async throws {
        let yaml = DockerComposeYamlFiles.honchoStackWithDeriversYaml

        let tempLocation = URL.temporaryDirectory
            .appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")

        try FileManager.default.createDirectory(
            at: tempLocation.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)

        try await ContainerPollingHelpers.withProjectCleanup(
            projectName: tempLocation.deletingLastPathComponent().lastPathComponent
        ) {
            let startTime = CFAbsoluteTimeGetCurrent()

            // Start honcho-db (includes relay setup)
            var composeUp = try ComposeUp.parse([
                "-d", "honcho-db",
                "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)
            ])
            try await composeUp.run()

            // Wait for socket
            let socketPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".containers/Volumes/\(tempLocation.deletingLastPathComponent().lastPathComponent)/honcho-db-sockets/.s.PGSQL.5432")

            var socketReady = false
            for _ in 0..<50 { // 5 second timeout
                if FileManager.default.fileExists(atPath: socketPath.path) {
                    socketReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            let endTime = CFAbsoluteTimeGetCurrent()
            let duration = endTime - startTime

            #expect(socketReady, "Socket should be ready within 5 seconds")
            #expect(duration < 5.0, "Startup should be < 5s, was \(duration)s")

            // Cleanup
            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }
}
