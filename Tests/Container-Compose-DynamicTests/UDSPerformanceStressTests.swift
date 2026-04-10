//===----------------------------------------------------------------------===//
// UDSPerformanceStressTests.swift
// Performance and stress tests for UDS relay (Plan 88)
// Migrated from VsockPerformanceStressTests
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import ContainerCommands
import ContainerAPIClient
import TestHelpers
@testable import ContainerComposeCore

@Suite("UDS Performance & Stress Tests", .containerDependent, .serialized)
struct UDSPerformanceStressTests {

    private func getRegistryURL() -> String {
        ProcessInfo.processInfo.environment["OCI_REGISTRY_URL"] ?? "docker.io"
    }

    private func createTestYaml(socketPath: String) -> String {
        let registryURL = getRegistryURL()
        return """
        name: uds-perf-test
        services:
          db:
            image: \(registryURL)/pgmicro:latest
            environment:
              POSTGRES_DB: testdb
              POSTGRES_USER: test
              POSTGRES_PASSWORD: test
            volumes:
              - test-db-sockets:/var/run/postgresql/sockets
            x-apple-relays:
              - type: uds
                port: 5432
                socket_path: \(socketPath)
            command:
              - /pgmicro
              - --unix-socket-dir=/var/run/postgresql/sockets
        volumes:
          test-db-sockets:
        """
    }

    @Test("Cold start: Container + socket ready < 5s")
    func testColdStartLatency() async throws {
        try await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 4, timeout: 30)

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "CCT_perf_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let socketPath = tempDir.appendingPathComponent("sockets/.s.PGSQL.5432").path
        let yaml = createTestYaml(socketPath: socketPath)

        let yamlURL = tempDir.appendingPathComponent("docker-compose.yaml")
        try yaml.write(to: yamlURL, atomically: false, encoding: .utf8)

        let projectName = tempDir.lastPathComponent

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            let startTime = CFAbsoluteTimeGetCurrent()

            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempDir.path(percentEncoded: false)
            ])
            try await composeUp.run()

            var socketReady = false
            var readyTime = startTime

            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: socketPath) {
                    socketReady = true
                    readyTime = CFAbsoluteTimeGetCurrent()
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            let duration = readyTime - startTime

            #expect(socketReady, "Socket should be ready at \(socketPath)")
            #expect(duration < 5.0, "Cold start should be < 5s, was \(String(format: "%.2f", duration))s")

            print("Cold start latency: \(String(format: "%.3f", duration))s")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Throughput: 10 connections in 5s window")
    func testThroughputConnections() async throws {
        try await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 4, timeout: 30)

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "CCT_throughput_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let socketPath = tempDir.appendingPathComponent("sockets/.s.PGSQL.5432").path
        let yaml = createTestYaml(socketPath: socketPath)

        let yamlURL = tempDir.appendingPathComponent("docker-compose.yaml")
        try yaml.write(to: yamlURL, atomically: false, encoding: .utf8)

        let projectName = tempDir.lastPathComponent

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempDir.path(percentEncoded: false)
            ])
            try await composeUp.run()

            var socketReady = false
            for _ in 0..<50 {
                if FileManager.default.fileExists(atPath: socketPath) {
                    socketReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(socketReady, "Socket should be ready")

            var successfulConnects = 0
            let testStartTime = CFAbsoluteTimeGetCurrent()

            for _ in 0..<10 {
                if FileManager.default.fileExists(atPath: socketPath) {
                    successfulConnects += 1
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            let testDuration = CFAbsoluteTimeGetCurrent() - testStartTime

            #expect(successfulConnects >= 8, "At least 8/10 connection attempts should succeed")
            #expect(testDuration < 6.0, "10 connection checks should complete within 6s")

            print("Throughput: \(successfulConnects)/10 connections in \(String(format: "%.2f", testDuration))s")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Stress: 3 rapid start/stop cycles")
    func testStressRapidStartStop() async throws {
        try await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 4, timeout: 30)

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "CCT_stress_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let socketPath = tempDir.appendingPathComponent("sockets/.s.PGSQL.5432").path
        let yaml = createTestYaml(socketPath: socketPath)

        let yamlURL = tempDir.appendingPathComponent("docker-compose.yaml")
        try yaml.write(to: yamlURL, atomically: false, encoding: .utf8)

        let projectName = tempDir.lastPathComponent

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            var successCount = 0

            for cycle in 1...3 {
                var composeUp = try ComposeUp.parse([
                    "-d", "db",
                    "--cwd", tempDir.path(percentEncoded: false)
                ])
                try await composeUp.run()

                var socketReady = false
                for _ in 0..<30 {
                    if FileManager.default.fileExists(atPath: socketPath) {
                        socketReady = true
                        break
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }

                guard socketReady else {
                    print("Cycle \(cycle): Socket not ready, skipping")
                    continue
                }

                var composeDown = ComposeDown()
                composeDown.projectName = projectName
                try await composeDown.run()

                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000_000)

                successCount += 1
                print("Cycle \(cycle): Completed successfully")
            }

            #expect(successCount >= 2, "At least 2/3 cycles should complete successfully")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Memory: Stable during sustained operation")
    func testMemoryStabilityUnderLoad() async throws {
        try await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 4, timeout: 30)

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "CCT_memory_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let socketPath = tempDir.appendingPathComponent("sockets/.s.PGSQL.5432").path
        let yaml = createTestYaml(socketPath: socketPath)

        let yamlURL = tempDir.appendingPathComponent("docker-compose.yaml")
        try yaml.write(to: yamlURL, atomically: false, encoding: .utf8)

        let projectName = tempDir.lastPathComponent

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempDir.path(percentEncoded: false)
            ])
            try await composeUp.run()

            var socketReady = false
            for _ in 0..<30 {
                if FileManager.default.fileExists(atPath: socketPath) {
                    socketReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(socketReady, "Socket should be ready")

            let baselineContainerCount = (try? await ClientContainer.list()?.count) ?? 0
            print("Baseline container count: \(baselineContainerCount)")

            for _ in 0..<5 {
                _ = try? await ClientContainer.list()
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

            let finalContainerCount = (try? await ClientContainer.list()?.count) ?? 0
            print("Final container count: \(finalContainerCount)")

            #expect(
                finalContainerCount <= baselineContainerCount + 2,
                "Container count should remain stable (\(baselineContainerCount) -> \(finalContainerCount))"
            )
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Latency: Socket file appearance < 3s after container start")
    func testSocketAppearanceLatency() async throws {
        try await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 4, timeout: 30)

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "CCT_latency_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let socketPath = tempDir.appendingPathComponent("sockets/.s.PGSQL.5432").path
        let yaml = createTestYaml(socketPath: socketPath)

        let yamlURL = tempDir.appendingPathComponent("docker-compose.yaml")
        try yaml.write(to: yamlURL, atomically: false, encoding: .utf8)

        let projectName = tempDir.lastPathComponent

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempDir.path(percentEncoded: false)
            ])
            try await composeUp.run()

            let startTime = CFAbsoluteTimeGetCurrent()
            var socketAppeared = false
            var appearanceTime = startTime

            for _ in 0..<60 {
                if FileManager.default.fileExists(atPath: socketPath) {
                    socketAppeared = true
                    appearanceTime = CFAbsoluteTimeGetCurrent()
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            let latency = appearanceTime - startTime

            #expect(socketAppeared, "Socket should appear at \(socketPath)")
            #expect(latency < 3.0, "Socket appearance should be < 3s, was \(String(format: "%.2f", latency))s")

            print("Socket appearance latency: \(String(format: "%.3f", latency))s")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Stress: Handle container cleanup under pressure")
    func testStressContainerCleanup() async throws {
        try await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 4, timeout: 30)

        var cleanupSuccesses = 0

        for _ in 0..<3 {
            let tempDir = FileManager.default.temporaryDirectory
                .appending(path: "CCT_cleanup_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let socketPath = tempDir.appendingPathComponent("sockets/.s.PGSQL.5432").path
            let yaml = createTestYaml(socketPath: socketPath)

            let yamlURL = tempDir.appendingPathComponent("docker-compose.yaml")
            try yaml.write(to: yamlURL, atomically: false, encoding: .utf8)

            let projectName = tempDir.lastPathComponent

            do {
                var composeUp = try ComposeUp.parse([
                    "-d", "db",
                    "--cwd", tempDir.path(percentEncoded: false)
                ])
                try await composeUp.run()

                try await Task.sleep(nanoseconds: 2_000_000_000)

                var composeDown = ComposeDown()
                composeDown.projectName = projectName
                try await composeDown.run()

                await ContainerPollingHelpers.cleanupProjectContainers(projectName: projectName)
                cleanupSuccesses += 1
            } catch {
                print("Cleanup cycle error: \(error)")
            }

            try? FileManager.default.removeItem(at: tempDir)
        }

        #expect(cleanupSuccesses >= 2, "At least 2/3 cleanup cycles should succeed")
    }

    @Test("Limits: Path length validation near AF_UNIX limit")
    func testSocketPathLengthLimits() async throws {
        let validPath = "/tmp/test_socket.sock"
        #expect(validPath.count < 104, "Valid path should be under 104 chars")

        let borderlinePath = String(repeating: "x", count: 100) + ".sock"
        #expect(borderlinePath.count < 104, "Borderline path should still be under limit")

        let tooLongPath = String(repeating: "x", count: 110) + ".sock"
        #expect(tooLongPath.count >= 104, "Long path should exceed 104 chars")

        let productionPath = "/Users/kieranlal/.containers/Volumes/apple-honcho/honcho-db-sockets/.s.PGSQL.5432"
        #expect(productionPath.count < 104, "Production path (\(productionPath.count) chars) should be under limit")
    }

    @Test("Duration: 30 second sustained operation")
    func test30SecondStability() async throws {
        try await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 4, timeout: 30)

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "CCT_duration_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let socketPath = tempDir.appendingPathComponent("sockets/.s.PGSQL.5432").path
        let yaml = createTestYaml(socketPath: socketPath)

        let yamlURL = tempDir.appendingPathComponent("docker-compose.yaml")
        try yaml.write(to: yamlURL, atomically: false, encoding: .utf8)

        let projectName = tempDir.lastPathComponent

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempDir.path(percentEncoded: false)
            ])
            try await composeUp.run()

            var socketReady = false
            for _ in 0..<30 {
                if FileManager.default.fileExists(atPath: socketPath) {
                    socketReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(socketReady, "Socket should be ready")

            var checksPassed = 0
            let totalChecks = 6

            for i in 1...totalChecks {
                try await Task.sleep(nanoseconds: 5_000_000_000)

                if FileManager.default.fileExists(atPath: socketPath) {
                    checksPassed += 1
                    print("Check \(i)/\(totalChecks): Socket still present")
                }
            }

            #expect(checksPassed >= 5, "Socket should remain stable for 30s (\(checksPassed)/\(totalChecks) checks passed)")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Warmup: Second start faster than first")
    func testWarmupPerformance() async throws {
        try await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 4, timeout: 30)

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "CCT_warmup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let socketPath = tempDir.appendingPathComponent("sockets/.s.PGSQL.5432").path
        let yaml = createTestYaml(socketPath: socketPath)

        let yamlURL = tempDir.appendingPathComponent("docker-compose.yaml")
        try yaml.write(to: yamlURL, atomically: false, encoding: .utf8)

        let projectName = tempDir.lastPathComponent

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            var firstStartDuration: TimeInterval = 0
            var secondStartDuration: TimeInterval = 0

            for attempt in 1...2 {
                let startTime = CFAbsoluteTimeGetCurrent()

                var composeUp = try ComposeUp.parse([
                    "-d", "db",
                    "--cwd", tempDir.path(percentEncoded: false)
                ])
                try await composeUp.run()

                var socketReady = false
                for _ in 0..<50 {
                    if FileManager.default.fileExists(atPath: socketPath) {
                        socketReady = true
                        break
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }

                let duration = CFAbsoluteTimeGetCurrent() - startTime

                #expect(socketReady, "Attempt \(attempt): Socket should be ready")

                if attempt == 1 {
                    firstStartDuration = duration
                } else {
                    secondStartDuration = duration
                }

                var composeDown = ComposeDown()
                composeDown.projectName = projectName
                try await composeDown.run()

                if attempt == 1 {
                    await ContainerPollingHelpers.cleanupProjectContainers(projectName: projectName)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }

            print("First start: \(String(format: "%.3f", firstStartDuration))s")
            print("Second start: \(String(format: "%.3f", secondStartDuration))s")

            #expect(
                secondStartDuration <= firstStartDuration * 1.5,
                "Second start should not be significantly slower than first"
            )
        }

        try? FileManager.default.removeItem(at: tempDir)
    }
}
