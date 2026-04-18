//===----------------------------------------------------------------------===//
// Phase12LoadStressTests.swift
// Pure non-blocking concurrent load testing for the UDS Socket Relay
// Direct targeted testing of fdCopyHandler bottleneck via 50 TCP streams
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import Network
import ContainerCommands
import ContainerAPIClient
import TestHelpers
@testable import ContainerComposeCore

@Suite("Phase 12: Data Pump Concurrency Stress", .containerDependent)
struct Phase12LoadStressTests {

    private func getRegistryURL() -> String {
        ProcessInfo.processInfo.environment["OCI_REGISTRY_URL"] ?? "docker.io"
    }

    /// Creates a short temp directory to ensure Unix socket length requirements
    private func createShortTempDir(prefix: String) throws -> (URL, String) {
        let shortUUID = String(UUID().uuidString.prefix(8))
        let tempDir = URL(fileURLWithPath: "/tmp/\(prefix)_\(shortUUID)")
        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let socketPath = tempDir.appendingPathComponent(".s.PGSQL.5432").path
        return (tempDir, socketPath)
    }

    private func createTestYaml(socketPath: String, relayPort: Int) -> String {
        let registryURL = getRegistryURL()
        return """
        name: phase12-load-test
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
                port: \(relayPort)
                socket_path: \(socketPath)
            command:
              - /pgmicro
              - --unix-socket-dir=/var/run/postgresql/sockets
        volumes:
          test-db-sockets:
        """
    }

    /// Pure Swift POSIX TCP execution payload driven by GCD
    /// Completely bypasses Executor thread-pool starvation by offloading standard POSIX
    /// connections directly to `DispatchQueue.global(qos: .userInitiated)` instead of
    /// blocking `await` or `NWConnection` state captures.
    private func pingRelay(socketPath: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(returning: false)
                    return
                }
                
                // Assert strict aggressive timeouts (3 sec max latency allowed)
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                socketPath.withCString { cString in
                    let length = min(socketPath.utf8.count, 103)
                    _ = memcpy(&addr.sun_path, cString, length + 1)
                }
                
                let connectResult = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                
                guard connectResult == 0 else {
                    Darwin.close(fd)
                    continuation.resume(returning: false)
                    return
                }
                
                // Postgres StartupMessage Protocol Mock: Length(8), Protocol(196608)
                let payload: [UInt8] = [0, 0, 0, 8, 0, 3, 0, 0]
                let sent = Darwin.send(fd, payload, payload.count, 0)
                guard sent == payload.count else {
                    Darwin.close(fd)
                    continuation.resume(returning: false)
                    return
                }
                
                var recvBuffer = [UInt8](repeating: 0, count: 1024)
                let received = Darwin.recv(fd, &recvBuffer, recvBuffer.count, 0)
                Darwin.close(fd)
                
                // If we received any byte payload back from pgmicro, the relay successfully mapped the round trip!
                continuation.resume(returning: received > 0)
            }
        }
    }

    @Test("50 Concurrent TCP Round-Trips via Relay")
    func testFIFTYConcurrentTCP() async throws {
        // Reserve exactly 1 container slot since we only need the proxy DB
        await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 1, timeout: 30)

        // Generate dynamic assets
        let (tempDir, socketPath) = try createShortTempDir(prefix: "p12")
        let relayPort: UInt16 = 15432
        let yaml = createTestYaml(socketPath: socketPath, relayPort: Int(relayPort))
        
        let yamlURL = tempDir.appendingPathComponent("docker-compose.yaml")
        try yaml.write(to: yamlURL, atomically: false, encoding: .utf8)
        let projectName = tempDir.lastPathComponent

        try await ContainerPollingHelpers.withProjectCleanup(projectName: projectName) {
            print("[DIAGNOSTIC] Booting single pgmicro container...")
            let bootStart = CFAbsoluteTimeGetCurrent()
            
            var composeUp = try ComposeUp.parse([
                "-d", "db",
                "--cwd", tempDir.path(percentEncoded: false)
            ])
            try await composeUp.run()
            
            print("[DIAGNOSTIC] Booted in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - bootStart))s")
            
            // Wait heavily for orchestrator + relay mapping to establish limits
            var socketReady = false
            for _ in 0..<50 {
                if FileManager.default.fileExists(atPath: socketPath) {
                    socketReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(socketReady, "UDS Socket failed to instantiate inside the orchestration loop")
            
            // Wait for DB to be completely up
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
            print("[DIAGNOSTIC] Firing 50 Concurrent Native AF_UNIX payloads against \(socketPath)...")
            let blastStart = CFAbsoluteTimeGetCurrent()
            
            let successCount = await withTaskGroup(of: Bool.self) { group in
                for _ in 1...50 {
                    group.addTask {
                        return await pingRelay(socketPath: socketPath)
                    }
                }
                
                var successes = 0
                for await result in group {
                    if result { successes += 1 }
                }
                return successes
            }
            
            let elapsed = CFAbsoluteTimeGetCurrent() - blastStart
            print("[DIAGNOSTIC] 50 Connections Complete. Successes: \(successCount)/50. Vector Latency: \(String(format: "%.3f", elapsed))s")
            
            // Expected that 50 concurrent loads against a serial queue bottleneck drops some handshakes - tracking exact throughput baseline.
            #expect(successCount >= 45, "Stress payload dropped too many connections over relay: \(successCount)/50")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }
}
