//===----------------------------------------------------------------------===//
// ResourceGuard.swift
// Memory Governor Trait for Swift Testing
//===----------------------------------------------------------------------===//

import Foundation
import Testing

/// Provides real-time memory monitoring for Swift Testing
public struct ResourceHelper {

    public static func getTelemetryPath() -> String {
        return ProcessInfo.processInfo.environment["RESOURCE_LOG_PATH"]
            ?? ProcessInfo.processInfo.environment["TELEMETRY_FILE"]
            ?? "/tmp/resource_monitor.log"
    }

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
        guard columns.count >= 2, let freeMemory = Int(columns[1]) else { return nil }
        return freeMemory
    }

    internal static func getSystemFreeMemory() -> Int? {
        let task = Process()
        task.launchPath = "/usr/bin/vm_stat"
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        var freePages: Int = 0, speculativePages: Int = 0, inactivePages: Int = 0
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
        return (freePages + speculativePages + inactivePages) * 16384 / (1024 * 1024)
    }

    public static func getSystemFreeMemoryPublic() -> Int? {
        return getSystemFreeMemory()
    }

    public static func getMemoryPressureLevel() -> Int {
        guard let available = getSystemFreeMemory() else { return 2 }
        let total = getTotalMemory()
        let availablePercent = Double(available) / Double(total)
        if availablePercent < 0.125 { return 2 }
        else if availablePercent < 0.375 { return 1 }
        return 0
    }

    public static func getTotalMemory() -> Int {
        let task = Process()
        task.launchPath = "/usr/sbin/sysctl"
        task.arguments = ["-n", "hw.memsize"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
              let bytes = UInt64(output) else { return 8192 }
        return Int(bytes / (1024 * 1024))
    }
}

public struct MemoryGuardTrait: TestScoping, TestTrait, SuiteTrait {
    public let minRequiredMB: Int
    public let telemetryPath: String?

    public init(minRequiredMB: Int, telemetryPath: String? = nil) {
        self.minRequiredMB = minRequiredMB
        self.telemetryPath = telemetryPath
    }

    public func provideScope(for test: Testing.Test, testCase: Testing.Test.Case?, performing function: () async throws -> Void) async throws {
        let freeMemory = ResourceHelper.getLatestFreeMemory(logPath: telemetryPath)
        let totalMemory = ResourceHelper.getTotalMemory()
        let pressureLevel = ResourceHelper.getMemoryPressureLevel()
        let profilingMode = ProcessInfo.processInfo.environment["MEMORY_GUARD_MODE"] == "LOG_ONLY"

        let actualThreshold: Int
        switch pressureLevel {
        case 2: actualThreshold = Int(Double(totalMemory) * 0.15)
        case 1: actualThreshold = Int(Double(totalMemory) * 0.25)
        default: actualThreshold = minRequiredMB
        }

        if let free = freeMemory {
            if free < actualThreshold {
                if profilingMode {
                    print("[PROFILE] Would skip '\(test.name)' (\(free)MB < \(actualThreshold)MB)")
                } else {
                    print("MEMORY GUARD: Skipping '\(test.name)' - need \(actualThreshold)MB, have \(free)MB")
                    return
                }
            } else {
                print("Memory Guard: '\(test.name)' OK (\(free)MB >= \(actualThreshold)MB)")
            }
        }

        try await function()
    }
}

extension Trait where Self == MemoryGuardTrait {
    public static func minMemory(_ mb: Int) -> MemoryGuardTrait { MemoryGuardTrait(minRequiredMB: mb) }
    public static var heavyContainer: MemoryGuardTrait { minMemory(400) }
    public static var mediumContainer: MemoryGuardTrait { minMemory(550) }
    public static var lightweight: MemoryGuardTrait { minMemory(700) }
}

public struct MemoryCheckTrait: TestTrait {
    public let minMemoryMB: Int
    public init(minMemoryMB: Int) { self.minMemoryMB = minMemoryMB }
}

public actor DynamicMemoryMonitor {
    private var isMonitoring = false
    private var checkInterval: TimeInterval
    private var minRequiredMB: Int
    private var currentTask: Task<Void, Never>?

    public init(minRequiredMB: Int, checkInterval: TimeInterval = 1.0) {
        self.minRequiredMB = minRequiredMB
        self.checkInterval = checkInterval
    }

    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        currentTask = Task {
            while isMonitoring && !Task.isCancelled {
                if let available = ResourceHelper.getSystemFreeMemoryPublic() {
                    if available < minRequiredMB {
                        print("⚠️ MEMORY PRESSURE: \(available)MB < \(minRequiredMB)MB")
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            }
        }
    }

    public func stopMonitoring() {
        isMonitoring = false
        currentTask?.cancel()
        currentTask = nil
    }
}
