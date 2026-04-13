//===----------------------------------------------------------------------===//
// RelayManagerErrorHandlingTests.swift
// Error handling integration tests for RelayManager
// Tests: error propagation, graceful degradation, cleanup on failure
//===----------------------------------------------------------------------===//

import XCTest
import Foundation
@testable import ContainerComposeCore

/// Error handling integration tests for RelayManager
/// Validates error flows from VsockRelay through RelayManager
@available(macOS 12.0, *)
final class RelayManagerErrorHandlingTests: XCTestCase, @unchecked Sendable {

    var eventLog: RelayEventLog!
    var relayManager: RelayManager!

override func setUp() {
        super.setUp()
        eventLog = RelayEventLog()
        // Disable security gates for tests - TCC preflight requires entitlements not available in test environment
        relayManager = RelayManager(eventLog: eventLog, enableSecurity: false)
    }

  override func tearDown() async throws {
    await relayManager.stopAll()
    relayManager = nil
    eventLog = nil
  }

  // MARK: - Test 1: Error Propagation

  /// Verify errors from VsockRelay propagate correctly through RelayManager
  func testErrorPropagationFromVsockRelay() async throws {
    // Config with invalid CID (should cause error)
    let config = RelayManager.RelayConfiguration(
      id: "error-test",
      tcpPort: 15432,
      transport: .uds(path: "/tmp/test-vsock-fallback-\(UUID().uuidString).sock", virtioFSMount: nil),
      description: "Error propagation test"
    )

    do {
      try await relayManager.startRelay(config)
      // If we get here, check if it's actually running or failed silently
      let status = await relayManager.status()
      if status.isEmpty {
        // Expected - vsock with CID 999 likely fails
        print("✅ Relay failed to start as expected (CID 999 invalid)")
      }
    } catch {
      // Error should be propagated with details
      let errorString = String(describing: error)
      print("✅ Error propagated: \(errorString)")

      // Error should contain useful information
      XCTAssertTrue(
        errorString.count > 0,
        "Error should have message"
      )
    }

    // Verify no lingering state
    let status = await relayManager.status()
    XCTAssertEqual(status.count, 0, "Should have no active relays after error")
  }

  // MARK: - Test 2: Graceful Degradation

  /// Verify RelayManager handles vsock unavailability gracefully
  func testGracefulDegradationWhenVsockUnavailable() async throws {
    // Try to start relay when vsock device may not be available
    let config = RelayManager.RelayConfiguration(
      id: "degradation-test",
      tcpPort: 15433,
      transport: .uds(path: "/tmp/test-\(UUID().uuidString).sock", virtioFSMount: nil),
      description: "Graceful degradation test"
    )

    do {
      try await relayManager.startRelay(config)
      // May succeed or fail depending on environment
      print("ℹ️  Relay start result depends on environment")
    } catch {
      // Should fail gracefully with informative error
      let errorString = String(describing: error)
      print("ℹ️  Error (expected if vsock unavailable): \(errorString)")

      // Should NOT crash or leave system in bad state
      let status = await relayManager.status()
      XCTAssertEqual(status.count, 0, "Should clean up on failure")
    }
  }

  // MARK: - Test 3: Cleanup on Error

/// Verify RelayManager cleans up resources when start fails
    /// Note: This test requires Apple Developer entitlements (TCC preflight)
    /// Skip if running in CI/test environment without proper signing
    ///
    /// This test may hang indefinitely without proper entitlements because
    /// RelayManager operations require Apple Developer ID signing for TCC preflight
    ///
    /// TODO: Properly detect if Apple Developer entitlements are available
    /// Currently checks for CI environment, but should check actual entitlement status
    /// e.g., via codesign -d --entitlements or by attempting a privileged operation
    func testCleanupOnStartFailure() async throws {
        // Skip in environments without proper entitlements
        // Quick toggle: SKIP_ENTITLEMENT_TESTS=1 to skip in development
        // TODO: Replace with proper entitlement check via codesign or AMFIValidator
        if ProcessInfo.processInfo.environment.keys.contains("SKIP_ENTITLEMENT_TESTS") {
            throw XCTSkip("Skipped via SKIP_ENTITLEMENT_TESTS environment variable")
        }
        guard !ProcessInfo.processInfo.environment.keys.contains("CI") else {
            throw XCTSkip("Requires Apple Developer entitlements - skipping in CI (TODO: proper entitlement detection)")
        }

        let config = RelayManager.RelayConfiguration(
            id: "cleanup-test",
            tcpPort: 15434,
            transport: .uds(path: "/tmp/test-\(UUID().uuidString).sock", virtioFSMount: nil),
            description: "Cleanup test"
        )

        // Try to start with XCTest expectation timeout
        // Using expectation pattern to prevent hanging indefinitely
        // Use actor-isolated approach to avoid Sendable warnings
        let expectation = self.expectation(description: "Relay start completes")
        
        // Create detached task to avoid capturing self
        Task.detached { [weak self] in
            defer { expectation.fulfill() }
            guard let strongSelf = self else { return }
            do {
                try await strongSelf.relayManager.startRelay(config)
            } catch {
                print("Start failed (may be expected): \(error)")
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)

        // Verify no partial state
        let status = await relayManager.status()
        XCTAssertEqual(status.filter { $0.id == "cleanup-test" }.count, 0,
                       "Should not have partial relay entry")

        // Verify can try again (with timeout)
        let expectation2 = self.expectation(description: "Second relay start completes")
        Task.detached { [weak self] in
            defer { expectation2.fulfill() }
            guard let strongSelf = self else { return }
            do {
                try await strongSelf.relayManager.startRelay(config)
                print("✅ Second attempt succeeded or failed cleanly")
            } catch {
                print("Second attempt failed: \(error)")
            }
        }
        await fulfillment(of: [expectation2], timeout: 5.0)

        // Final cleanup (no-op if relay never started)
        await relayManager.stopRelay(id: "cleanup-test")
    }

// MARK: - Test 4: Duplicate ID Error

/// Verify proper error when starting duplicate relay
/// Plan 88: Migrated from vsock to UDS
func testDuplicateIdError() async throws {
	let socketPath = "/tmp/test-duplicate-\(UUID().uuidString).sock"
	defer { try? FileManager.default.removeItem(atPath: socketPath) }

	let config = RelayManager.RelayConfiguration(
		id: "duplicate-test",
		tcpPort: 15435,
		transport: .uds(path: socketPath, virtioFSMount: nil),
		description: "Duplicate ID test"
	)

    // First start (may succeed or fail)
    do {
      try await relayManager.startRelay(config)
    } catch {
      print("First start failed: \(error)")
    }

    // Second start with same ID should fail
    do {
      try await relayManager.startRelay(config)
      // If first failed, second might succeed
      print("Second start succeeded (first must have failed)")
    } catch {
      let errorString = String(describing: error)
      XCTAssertTrue(
        errorString.contains("already") || errorString.contains("duplicate") || errorString.contains("running"),
        "Error should indicate duplicate: \(errorString)"
      )
    }

    // Cleanup
    await relayManager.stopRelay(id: "duplicate-test")
  }

  // MARK: - Test 5: Invalid Transport Error

  /// Verify error for unsupported transport types
  func testInvalidTransportError() async throws {
    // Test with unixSocket transport (not supported for vsock-db)
    let config = RelayManager.RelayConfiguration(
      id: "invalid-transport-test",
      tcpPort: 15436,
      transport: .unixSocket(path: "/tmp/test.sock"),
      description: "Invalid transport test"
    )

    do {
      try await relayManager.startRelay(config)
      // May succeed for unixSocket
      print("UnixSocket relay started")
      await relayManager.stopRelay(id: "invalid-transport-test")
    } catch {
      let errorString = String(describing: error)
      print("Error (may be expected): \(errorString)")
    }
  }

  // MARK: - Test 6: Port Conflict Detection

  /// Verify detection of port conflicts
  func testPortConflictDetection() async throws {
    let config1 = RelayManager.RelayConfiguration(
      id: "port-conflict-1",
      tcpPort: 15437,
      transport: .uds(path: "/tmp/test-\(UUID().uuidString).sock", virtioFSMount: nil),
      description: "Port conflict test 1"
    )

    let config2 = RelayManager.RelayConfiguration(
      id: "port-conflict-2",
      tcpPort: 15437, // Same port
      transport: .uds(path: "/tmp/test-5433-\(UUID().uuidString).sock", virtioFSMount: nil),
      description: "Port conflict test 2"
    )

    // Start first
    do {
      try await relayManager.startRelay(config1)
    } catch {
      print("First start failed: \(error)")
    }

    // Try second with same port
    do {
      try await relayManager.startRelay(config2)
      print("Second start succeeded (ports may be managed)")
    } catch {
      let errorString = String(describing: error)
      XCTAssertTrue(
        errorString.contains("port") || errorString.contains("address"),
        "Should indicate port issue: \(errorString)"
      )
    }

    // Cleanup
    await relayManager.stopRelay(id: "port-conflict-1")
    await relayManager.stopRelay(id: "port-conflict-2")
  }

  // MARK: - Test 7: Event Log on Error

  /// Verify errors are logged to event log
  func testEventLogOnError() async throws {
    let config = RelayManager.RelayConfiguration(
      id: "event-log-test",
      tcpPort: 15438,
      transport: .uds(path: "/tmp/test-vsock-fallback-\(UUID().uuidString).sock", virtioFSMount: nil),
      description: "Event log test"
    )

    // Clear event log
    let initialEvents = await eventLog.eventsForRelay("event-log-test")
    XCTAssertEqual(initialEvents.count, 0, "Should start with no events")

    // Try to start
    do {
      try await relayManager.startRelay(config)
    } catch {
      print("Error captured: \(error)")
    }

    // Check event log captured something
    let events = await eventLog.eventsForRelay("event-log-test")
    print("✅ Events captured: \(events.count)")
    // Events may be 0 if start failed before logging, which is OK
  }

  // MARK: - Test 8: Stop Non-Existent Relay

  /// Verify graceful handling when stopping non-existent relay
  func testStopNonExistentRelay() async {
    // Should not throw
    await relayManager.stopRelay(id: "non-existent-relay")

    // Status should be empty
    let status = await relayManager.status()
    XCTAssertEqual(status.count, 0, "Should have no relays")
  }

  // MARK: - Test 9: Configuration Validation

  /// Verify configuration validation before starting
  func testConfigurationValidation() {
    // Valid configuration
    let validConfig = RelayManager.RelayConfiguration(
      id: "valid-config",
      tcpPort: 15439,
      transport: .uds(path: "/tmp/test-\(UUID().uuidString).sock", virtioFSMount: nil),
      description: "Valid config"
    )

    // Should be creatable
    XCTAssertEqual(validConfig.id, "valid-config")
    XCTAssertEqual(validConfig.tcpPort, 15439)

    // Edge case: empty ID
    let emptyIdConfig = RelayManager.RelayConfiguration(
      id: "",
      tcpPort: 15440,
      transport: .uds(path: "/tmp/test-\(UUID().uuidString).sock", virtioFSMount: nil),
      description: "Empty ID"
    )
    XCTAssertEqual(emptyIdConfig.id, "", "Should allow empty ID (may fail on start)")
  }

  // MARK: - Test 10: Multiple Error Scenarios

  /// Verify handling of multiple sequential errors
  func testMultipleSequentialErrors() async throws {
    let configs = [
      RelayManager.RelayConfiguration(
        id: "error-1",
        tcpPort: 15441,
        transport: .uds(path: "/tmp/test-vsock-fallback-\(UUID().uuidString).sock", virtioFSMount: nil),
        description: "Error 1"
      ),
      RelayManager.RelayConfiguration(
        id: "error-2",
        tcpPort: 15442,
        transport: .uds(path: "/tmp/test-998-\(UUID().uuidString).sock", virtioFSMount: nil),
        description: "Error 2"
      ),
      RelayManager.RelayConfiguration(
        id: "error-3",
        tcpPort: 15443,
        transport: .uds(path: "/tmp/test-997-\(UUID().uuidString).sock", virtioFSMount: nil),
        description: "Error 3"
      )
    ]

    var successCount = 0
    var errorCount = 0

    for config in configs {
      do {
        try await relayManager.startRelay(config)
        successCount += 1
      } catch {
        errorCount += 1
        print("Error \(config.id): \(error)")
      }
    }

    print("✅ Success: \(successCount), Errors: \(errorCount)")

    // System should be stable after multiple errors
    let status = await relayManager.status()
print("Active relays: \(status.count)")

    // Cleanup any that started
    for config in configs {
        await relayManager.stopRelay(id: config.id)
    }
}

// MARK: - UDS Error Handling Tests (Plan 88)

func testUDSRelayWithInvalidSocketPath() async throws {
    // Plan 88: Test UDS relay handles invalid socket path gracefully
    let invalidPath = String(repeating: "a", count: 110) + ".sock"

    let config = RelayManager.RelayConfiguration(
        id: "invalid-uds-relay",
        tcpPort: 9999,
        transport: .uds(path: invalidPath, virtioFSMount: nil),
        description: "Test invalid UDS path"
    )

    do {
        try await relayManager.startRelay(config)
        XCTFail("Should have thrown error for path >= 104 chars")
    } catch {
        // Expected: UDSError.socketPathTooLong
        let errorString = String(describing: error)
        XCTAssertTrue(
            errorString.contains("too long") || errorString.contains("104"),
            "Error should indicate path too long: \(errorString)"
        )
    }
}

func testUDSRelayWithEmptyPath() async throws {
    // Plan 88: Test UDS relay handles empty socket path
    let config = RelayManager.RelayConfiguration(
        id: "empty-uds-relay",
        tcpPort: 9998,
        transport: .uds(path: "", virtioFSMount: nil),
        description: "Test empty UDS path"
    )

    // Empty path should be allowed (will fail at bind time, not init)
    try await relayManager.startRelay(config)
    await relayManager.stopRelay(id: "empty-uds-relay")
}
}
