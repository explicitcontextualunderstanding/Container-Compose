//===----------------------------------------------------------------------===//
// ResourceGuard.swift
// Memory Governor Trait for Swift Testing
// WARN MODE: Records telemetry, runs tests, only skips at critical levels
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import TestHelpers

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

        guard columns.count >= 2,
              let freeMemory = Int(columns[1]) else {
            return nil
        }

        return freeMemory
    }

    internal static func getSystemFreeMemory() -> Int? {
        // Use 'memory_pressure' for more accurate available memory
        // vm_stat's "free" is misleading on macOS - much more is available
        let task = Process()
        task.launchPath = "/usr/bin/memory_pressure"
        task.arguments = ["-Q"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return getFallbackMemory()
        }

        // Parse: "The system has X percent free memory"
        if let match = output.range(of: #"(\d+)(\.\d+)? percent free"#, options: .regularExpression),
           let percentStr = output[match].components(separatedBy: CharacterSet.letters).first,
           let percent = Double(percentStr.trimmingCharacters(in: .whitespaces)) {
            let total = getTotalMemory()
            return Int(Double(total) * (percent / 100.0))
        }

        return getFallbackMemory()
    }

    private static func getFallbackMemory() -> Int? {
        // Fallback: Use vm_stat but add compressed + purgeable
        let task = Process()
        task.launchPath = "/usr/bin/vm_stat"
        task.arguments = []

        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()

        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }

        var availablePages: Int = 0

        for line in output.components(separatedBy: .newlines) {
            // Count ALL reclaimable memory
            for key in ["Pages free", "Pages speculative", "Pages inactive",
                       "Pages purgeable", "Pages occupied by compressor"] {
                if line.contains(key),
                   let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces),
                   let num = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                    availablePages += num
                }
            }
        }

        return (availablePages * 16384) / (1024 * 1024)
    }

    public static func getSystemFreeMemoryPublic() -> Int? {
        return getSystemFreeMemory()
    }

    public static func getMemoryPressureLevel() -> Int {
        // Use actual memory_pressure command for accurate system pressure
        let task = Process()
        task.launchPath = "/usr/bin/memory_pressure"
        task.arguments = ["-Q"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()

        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let match = output.range(of: #"(\d+)(\.\d+)? percent free"#, options: .regularExpression),
              let percentStr = output[match].components(separatedBy: CharacterSet.letters).first,
              let percentFree = Double(percentStr.trimmingCharacters(in: .whitespaces)) else {
            // Fallback: use available memory calculation
            guard let available = getSystemFreeMemory() else { return 2 }
            let total = getTotalMemory()
            let availablePercent = Double(available) / Double(total) * 100
            return availablePercent < 15 ? 2 : availablePercent < 50 ? 1 : 0
        }

        // Convert percent free to pressure level
        // >85% free = Green (0), 50-85% = Yellow (1), <50% = Red (2)
        if percentFree > 85 {
            return 0  // Green - plenty available
        } else if percentFree > 50 {
            return 1  // Yellow - some pressure
        }
        return 2  // Red - high pressure
    }

    /// Get available memory using macOS memory_pressure (state-of-the-art)
    public static func getAvailableMemoryMB() -> Int? {
        let task = Process()
        task.launchPath = "/usr/bin/memory_pressure"
        task.arguments = ["-Q"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()

        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let match = output.range(of: #"(\d+)(\.\d+)? percent free"#, options: .regularExpression),
              let percentStr = output[match].components(separatedBy: CharacterSet.letters).first,
              let percentFree = Double(percentStr.trimmingCharacters(in: .whitespaces)) else {
            return getSystemFreeMemory()  // Fallback
        }

        let total = getTotalMemory()
        return Int(Double(total) * (percentFree / 100.0))
    }

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

/// Custom trait that warns about memory but runs tests to collect telemetry
public struct MemoryGuardTrait: TestScoping, TestTrait, SuiteTrait {
    public let minRequiredMB: Int
    public let telemetryPath: String?
    public let image: String?

    public init(minRequiredMB: Int, telemetryPath: String? = nil, image: String? = nil) {
        self.minRequiredMB = minRequiredMB
        self.telemetryPath = telemetryPath
        self.image = image
    }

    public func provideScope(
        for test: Testing.Test,
        testCase: Testing.Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        // Use accurate available memory (not misleading "free")
        let availableMemory = ResourceHelper.getAvailableMemoryMB()
        let pressureLevel = ResourceHelper.getMemoryPressureLevel()
        let estimatedThreshold = resolveThreshold()

        // WARN MODE: Log memory state, run test, only skip at critical pressure
        // Critical: Red pressure (< 50% free) + very low absolute memory (< 500MB)
        if let available = availableMemory {
            if pressureLevel >= 2 && available < 500 {
                // Critical: High pressure AND low absolute memory
                print("🛑 MEMORY CRITICAL: '\(test.name)' SKIPPED")
                print(" Available: \(available)MB (< 500MB) | Pressure: RED")
                print(" Estimated need: \(estimatedThreshold)MB")
                return
            } else if pressureLevel >= 1 {
                // Yellow/Red pressure but sufficient absolute: warn and run
                let color = pressureLevel == 2 ? "🔴" : "🟡"
                print("\(color) MEMORY PRESSURE: '\(test.name)' running (\(available)MB available)")
            } else {
                // Green pressure: comfortable
                print("🟢 '\(test.name)' OK (\(available)MB available, pressure: GREEN)")
            }
        } else {
            // Unknown memory state - assume OK and attempt
            print("⚠️  MEMORY UNKNOWN: '\(test.name)' attempting anyway")
        }

        // ALWAYS run the test to collect empirical data
        try await function()

        // Post-test: log actual usage if we can get it
        if let available = availableMemory {
            print("📊 TELEMETRY: '\(test.name)' - Available: \(available)MB, Estimated: \(estimatedThreshold)MB")
        }
    }

    /// Look up empirical profile for the image, fall back to static minRequiredMB
    private func resolveThreshold() -> Int {
        guard let image else { return minRequiredMB }

        let profiles = ContainerTelemetry.shared.loadProfiles()
        guard let profile = profiles.first(where: { $0.image.contains(image) }) else {
            return minRequiredMB // No profile yet — use static fallback
        }

        let empirical = Int(profile.memoryGateMB)
        if empirical < minRequiredMB {
            return empirical
        }
        return minRequiredMB
    }
}

extension Trait where Self == MemoryGuardTrait {
    public static func minMemory(_ mb: Int) -> MemoryGuardTrait {
        MemoryGuardTrait(minRequiredMB: mb)
    }

    /// Empirical gate: looks up ContainerProfile for the image
    public static func empiricalMemory(image: String, fallbackMB: Int = 450) -> MemoryGuardTrait {
        MemoryGuardTrait(minRequiredMB: fallbackMB, image: image)
    }

    /// Static fallback thresholds
    public static var heavyContainer: MemoryGuardTrait {
        minMemory(450)
    }

    public static var mediumContainer: MemoryGuardTrait {
        minMemory(270)
    }

    public static var lightweight: MemoryGuardTrait {
        minMemory(140)
    }
}

/// Simple memory check trait
public struct MemoryCheckTrait: TestTrait {
    public let minMemoryMB: Int

    public init(minMemoryMB: Int) {
        self.minMemoryMB = minMemoryMB
    }
}

/// Actor for dynamic memory monitoring during test execution
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
                        print("⚠️  DYNAMIC MEMORY WARNING: \(available)MB < \(minRequiredMB)MB")
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

    public func checkMemory() -> (passes: Bool, available: Int?) {
        let available = ResourceHelper.getSystemFreeMemoryPublic()
        if let free = available {
            return (free >= minRequiredMB, free)
        }
        return (false, nil)
    }
}
