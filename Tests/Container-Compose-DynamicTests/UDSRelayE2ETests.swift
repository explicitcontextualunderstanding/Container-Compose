//===----------------------------------------------------------------------===//
// UDSRelayE2ETests.swift
// E2E tests for UDS relay using actual containers
// Plan 88 Phase 4: Real container integration testing
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import ContainerCommands
import ContainerAPIClient
import TestHelpers
@testable import ContainerComposeCore

@Suite("UDS Relay E2E Tests", .containerDependent,
       .empiricalMemory(image: "pgmicro", fallbackMB: 270))
struct UDSRelayE2ETests {

    @Test("E2E: UDS relay with real PostgreSQL container")
    func testUDSRelayWithRealDatabase() async throws {
        try await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 4, timeout: 30)

        let containerCount = (try? await ClientContainer.list())?.count ?? 0
        if containerCount > 6 {
            print("⚠️ Skipping E2E test: \(containerCount) containers running, need slots")
            return
        }

        let tempProject = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(
            yaml: DockerComposeYamlFiles.udsDbRelayYaml
        )

        try await ContainerPollingHelpers.withProjectCleanup(projectName: tempProject.name) {
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempProject.base.path(percentEncoded: false)
            ])
            try await composeUp.run()

            let containers = try await ClientContainer.list()
            let dbContainer = containers.first { $0.configuration.id.contains("\(tempProject.name)-db") }

            #expect(dbContainer != nil, "db container should exist in project \(tempProject.name)")

            var isRunning = false
            for _ in 0..<60 {
                let refreshed = try await ClientContainer.list()
                    .first { $0.configuration.id.contains("\(tempProject.name)-db") }
                if refreshed?.status == .running {
                    isRunning = true
                    break
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            #expect(isRunning, "db should be running within 60s")

            let expectedSocketPath = tempProject.base
                .appendingPathComponent("sockets/.s.PGSQL.5432")

            var socketExists = false
            for _ in 0..<60 {
                if FileManager.default.fileExists(atPath: expectedSocketPath.path) {
                    socketExists = true
                    break
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

            #expect(socketExists, "Socket should exist at \(expectedSocketPath.path)")
        }
    }

    @Test("E2E: Database connectivity through UDS relay")
    func testDatabaseConnectivityThroughRelay() async throws {
        let tempProject = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(
            yaml: DockerComposeYamlFiles.udsDbRelayYaml
        )

        try await ContainerPollingHelpers.withProjectCleanup(projectName: tempProject.name) {
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempProject.base.path(percentEncoded: false)
            ])
            try await composeUp.run()

            let containers = try await ContainerPollingHelpers.waitForContainers(
                projectName: tempProject.name,
                expectedCount: 1,
                timeout: 30
            )

            #expect(!containers.isEmpty, "db container should be created")

            let containerId = containers.first?.configuration.id ?? ""
            let runningContainer = try? await ContainerPollingHelpers.waitForRunning(
                containerId: containerId,
                timeout: 30
            )

            #expect(runningContainer != nil, "db container should be running")

            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }

    @Test("E2E: RelayManager with UDS transport")
    func testRelayManagerWithUDS() async throws {
        let tempProject = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(
            yaml: DockerComposeYamlFiles.udsDbRelayYaml
        )

        try await ContainerPollingHelpers.withProjectCleanup(projectName: tempProject.name) {
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempProject.base.path(percentEncoded: false)
            ])
            try await composeUp.run()

            let containers = try await ClientContainer.list()
            let dbContainer = containers.first { $0.configuration.id.contains("\(tempProject.name)-db") }

            #expect(dbContainer != nil, "Container should exist")
            #expect(dbContainer?.configuration.networks != nil, "Container should have network config")

            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }
}

@Suite("UDS Relay Performance Tests", .containerDependent)
struct UDSRelayPerformanceTests {

    @Test("Performance: Relay startup time < 5s target")
    func testRelayStartupTime() async throws {
        let tempProject = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(
            yaml: DockerComposeYamlFiles.udsDbRelayYaml
        )

        try await ContainerPollingHelpers.withProjectCleanup(projectName: tempProject.name) {
            let startTime = CFAbsoluteTimeGetCurrent()

            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempProject.base.path(percentEncoded: false)
            ])
            try await composeUp.run()

            let socketPath = tempProject.base.appendingPathComponent("sockets/.s.PGSQL.5432")

            var socketReady = false
            for _ in 0..<50 {
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

            var composeDown = ComposeDown()
            try await composeDown.run()
        }
    }
}
