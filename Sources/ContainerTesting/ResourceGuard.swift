//===----------------------------------------------------------------------===//
// ResourceGuard.swift
// Memory Governor Trait for Swift Testing
// Prevents tests from launching when memory is constrained
// Critical for 8GB M2 environments to avoid swap death
//===----------------------------------------------------------------------===//

import Foundation
import Testing

/// Provides real-time memory monitoring for Swift Testing
public struct ResourceHelper {
    
    /// Reads the latest free memory from telemetry CSV
    /// - Parameter logPath: Path to the resource monitor CSV
    /// - Returns: Free memory in MB, or nil if not available
    public static func getLatestFreeMemory(logPath: String? = nil) -> Int? {
        let path = logPath ?? ProcessInfo.processInfo.environment["RESOURCE_LOG_PATH"] 
            ?? "/tmp/resource_monitor.csv"
        
        guard FileManager.default.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            // Fallback to direct system query
            return getSystemFreeMemory()
        }
        
        let lines = contents.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else { return nil }
        
        // Get last data line (skip header)
        let lastLine = lines.last!
        let columns = lastLine.components(separatedBy: ",")
        
        // CSV format: timestamp,free_memory_mb,active_memory_mb,cpu_percent,container_count
        guard columns.count >= 2,
              let freeMemory = Int(columns[1]) else {
            return nil
        }
        
        return freeMemory
    }
    
    /// Direct system memory query (fallback when telemetry not available)
    private static func getSystemFreeMemory() -> Int? {
        // Use vm_stat for macOS
        let task = Process()
        task.launchPath = "/usr/bin/vm_stat"
        task.arguments = []
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        
        // Parse vm_stat output
        var freePages: Int = 0
        var speculativePages: Int = 0
        var inactivePages: Int = 0
        
        for line in output.components(separatedBy: .newlines) {
            if line.contains("Pages free"),
               let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces),
               let num = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                freePages = num
            }
            if line.contains("Pages speculative"),
               let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces),
               let num = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                speculativePages = num
            }
            if line.contains("Pages inactive"),
               let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces),
               let num = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                inactivePages = num
            }
        }
        
        let totalAvailable = freePages + speculativePages + inactivePages
        return (totalAvailable * 4096) / (1024 * 1024)
    }
    
    /// Gets total physical memory
    public static func getTotalMemory() -> Int {
        let task = Process()
        task.launchPath = "/usr/sbin/sysctl"
        task.arguments = ["-n", "hw.memsize"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
              let bytes = UInt64(output) else {
            return 8192 // Fallback: assume 8GB
        }
        
        return Int(bytes / (1024 * 1024))
    }
}

/// Custom trait that guards tests based on available memory
/// Use this for heavy tests to prevent OOM crashes on constrained systems
public struct MemoryGuardTrait: TestScoping, TestTrait, SuiteTrait {

    /// Minimum free memory required (in MB)
    public let minRequiredMB: Int
    
    /// Optional path to telemetry log
    public let telemetryPath: String?
    
    /// Initialize with memory requirement
    /// - Parameters:
    ///   - minRequiredMB: Minimum free memory in MB
    ///   - telemetryPath: Optional path to resource telemetry CSV
    public init(minRequiredMB: Int, telemetryPath: String? = nil) {
        self.minRequiredMB = minRequiredMB
        self.telemetryPath = telemetryPath
    }
    
    public func provideScope(
        for test: Testing.Test,
        testCase: Testing.Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        let freeMemory = ResourceHelper.getLatestFreeMemory(logPath: telemetryPath)
        let totalMemory = ResourceHelper.getTotalMemory()
        
        if let free = freeMemory {
            let enabled = free >= minRequiredMB
            
            if !enabled {
                print("⛔ MEMORY GUARD: Skipping '\(test.name)'")
                print("   Required: \(minRequiredMB)MB free")
                print("   Available: \(free)MB free")
                print("   Total: \(totalMemory)MB")
                print("   Reason: Insufficient memory - test would cause swap pressure")
                return // Skip test
            } else {
                print("✓ Memory Guard: '\(test.name)' can run (\(free)MB >= \(minRequiredMB)MB)")
            }
        } else {
            // If we can't determine memory, be conservative for heavy tests
            print("⚠️  Memory Guard: Cannot determine available memory, allowing test")
        }
        
        // Memory guard passed - run the test
        try await function()
    }
}

/// Extension for convenient trait syntax
extension Trait where Self == MemoryGuardTrait {
    /// Requires minimum free memory for test execution
    /// - Parameter mb: Minimum free memory in MB
    public static func minMemory(_ mb: Int) -> MemoryGuardTrait {
        MemoryGuardTrait(minRequiredMB: mb)
    }
    
    /// Guards for heavy container tests (typically needs 800MB+)
    public static var heavyContainer: MemoryGuardTrait {
        minMemory(800)
    }
    
    /// Guards for medium tests (typically needs 400MB+)
    public static var mediumContainer: MemoryGuardTrait {
        minMemory(400)
    }
    
    /// Guards for lightweight tests (typically needs 200MB+)
    public static var lightweight: MemoryGuardTrait {
        minMemory(200)
    }
}

/// Simple memory check trait for basic enable/disable
public struct MemoryCheckTrait: TestTrait {
    public let minMemoryMB: Int
    
    public init(minMemoryMB: Int) {
        self.minMemoryMB = minMemoryMB
    }
}
