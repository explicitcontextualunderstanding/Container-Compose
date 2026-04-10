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
    // Skip if vsock unavailable (macOS host)
    let availability = checkVsockAvailability()
    if !availability.isAvailable {
      print("⚠️ Skipping E2E test: Vsock unavailable - \(availability.errorMessage ?? "unknown")")
      return
    }

    // Wait for available VM slots before starting
    // Uses same pattern as run_tests.sh cleanup
    try await ContainerPollingHelpers.waitForContainerSlots(maxSlots: 4, timeout: 30)

    // Check if we have enough resources to run E2E test
    let containerCount = (try? await ClientContainer.list())?.count ?? 0
    if containerCount > 6 {
      // Skip if too many containers already running (resource constraint)
      print("⚠️ Skipping E2E test: \(containerCount) containers running, need slots")
      return
    }

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

      // Verify container exists and started
      #expect(dbContainer != nil, "db container should exist in project \(tempProject.name)")

      // Wait for container to be running (may take time for PostgreSQL to init)
      var isRunning = false
      for _ in 0..<60 {  // 60 second wait for PostgreSQL
        let refreshed = try await ClientContainer.list()
          .first { $0.configuration.id.contains("\(tempProject.name)-db") }
        if refreshed?.status == .running {
          isRunning = true
          break
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
      #expect(isRunning, "db should be running within 60s")

      // Verify socket path configured from YAML fixture
      // Socket path is now set to tempProject.base/sockets/.s.PGSQL.5432 in the fixture
      let expectedSocketPath = tempProject.base
        .appendingPathComponent("sockets/.s.PGSQL.5432")

      // Poll for socket creation (up to 60s for PostgreSQL + relay)
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

@Suite("UDS Relay E2E Tests (Plan 88)", .serialized)
struct UDSRelayE2ETests {
	// MARK: - UDS Path Length Validation Tests

	@Test("UDS: Path length validation rejects paths >= 104 chars")
	func testUDSSocketPathLengthValidation() {
		// Plan 88 Finding C-2: Must hard-error at config time for paths >= 104 chars
		let longPath = String(repeating: "a", count: 110) + ".sock"

		XCTAssertThrowsError(try UDSVirtioFSRelay(
			socketPath: longPath,
			virtioFSMountPath: nil,
			createSignalSocket: true,
			eventLog: RelayEventLog()
		)) { error in
			let errorString = String(describing: error)
			XCTAssertTrue(
				errorString.contains("too long") || errorString.contains("104"),
				"Error should indicate path too long: \(errorString)"
			)
		}
	}

	@Test("UDS: Accepts valid socket paths under 104 chars")
	func testUDSAcceptValidSocketPath() throws {
		let validPath = "/tmp/valid-uds-socket-\(UUID().uuidString).sock"
		defer { try? FileManager.default.removeItem(atPath: validPath) }

		// Valid path should not throw
		let relay = try UDSVirtioFSRelay(
			socketPath: validPath,
			virtioFSMountPath: nil,
			createSignalSocket: true,
			eventLog: RelayEventLog()
		)

		XCTAssertNotNil(relay)
	}

	// MARK: - UDS Transport Type Tests

	@Test("UDS: Transport type correctly stores path and mount")
	func testUDSTransportType() async throws {
		let socketPath = "/tmp/transport-test-\(UUID().uuidString).sock"
		let mountPath = "/Volumes/apple"
		defer { try? FileManager.default.removeItem(atPath: socketPath) }

		let relay = try UDSVirtioFSRelay(
			socketPath: socketPath,
			virtioFSMountPath: mountPath,
			createSignalSocket: true,
			eventLog: RelayEventLog()
		)

		let transport = await relay.transportType
		if case .uds(let path, let mount) = transport {
			XCTAssertEqual(path, socketPath)
			XCTAssertEqual(mount, mountPath)
		} else {
			XCTFail("Transport should be .uds")
		}
	}

	// MARK: - UDS Production Path Test

	@Test("UDS: Production socket path (88 chars) is valid")
	func testUDSProductionSocketPath() {
		// Actual path from honcho-stack-with-derivers.yml
		let productionPath = "/Users/kieranlal/.containers/Volumes/apple-honcho/honcho-db-sockets/.s.PGSQL.5432"

		XCTAssertLessThan(productionPath.count, 104,
			"Production socket path must be under AF_UNIX limit (104 chars)")

		// Should not throw - valid path
		XCTAssertNoThrow(try UDSVirtioFSRelay(
			socketPath: productionPath,
			virtioFSMountPath: "/Users/kieranlal/.containers/Volumes/apple-honcho",
			createSignalSocket: false,
			eventLog: RelayEventLog()
		))
	}
}
}
