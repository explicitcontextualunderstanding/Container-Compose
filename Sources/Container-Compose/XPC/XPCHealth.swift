//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
// Rights reserved as per Apache License 2.0
//===----------------------------------------------------------------------===//

import ContainerAPIClient
import Foundation

/// XPC health verification and diagnostics for Apple Container runtime
/// Provides pre-flight checks and detailed diagnostics for XPC connections
public enum XPCHealth {
    
    // MARK: - Health Check Results
    
    /// Result of XPC health verification
    public struct HealthStatus: Sendable {
        public let isHealthy: Bool
        public let daemonRunning: Bool
        public let connectionValid: Bool
        public let apiResponsive: Bool
        public let diagnostics: XPCDiagnostics
        public let issues: [XPCIssue]
        
        public init(
            isHealthy: Bool,
            daemonRunning: Bool,
            connectionValid: Bool,
            apiResponsive: Bool,
            diagnostics: XPCDiagnostics,
            issues: [XPCIssue]
        ) {
            self.isHealthy = isHealthy
            self.daemonRunning = daemonRunning
            self.connectionValid = connectionValid
            self.apiResponsive = apiResponsive
            self.diagnostics = diagnostics
            self.issues = issues
        }
    }
    
    /// Collected diagnostic information
    public struct XPCDiagnostics: Sendable {
        public let containerVersion: String?
        public let daemonPID: Int?
        public let connectionState: String
        public let lastSuccessfulCheck: Date
        public let systemLoad: Double?
        public let availableMemory: UInt64?
        
        public init(
            containerVersion: String? = nil,
            daemonPID: Int? = nil,
            connectionState: String = "unknown",
            lastSuccessfulCheck: Date = Date(),
            systemLoad: Double? = nil,
            availableMemory: UInt64? = nil
        ) {
            self.containerVersion = containerVersion
            self.daemonPID = daemonPID
            self.connectionState = connectionState
            self.lastSuccessfulCheck = lastSuccessfulCheck
            self.systemLoad = systemLoad
            self.availableMemory = availableMemory
        }
    }
    
    /// Represents a detected issue with XPC
    public enum XPCIssue: Error, Sendable {
        case daemonNotRunning
        case connectionInvalid
        case apiTimeout
        case daemonUnresponsive
        case unknown(String)
        
        public var description: String {
            switch self {
            case .daemonNotRunning:
                return "Apple Container daemon is not running"
            case .connectionInvalid:
                return "XPC connection is invalid (run 'container system-reset' to fix)"
            case .apiTimeout:
                return "Container API timed out during health check"
            case .daemonUnresponsive:
                return "Container daemon is not responding to XPC messages"
            case .unknown(let message):
                return "Unknown XPC issue: \(message)"
            }
        }
    }
    
    // MARK: - Public API
    
    /// Verify XPC connection can send/receive messages
    /// - Returns: Health status with detailed diagnostics
    /// - Throws: XPCIssue if critical problems detected
    public static func verifyConnection() async throws -> HealthStatus {
        // Collect diagnostics
        let version = try? await getContainerVersion()
        let daemonPID = getDaemonPID()
        let connectionState = await testConnectionState()
        let load = getSystemLoad()
        let memory = getAvailableMemory()
        
        let diagnostics = XPCDiagnostics(
            containerVersion: version,
            daemonPID: daemonPID,
            connectionState: connectionState,
            lastSuccessfulCheck: Date(),
            systemLoad: load,
            availableMemory: memory
        )
        
        // Check for issues
        var issues: [XPCIssue] = []
        
        // Check 1: Daemon running
        let daemonRunning = daemonPID != nil
        if !daemonRunning {
            issues.append(.daemonNotRunning)
        }
        
        // Check 2: Connection valid
        let connectionValid = connectionState == "valid" || connectionState == "connected"
        if !connectionValid && daemonRunning {
            issues.append(.connectionInvalid)
        }
        
        // Check 3: API responsive
        let apiResponsive = version != nil
        if !apiResponsive && daemonRunning && connectionValid {
            issues.append(.daemonUnresponsive)
        }
        
        // Overall health
        let isHealthy = issues.isEmpty && daemonRunning && connectionValid && apiResponsive
        
        return HealthStatus(
            isHealthy: isHealthy,
            daemonRunning: daemonRunning,
            connectionValid: connectionValid,
            apiResponsive: apiResponsive,
            diagnostics: diagnostics,
            issues: issues
        )
    }
    
    /// Quick health check without detailed diagnostics
    /// - Returns: true if XPC is healthy, false otherwise
    public static func isHealthy() async -> Bool {
        do {
            let status = try await verifyConnection()
            return status.isHealthy
        } catch {
            return false
        }
    }
    
    /// Check if container daemon is running
    /// - Returns: PID of daemon if running, nil otherwise
    public static func getDaemonPID() -> Int? {
        // Check if daemon is running via launchctl
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return nil
            }
            
            // Look for com.apple.container process
            // Format: PID  Status  Label
            // Example: 12345  0  com.apple.container
            let lines = output.split(separator: "\n")
            for line in lines {
                if line.contains("com.apple.container") {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    if let pidString = parts.first, let pid = Int(pidString) {
                        return pid
                    }
                }
            }
            
            return nil
        } catch {
            return nil
        }
    }
    
    /// Get container CLI version (tests API responsiveness)
    /// - Returns: Version string if API is responsive
    /// - Throws: Error if API is unresponsive
    public static func getContainerVersion() async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        task.arguments = ["--version"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try task.run()
                
                DispatchQueue.global().async {
                    task.waitUntilExit()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard let output = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: XPCIssue.apiTimeout)
                        return
                    }
                    
                    // Extract version from output
                    // Example output: "container CLI version 0.11.0 (build: release, commit: d9b8a8d)\n"
                    
                    // Pattern 1: "container CLI version X.Y.Z"
                    let pattern1 = #"container CLI version (\d+\.\d+\.\d+)"#
                    if let regex1 = try? NSRegularExpression(pattern: pattern1, options: []),
                       let match = regex1.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)),
                       let range = Range(match.range(at: 1), in: output) {
                        let version = String(output[range])
                        continuation.resume(returning: version)
                        return
                    }
                    
                    // Pattern 2: "version X.Y.Z"
                    let pattern2 = #"version (\d+\.\d+\.\d+)"#
                    if let regex2 = try? NSRegularExpression(pattern: pattern2, options: []),
                       let match = regex2.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)),
                       let range = Range(match.range(at: 1), in: output) {
                        let version = String(output[range])
                        continuation.resume(returning: version)
                        return
                    }
                    
                    // If we got output but couldn't parse version, API is responsive
                    continuation.resume(returning: "unknown")
                }
            } catch {
                continuation.resume(throwing: XPCIssue.daemonUnresponsive)
            }
        }
    }
    
    /// Collect diagnostic information for troubleshooting
    /// - Returns: Detailed diagnostics
    public static func collectDiagnostics() async -> XPCDiagnostics {
        let version = try? await getContainerVersion()
        let daemonPID = getDaemonPID()
        let connectionState = await testConnectionState()
        let load = getSystemLoad()
        let memory = getAvailableMemory()
        
        return XPCDiagnostics(
            containerVersion: version,
            daemonPID: daemonPID,
            connectionState: connectionState,
            lastSuccessfulCheck: Date(),
            systemLoad: load,
            availableMemory: memory
        )
    }
    
// MARK: - Private Helpers
    
    /// Test XPC connection state by making a lightweight API call
    private static func testConnectionState() async -> String {
        do {
            // Try a lightweight operation to verify connection
            _ = try await getContainerVersion()
            return "connected"
        } catch {
            // Check if it's a connection issue vs timeout
            let errorMessage = error.localizedDescription.lowercased()
            if errorMessage.contains("connection") || errorMessage.contains("invalid") {
                return "invalid"
            } else if errorMessage.contains("timeout") {
                return "timeout"
            }
            return "error"
        }
    }
    
    /// Get system load average
    private static func getSystemLoad() -> Double? {
        // getloadavg is thread-safe for reading
        var load = [Double](repeating: 0.0, count: 3)
        let count = getloadavg(&load, 3)
        guard count > 0 else { return nil }
        return load[0] // 1-minute load average
    }
    
    /// Get available memory in bytes
    private static func getAvailableMemory() -> UInt64? {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &vmStats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ptr, &count)
            }
        }
        
        guard result == KERN_SUCCESS else { return nil }
        
        // Get page size using sysctl (thread-safe)
        var pageSize: Int = 0
        var size = MemoryLayout<Int>.size
        let sysctlResult = sysctlbyname("hw.pagesize", &pageSize, &size, nil, 0)
        guard sysctlResult == 0 else { return nil }
        
        let free = UInt64(vmStats.free_count) * UInt64(pageSize)
        return free
    }
}

// MARK: - Custom String Convertibles

extension XPCHealth.HealthStatus: CustomStringConvertible {
    public var description: String {
        let statusIcon = isHealthy ? "✓" : "✗"
        let statusText = isHealthy ? "Healthy" : "Unhealthy"
        
        var desc = "\(statusIcon) XPC Health: \(statusText)\n"
        desc += "  Daemon Running: \(daemonRunning ? "✓" : "✗")\n"
        desc += "  Connection Valid: \(connectionValid ? "✓" : "✗")\n"
        desc += "  API Responsive: \(apiResponsive ? "✓" : "✗")\n"
        
        if !issues.isEmpty {
            desc += "\nIssues Detected:\n"
            for issue in issues {
                desc += "  • \(issue.description)\n"
            }
        }
        
        desc += "\nDiagnostics:\n"
        if let version = diagnostics.containerVersion {
            desc += "  Container Version: \(version)\n"
        }
        if let pid = diagnostics.daemonPID {
            desc += "  Daemon PID: \(pid)\n"
        }
        desc += "  Connection State: \(diagnostics.connectionState)\n"
        if let load = diagnostics.systemLoad {
            desc += "  System Load: \(String(format: "%.2f", load))\n"
        }
        if let memory = diagnostics.availableMemory {
            let mb = Double(memory) / 1_048_576.0
            desc += "  Available Memory: \(String(format: "%.1f", mb)) MB\n"
        }
        
        return desc
    }
}

extension XPCHealth.XPCDiagnostics: CustomStringConvertible {
    public var description: String {
        var desc = "XPC Diagnostics:\n"
        if let version = containerVersion {
            desc += "  Container Version: \(version)\n"
        }
        if let pid = daemonPID {
            desc += "  Daemon PID: \(pid)\n"
        }
        desc += "  Connection State: \(connectionState)\n"
        if let load = systemLoad {
            desc += "  System Load: \(String(format: "%.2f", load))\n"
        }
        if let memory = availableMemory {
            let mb = Double(memory) / 1_048_576.0
            desc += "  Available Memory: \(String(format: "%.1f", mb)) MB\n"
        }
        desc += "  Last Check: \(lastSuccessfulCheck)\n"
        return desc
    }
}