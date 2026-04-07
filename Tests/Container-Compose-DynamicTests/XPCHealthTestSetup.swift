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
    /// - Throws: XCTSkip if XPC is unhealthy, allowing test to skip cleanly
    /// - Note: Logs full XPC diagnostics when skipping
    public static func verifyXPCHealth() async throws {
        let status = try await XPCHealth.verifyConnection()
        
        if !status.isHealthy {
            // Log detailed diagnostics for debugging
            print("⚠️  XPC Health Check Failed:")
            print(status.description)
            
            // Create descriptive skip message
            let issues = status.issues.map { $0.description }.joined(separator: ", ")
            throw XCTSkip("XPC not healthy: \(issues)")
        }
        
        // Log successful health check for visibility
        if let version = status.diagnostics.containerVersion {
            let pidString = status.diagnostics.daemonPID.map { String($0) } ?? "unknown"
            print("✓ XPC Health: v\(version), PID: \(pidString)")
        } else {
            let pidString = status.diagnostics.daemonPID.map { String($0) } ?? "unknown"
            print("✓ XPC Health: PID: \(pidString)")
        }
        
        // Log system state for context
        if let load = status.diagnostics.systemLoad {
            print("  System Load: \(String(format: "%.2f", load))")
        }
        if let memory = status.diagnostics.availableMemory {
            let mb = Double(memory) / 1_048_576.0
            print("  Available Memory: \(String(format: "%.1f", mb)) MB")
        }
    }
    
    /// Check if XPC is healthy without skipping
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
    
    /// Skip test if XPC is unhealthy, with optional context
    /// - Parameters:
    ///   - context: Additional context to include in skip message
    ///   - file: File for XCTest skip location
    ///   - line: Line for XCTest skip location
    /// - Throws: XCTSkip if XPC unhealthy
    public static func skipIfUnhealthy(
        context: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let status = try await XPCHealth.verifyConnection()
        
        if !status.isHealthy {
            // Log detailed diagnostics
            print("⚠️  XPC Health Check Failed (file: \(file), line: \(line)):")
            print(status.description)
            
            if let context = context {
                print("  Context: \(context)")
            }
            
            let issues = status.issues.map { $0.description }.joined(separator: ", ")
            let message = context != nil
                ? "XPC not healthy (\(context!)): \(issues)"
                : "XPC not healthy: \(issues)"
            
            throw XCTSkip(message, file: (file), line: line)
        }
    }
    
    /// Assert XPC is healthy, fail test if not
    /// - Parameters:
    ///   - file: File for XCTest assertion location
    ///   - line: Line for XCTest assertion location
    /// - Note: Use this when test MUST have healthy XPC (not optional)
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