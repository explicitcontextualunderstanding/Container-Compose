//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richer and the Container-Compose project authors. All rights reserved.
// Rights reserved as per Apache License 2.0
//===----------------------------------------------------------------------===//

import XCTest
@testable import ContainerComposeCore

/// Shared XPC health verification for dynamic tests
/// Use in setUp() to ensure Apple Container runtime is healthy before running tests
public enum XPCHealthTestSetup {

  /// Verify XPC is healthy before running dynamic tests
  /// - Note: Test FAILS if XPC is unhealthy - no skipping allowed
  public static func verifyXPCHealth() async throws {
    let status = try await XPCHealth.verifyConnection()

    // Log health status for debugging
    if status.isHealthy {
      if let version = status.diagnostics.containerVersion {
        let pidString = status.diagnostics.daemonPID.map { String($0) } ?? "unknown"
        print("✓ XPC Health: v\(version), PID: \(pidString)")
      } else {
        let pidString = status.diagnostics.daemonPID.map { String($0) } ?? "unknown"
        print("✓ XPC Health: PID: \(pidString)")
      }

      // Log system state for context
      if let load = status.diagnostics.systemLoad {
        print(" System Load: \(String(format: "%.2f", load))")
      }
      if let memory = status.diagnostics.availableMemory {
        let mb = Double(memory) / 1_048_576.0
        print(" Available Memory: \(String(format: "%.1f", mb)) MB")
      }
    } else {
      // Log detailed diagnostics for debugging
      print("⚠️ XPC Health Check Failed:")
      print(status.description)

      // Create failure message - NO SKIPPING
      let issues = status.issues.map { $0.description }.joined(separator: ", ")
      XCTFail("XPC not healthy: \(issues). Install Apple Container runtime or run on compatible system.")
    }
  }

  /// Check if XPC is healthy without throwing
  /// - Returns: true if healthy, false otherwise
  /// - Note: Use for optional checks or conditional test behavior
  public static func isXPCHealthy() async -> Bool {
    await XPCHealth.isHealthy()
  }

  /// Collect XPC diagnostics without throwing
  /// - Returns: XPC diagnostics snapshot
  public static func collectDiagnostics() async -> XPCHealth.XPCDiagnostics {
    await XPCHealth.collectDiagnostics()
  }

  /// Assert XPC is healthy, fail test if not
  /// - Parameters:
  ///   - file: File for XCTest assertion location
  ///   - line: Line for XCTest assertion location
  public static func assertHealthy(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let status = try await XPCHealth.verifyConnection()

    if !status.isHealthy {
      let issues = status.issues.map { $0.description }.joined(separator: ", ")
      XCTFail("XPC must be healthy: \(issues)", file: (file), line: line)
    }
  }
}
