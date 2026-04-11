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

    /// Gets the default telemetry path
    public static func getTelemetryPath() -> String {
        return ProcessInfo.processInfo.environment["RESOURCE_LOG_PATH"]
            ?? ProcessInfo.processInfo.environment["TELEMETRY_FILE"]
            ?? "/tmp/resource_monitor.log"
    }

    /// Reads the latest free memory from telemetry CSV
    public static func getLatestFreeMemory(logPath: String? = nil) -> Int? {
        let path = logPath ?? getTelemetryPath()

        guard FileManager.default.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return getSystemFreeMemory()
        }

        let lines = contents.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else { return nil }

        let lastLine = lines.last!
        let columns = lastLine.components(separatedBy: ",")

        guard columns.count >= 2,
              let freeMemory = Int(columns[1]) else {
            return nil
        }

        return freeMemory
    }

    /// Returns truly available memory: free + speculative + inactive
    private static func getSystemFreeMemory() -> Int? {
        let task = Process()
        task.launchPath = "/usr/bin/vm_stat"
        task.arguments = []

        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

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
        return (totalAvailable * 16384) / (1024 * 1024)
    }

    /// Gets memory pressure level: 0=normal, 1=warning, 2=critical
    public static func getMemoryPressureLevel() -> Int {
        guard let available = getSystemFreeMemory() else { return 2 }

        let total = getTotalMemory()
        let availablePercent = Double(available) / Double(total)

        if availablePercent < 0.125 {
            return 2
        } else if availablePercent < 0.375 {
            return 1
        }
        return 0
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
            return 8192
        }

        return Int(bytes / (1024 * 1024))
    }
}

/// Custom trait that guards tests based on available memory
public struct MemoryGuardTrait: TestScoping, TestTrait, SuiteTrait {
    public let minRequiredMB: Int
    public let telemetryPath: String?

    public init(minRequiredMB: Int, telemetryPath: String? = nil) {
        self.minRequiredMB = minRequiredMB
        self.telemetryPath = telemetryPath
    }

    /// Provide scope with memory guard check
    /// Set MEMORY_GUARD_MODE=LOG_ONLY to log but not skip (for profiling)
    public func provideScope(
        for test: Testing.Test,
        testCase: Testing.Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        let freeMemory = ResourceHelper.getLatestFreeMemory(logPath: telemetryPath)
        let totalMemory = ResourceHelper.getTotalMemory()
        let pressureLevel = ResourceHelper.getMemoryPressureLevel()

        // Check for profiling mode (log-only, don't skip)
        let profilingMode = ProcessInfo.processInfo.environment["MEMORY_GUARD_MODE"] == "LOG_ONLY"

        let actualThreshold: Int
        switch pressureLevel {
        case 2:
            actualThreshold = Int(Double(totalMemory) * 0.15)
        case 1:
            actualThreshold = Int(Double(totalMemory) * 0.25)
        default:
            actualThreshold = minRequiredMB
        }

        if let free = freeMemory {
            let enabled = free >= actualThreshold

            if !enabled {
                if profilingMode {
                    // In profiling mode: log but still run the test
                    print("[PROFILE] Memory Guard would skip '\(test.name)' (\(free)MB < \(actualThreshold)MB)")
                    print("[PROFILE] But running anyway to capture peak usage")
                } else {
                    // Normal mode: skip the test
                    print("MEMORY GUARD: Skipping '\(test.name)'")
                    print("  Required: \(actualThreshold)MB (dynamic)")
                    print("  Available: \(free)MB")
                    print("  Total: \(totalMemory)MB")
                    return
                }
            } else {
                print("Memory Guard: '\(test.name)' OK (\(free)MB >= \(actualThreshold)MB)")
            }
        } else {
            if pressureLevel >= 2 && !profilingMode {
                print("MEMORY GUARD: Skipping (critical pressure)")
                return
            }
            if profilingMode && pressureLevel >= 2 {
                print("[PROFILE] Critical pressure but running anyway for profiling")
            } else {
                print("Memory Guard: Allowing (pressure OK)")
            }
        }

        try await function()
    }
}

extension Trait where Self == MemoryGuardTrait {
    public static func minMemory(_ mb: Int) -> MemoryGuardTrait {
        MemoryGuardTrait(minRequiredMB: mb)
    }

    public static var heavyContainer: MemoryGuardTrait {
        minMemory(800)
    }

    public static var mediumContainer: MemoryGuardTrait {
        minMemory(400)
    }

    public static var lightweight: MemoryGuardTrait {
        minMemory(200)
    }
}

/// Simple memory check trait
public struct MemoryCheckTrait: TestTrait {
    public let minMemoryMB: Int

    public init(minMemoryMB: Int) {
        self.minMemoryMB = minMemoryMB
    }
}
