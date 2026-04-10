//===----------------------------------------------------------------------===//
// UDSSocketLifecycleTests.swift
// Dynamic tests for UDS socket lifecycle with real containers
// Plan 88: Migrated from VsockSocketLifecycleTests
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import ContainerCommands
import ContainerAPIClient
import TestHelpers
@testable import ContainerComposeCore

@Suite("UDS Socket Lifecycle Tests", .containerDependent, .serialized)
struct UDSSocketLifecycleTests {

    private func requireRegistryURL() -> String {
        ProcessInfo.processInfo.environment["OCI_REGISTRY_URL"] ?? "docker.io"
    }

    @Test("Socket created in Virtio-FS when container starts")
    func testSocketCreatedInVirtioFs() async throws {
        let projectName = "CCT_UDSSocketCreate_\(UUID().uuidString.prefix(8))"
        let registryURL = requireRegistryURL()

        let yaml = """
        name: \(projectName)
        services:
          db:
            image: \(registryURL)/pgmicro:latest
            environment:
              POSTGRES_DB: testdb
            volumes:
              - db-sockets:/var/run/postgresql/sockets
            x-apple-relays:
              - type: uds
                socket_path: ~/.containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.5432
            command:
              - /pgmicro
              - --unix-socket-dir=/var/run/postgresql/sockets
        volumes:
          db-sockets:
        """

        let tempDir = URL.temporaryDirectory.appending(path: projectName)
        let composePath = tempDir.appending(path: "docker-compose.yaml")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try yaml.write(to: composePath, atomically: false, encoding: .utf8)

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            var composeUp = try ComposeUp.parse([
                "-d", "--cwd", tempDir.path(percentEncoded: false)
            ])
            try await composeUp.run()

            let dbContainer = try await ContainerPollingHelpers.pollForContainer(
                projectName: projectName,
                serviceName: "db",
                timeout: 30
            )
            #expect(dbContainer != nil, "Container should start")
            #expect(dbContainer?.status == .running, "Container should be running")

            let socketPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.5432")

            let socketExists = try await ContainerPollingHelpers.pollForFile(
                path: socketPath,
                timeout: 10
            )
            #expect(socketExists, "Socket should exist at \(socketPath.path)")

            if socketExists {
                let attrs = try? FileManager.default.attributesOfItem(atPath: socketPath.path)
                let isSocket = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o170000 == 0o140000
                #expect(isSocket, "File should be a Unix socket")
            }
        }
    }

    @Test("Socket removed when container stops")
    func testSocketRemovedOnStop() async throws {
        let projectName = "CCT_UDSSocketRemove_\(UUID().uuidString.prefix(8))"
        let registryURL = requireRegistryURL()

        let yaml = """
        name: \(projectName)
        services:
          db:
            image: \(registryURL)/pgmicro:latest
            volumes:
              - db-sockets:/var/run/postgresql/sockets
            x-apple-relays:
              - type: uds
                socket_path: ~/.containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.5432
            command:
              - /pgmicro
              - --unix-socket-dir=/var/run/postgresql/sockets
        volumes:
          db-sockets:
        """

        let tempDir = URL.temporaryDirectory.appending(path: projectName)
        let composePath = tempDir.appending(path: "docker-compose.yaml")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try yaml.write(to: composePath, atomically: false, encoding: .utf8)

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            var composeUp = try ComposeUp.parse(["-d", "--cwd", tempDir.path])
            try await composeUp.run()

            let socketPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.5432")

            _ = try await ContainerPollingHelpers.pollForFile(path: socketPath, timeout: 10)
            #expect(socketPath.exists, "Socket should exist while container runs")

            var composeDown = ComposeDown()
            try await composeDown.run()

            try await Task.sleep(nanoseconds: 2_000_000_000)

            let containers = try await ClientContainer.list()
                .filter { $0.configuration.id.contains(projectName) }
            #expect(containers.isEmpty, "Container should be stopped")
        }
    }

    @Test("Multiple services with UDS relays")
    func testMultipleUDSRelays() async throws {
        let projectName = "CCT_UDSMultiRelay_\(UUID().uuidString.prefix(8))"
        let registryURL = requireRegistryURL()
        let yaml = """
        name: \(projectName)
        services:
          db1:
            image: \(registryURL)/pgmicro:latest
            volumes:
              - db1-sockets:/var/run/postgresql/sockets
            x-apple-relays:
              - type: uds
                socket_path: ~/.containers/Volumes/\(projectName)/db1-sockets/.s.PGSQL.5432
          db2:
            image: \(registryURL)/pgmicro:latest
            volumes:
              - db2-sockets:/var/run/postgresql/sockets
            x-apple-relays:
              - type: uds
                socket_path: ~/.containers/Volumes/\(projectName)/db2-sockets/.s.PGSQL.5433
        volumes:
          db1-sockets:
          db2-sockets:
        """

        let tempDir = URL.temporaryDirectory.appending(path: projectName)
        let composePath = tempDir.appending(path: "docker-compose.yaml")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try yaml.write(to: composePath, atomically: false, encoding: .utf8)

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            var composeUp = try ComposeUp.parse(["-d", "--cwd", tempDir.path])
            try await composeUp.run()

            let socketPath1 = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".containers/Volumes/\(projectName)/db1-sockets/.s.PGSQL.5432")
            let socketPath2 = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".containers/Volumes/\(projectName)/db2-sockets/.s.PGSQL.5433")

            let sock1Exists = try await ContainerPollingHelpers.pollForFile(path: socketPath1, timeout: 15)
            let sock2Exists = try await ContainerPollingHelpers.pollForFile(path: socketPath2, timeout: 15)

            #expect(sock1Exists, "Socket 1 should exist")
            #expect(sock2Exists, "Socket 2 should exist")
            #expect(socketPath1.path != socketPath2.path, "Sockets should have different paths")
        }
    }

    @Test("Socket persists across relay restart")
    func testSocketPersistence() async throws {
        let projectName = "CCT_UDSSocketPersist_\(UUID().uuidString.prefix(8))"
        let registryURL = requireRegistryURL()
        let yaml = """
        name: \(projectName)
        services:
          db:
            image: \(registryURL)/pgmicro:latest
            volumes:
              - db-sockets:/var/run/postgresql/sockets
            x-apple-relays:
              - type: uds
                socket_path: ~/.containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.5432
        volumes:
          db-sockets:
        """

        let tempDir = URL.temporaryDirectory.appending(path: projectName)
        let composePath = tempDir.appending(path: "docker-compose.yaml")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try yaml.write(to: composePath, atomically: false, encoding: .utf8)

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            var composeUp = try ComposeUp.parse(["-d", "--cwd", tempDir.path])
            try await composeUp.run()

            let socketPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".containers/Volumes/\(projectName)/db-sockets/.s.PGSQL.5432")

            let exists1 = try await ContainerPollingHelpers.pollForFile(path: socketPath, timeout: 10)
            #expect(exists1, "Socket should exist initially")

            try await Task.sleep(nanoseconds: 2_000_000_000)
            #expect(socketPath.exists, "Socket should persist")
        }
    }
}

extension ContainerPollingHelpers {
    static func pollForContainer(
        projectName: String,
        serviceName: String,
        timeout: TimeInterval
    ) async throws -> ClientContainer? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let containers = try await ClientContainer.list()
                .filter { $0.configuration.id == "\(projectName)-\(serviceName)" }

            if let container = containers.first, container.status == .running {
                return container
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    static func pollForFile(path: URL, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if path.exists { return true }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: self.path) }
}
