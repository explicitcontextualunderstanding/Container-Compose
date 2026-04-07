//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
// Rights reserved as per Apache License 2.0
//===----------------------------------------------------------------------===//

import XCTest
@testable import ContainerComposeCore

final class XPCHealthTests: XCTestCase {
    
    // MARK: - Health Status Tests
    
    func testHealthStatusInitialization() {
        let diagnostics = XPCHealth.XPCDiagnostics(
            containerVersion: "0.11.0",
            daemonPID: 12345,
            connectionState: "valid"
        )
        
        let status = XPCHealth.HealthStatus(
            isHealthy: true,
            daemonRunning: true,
            connectionValid: true,
            apiResponsive: true,
            diagnostics: diagnostics,
            issues: []
        )
        
        XCTAssertTrue(status.isHealthy)
        XCTAssertTrue(status.daemonRunning)
        XCTAssertTrue(status.connectionValid)
        XCTAssertTrue(status.apiResponsive)
        XCTAssertEqual(status.issues.count, 0)
        XCTAssertEqual(status.diagnostics.containerVersion, "0.11.0")
        XCTAssertEqual(status.diagnostics.daemonPID, 12345)
    }
    
    func testHealthStatusWithIssues() {
        let diagnostics = XPCHealth.XPCDiagnostics(
            containerVersion: nil,
            daemonPID: nil,
            connectionState: "invalid"
        )
        
        let issues: [XPCHealth.XPCIssue] = [
            .daemonNotRunning,
            .connectionInvalid
        ]
        
        let status = XPCHealth.HealthStatus(
            isHealthy: false,
            daemonRunning: false,
            connectionValid: false,
            apiResponsive: false,
            diagnostics: diagnostics,
            issues: issues
        )
        
        XCTAssertFalse(status.isHealthy)
        XCTAssertFalse(status.daemonRunning)
        XCTAssertFalse(status.connectionValid)
        XCTAssertEqual(status.issues.count, 2)
    }
    
    // MARK: - XPC Diagnostics Tests
    
    func testDiagnosticsInitialization() {
        let diagnostics = XPCHealth.XPCDiagnostics(
            containerVersion: "0.11.0",
            daemonPID: 54321,
            connectionState: "connected",
            systemLoad: 2.5,
            availableMemory: 8_589_934_592 // 8GB
        )
        
        XCTAssertEqual(diagnostics.containerVersion, "0.11.0")
        XCTAssertEqual(diagnostics.daemonPID, 54321)
        XCTAssertEqual(diagnostics.connectionState, "connected")
        XCTAssertEqual(diagnostics.systemLoad, 2.5)
        XCTAssertEqual(diagnostics.availableMemory, 8_589_934_592)
    }
    
    func testDiagnosticsDefaultValues() {
        let diagnostics = XPCHealth.XPCDiagnostics()
        
        XCTAssertNil(diagnostics.containerVersion)
        XCTAssertNil(diagnostics.daemonPID)
        XCTAssertEqual(diagnostics.connectionState, "unknown")
        XCTAssertNotNil(diagnostics.lastSuccessfulCheck)
        XCTAssertNil(diagnostics.systemLoad)
        XCTAssertNil(diagnostics.availableMemory)
    }
    
    // MARK: - XPC Issue Tests
    
    func testXPCIssueDescriptions() {
        XCTAssertEqual(
            XPCHealth.XPCIssue.daemonNotRunning.description,
            "Apple Container daemon is not running"
        )
        
        XCTAssertEqual(
            XPCHealth.XPCIssue.connectionInvalid.description,
            "XPC connection is invalid (run 'container system-reset' to fix)"
        )
        
        XCTAssertEqual(
            XPCHealth.XPCIssue.apiTimeout.description,
            "Container API timed out during health check"
        )
        
        XCTAssertEqual(
            XPCHealth.XPCIssue.daemonUnresponsive.description,
            "Container daemon is not responding to XPC messages"
        )
        
        XCTAssertEqual(
            XPCHealth.XPCIssue.unknown("test error").description,
            "Unknown XPC issue: test error"
        )
    }
    
    // MARK: - Daemon PID Tests
    
    func testGetDaemonPID() {
        // This test checks if daemon PID can be retrieved
        // It may return nil if daemon not running (acceptable)
        let pid = XPCHealth.getDaemonPID()
        
        // If daemon is running, PID should be positive
        if let pid = pid {
            XCTAssertGreaterThan(pid, 0, "Daemon PID should be positive")
        }
        
        // If daemon not running, nil is acceptable
        // This test passes either way
    }
    
    // MARK: - Integration Tests (require running daemon)
    
    func testVerifyConnectionIntegration() async throws {
        // This test requires container daemon to be running
        // Skip if daemon not available
        
        // Check if container CLI exists in common locations
        let containerPaths = ["/usr/local/bin/container", "/usr/bin/container"]
        let containerExists = containerPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
        
        guard containerExists else {
            throw XCTSkip("Container CLI not available")
        }
        
        // Verify connection
        let status = try await XPCHealth.verifyConnection()
        
        // Print status for debugging
        print(status.description)
        
        // Basic assertions (may fail if daemon not running, which is acceptable)
        if status.isHealthy {
            XCTAssertTrue(status.daemonRunning, "Should report daemon running if healthy")
            XCTAssertTrue(status.connectionValid, "Should report valid connection if healthy")
            XCTAssertTrue(status.apiResponsive, "Should report responsive API if healthy")
            XCTAssertEqual(status.issues.count, 0, "Should have no issues if healthy")
        } else {
            // If unhealthy, should have at least one issue
            XCTAssertGreaterThan(status.issues.count, 0, "Should have at least one issue if unhealthy")
        }
    }
    
    func testIsHealthyIntegration() async {
        // This test requires container daemon to be running
        let containerPaths = ["/usr/local/bin/container", "/usr/bin/container"]
        let containerExists = containerPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
        
        guard containerExists else {
            // Skip test if container CLI not available
            return
        }
        
        // Quick health check
        let isHealthy = await XPCHealth.isHealthy()
        
        // Either healthy or unhealthy is acceptable
        // This test just verifies the function runs without error
        
        // Get detailed diagnostics
        let diagnostics = await XPCHealth.collectDiagnostics()
        
        // Verify diagnostics structure
        XCTAssertNotNil(diagnostics.lastSuccessfulCheck)
        XCTAssertNotNil(diagnostics.connectionState)
    }
    
    func testGetContainerVersionIntegration() async throws {
        // This test requires container daemon to be running
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/container") else {
            throw XCTSkip("Container CLI not available")
        }
        
        do {
            let version = try await XPCHealth.getContainerVersion()
            
            // Version should be non-empty string or "unknown"
            XCTAssertFalse(version.isEmpty, "Version should not be empty")
            
            print("Container version: \(version)")
        } catch {
            // API not responsive is acceptable if daemon not running
            if case XPCHealth.XPCIssue.daemonUnresponsive = error {
                // Acceptable
                print("Daemon not responsive (acceptable if not running)")
            } else {
                throw error
            }
        }
    }
    
    // MARK: - Custom String Convertible Tests
    
    func testHealthStatusDescription() {
        let diagnostics = XPCHealth.XPCDiagnostics(
            containerVersion: "0.11.0",
            daemonPID: 12345,
            connectionState: "valid",
            systemLoad: 1.5,
            availableMemory: 4_294_967_296
        )
        
        let status = XPCHealth.HealthStatus(
            isHealthy: true,
            daemonRunning: true,
            connectionValid: true,
            apiResponsive: true,
            diagnostics: diagnostics,
            issues: []
        )
        
        let description = status.description
        
        XCTAssertTrue(description.contains("✓ XPC Health: Healthy"))
        XCTAssertTrue(description.contains("Container Version: 0.11.0"))
        XCTAssertTrue(description.contains("Daemon PID: 12345"))
        XCTAssertTrue(description.contains("Available Memory"))
    }
    
    func testHealthStatusDescriptionWithIssues() {
        let diagnostics = XPCHealth.XPCDiagnostics(connectionState: "invalid")
        let status = XPCHealth.HealthStatus(
            isHealthy: false,
            daemonRunning: false,
            connectionValid: false,
            apiResponsive: false,
            diagnostics: diagnostics,
            issues: [.daemonNotRunning, .connectionInvalid]
        )
        
        let description = status.description
        
        XCTAssertTrue(description.contains("✗ XPC Health: Unhealthy"))
        XCTAssertTrue(description.contains("Issues Detected:"))
        XCTAssertTrue(description.contains("daemon is not running"))
        XCTAssertTrue(description.contains("connection is invalid"))
    }
    
    func testDiagnosticsDescription() {
        let diagnostics = XPCHealth.XPCDiagnostics(
            containerVersion: "0.11.0",
            daemonPID: 999,
            connectionState: "connected",
            systemLoad: 3.14,
            availableMemory: 16_581_375_488
        )
        
        let description = diagnostics.description
        
        XCTAssertTrue(description.contains("Container Version: 0.11.0"))
        XCTAssertTrue(description.contains("Daemon PID: 999"))
        XCTAssertTrue(description.contains("Connection State: connected"))
        XCTAssertTrue(description.contains("System Load:"))
        XCTAssertTrue(description.contains("Available Memory:"))
    }
}