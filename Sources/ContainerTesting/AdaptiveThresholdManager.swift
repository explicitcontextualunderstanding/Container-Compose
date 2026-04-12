//===----------------------------------------------------------------------===//
// AdaptiveThresholdManager.swift
// Continuously adjusts test thresholds based on real-time memory conditions
// Allows heavy tests to run when memory frees up, skip when constrained
//===----------------------------------------------------------------------===//

import Foundation
import Testing

/// Manages adaptive thresholds that change based on available memory
public actor AdaptiveThresholdManager {
    public static let shared = AdaptiveThresholdManager()
    
    /// Current memory state
    public struct MemoryState: Sendable {
        public let freeMB: Int
        public let totalMB: Int
        public let pressureLevel: Int // 0=normal, 1=warning, 2=critical
        public let timestamp: Date
        
        public var canRunHeavy: Bool { freeMB >= 450 }
        public var canRunMedium: Bool { freeMB >= 270 }
        public var canRunLightweight: Bool { freeMB >= 140 }
        
        public var recommendedTestWeight: TestWeight {
            if canRunHeavy { return .heavy }
            if canRunMedium { return .medium }
            if canRunLightweight { return .lightweight }
            return .none
        }
    }
    
    public enum TestWeight: Sendable {
        case heavy      // 450MB+
        case medium     // 270-449MB
        case lightweight // 140-269MB
        case none       // <140MB
        
        public var thresholdMB: Int {
            switch self {
            case .heavy: return 450
            case .medium: return 270
            case .lightweight: return 140
            case .none: return 0
            }
        }
    }
    
    /// History of memory states for trend analysis
    private var memoryHistory: [MemoryState] = []
    private let maxHistorySize = 10
    
    /// Callbacks for threshold changes
    private var thresholdChangeCallbacks: [(TestWeight) -> Void] = []
    
    /// Current adaptive threshold
    private(set) var currentAdaptiveThreshold: TestWeight = .heavy
    
    /// Update interval in seconds
    private let updateInterval: TimeInterval = 2.0
    
    /// Background monitoring task
    private var monitorTask: Task<Void, Never>?
    
    /// Start continuous monitoring
    public func startMonitoring() {
        guard monitorTask == nil else { return }
        
        monitorTask = Task {
            while !Task.isCancelled {
                await updateMemoryState()
                try? await Task.sleep(nanoseconds: UInt64(updateInterval * 1_000_000_000))
            }
        }
    }
    
    /// Stop monitoring
    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }
    
    /// Get current memory state
    public func getCurrentState() -> MemoryState {
        let free = ResourceHelper.getLatestFreeMemory() ?? 0
        let total = ResourceHelper.getTotalMemory()
        let pressure = ResourceHelper.getMemoryPressureLevel()
        
        return MemoryState(
            freeMB: free,
            totalMB: total,
            pressureLevel: pressure,
            timestamp: Date()
        )
    }
    
    /// Update memory state and trigger threshold adjustments
    private func updateMemoryState() async {
        let state = getCurrentState()
        
        // Add to history
        memoryHistory.append(state)
        if memoryHistory.count > maxHistorySize {
            memoryHistory.removeFirst()
        }
        
        // Check if threshold should change
        let newThreshold = state.recommendedTestWeight
        if newThreshold != currentAdaptiveThreshold {
            let oldThreshold = currentAdaptiveThreshold
            currentAdaptiveThreshold = newThreshold
            
            print("🔄 ADAPTIVE THRESHOLD: Changed from \(oldThreshold) to \(newThreshold)")
            print("   Free memory: \(state.freeMB)MB (pressure: \(state.pressureLevel))")
            print("   Can run: Heavy=\(state.canRunHeavy), Medium=\(state.canRunMedium), Light=\(state.canRunLightweight)")
            
            // Notify callbacks
            for callback in thresholdChangeCallbacks {
                callback(newThreshold)
            }
        }
    }
    
    /// Register callback for threshold changes
    public func onThresholdChange(_ callback: @escaping (TestWeight) -> Void) {
        thresholdChangeCallbacks.append(callback)
    }
    
    /// Check if a specific test can run with current memory
    public func canRun(testWeight: TestWeight) -> Bool {
        let state = getCurrentState()
        
        switch testWeight {
        case .heavy:
            return state.canRunHeavy
        case .medium:
            return state.canRunMedium
        case .lightweight:
            return state.canRunLightweight
        case .none:
            return false
        }
    }
    
    /// Get trend analysis (is memory improving?)
    public func getMemoryTrend() -> Trend {
        guard memoryHistory.count >= 2 else { return .stable }
        
        let recent = memoryHistory.suffix(5)
        let avgRecent = recent.map { $0.freeMB }.reduce(0, +) / recent.count
        let avgOlder = memoryHistory.prefix(memoryHistory.count - 5).map { $0.freeMB }.reduce(0, +) / (memoryHistory.count - 5)
        
        if avgRecent > avgOlder + 50 {
            return .improving
        } else if avgRecent < avgOlder - 50 {
            return .degrading
        }
        return .stable
    }
    
    public enum Trend: Sendable {
        case improving
        case stable
        case degrading
    }
    
    /// Wait for memory to become available for a specific test
    public func waitForMemory(
        testWeight: TestWeight,
        timeout: TimeInterval = 60.0,
        pollInterval: TimeInterval = 2.0
    ) async -> Bool {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            if canRun(testWeight: testWeight) {
                return true
            }
            
            let state = getCurrentState()
            let needed = testWeight.thresholdMB - state.freeMB
            print("⏳ Waiting for \(needed)MB more memory to run \(testWeight) test...")
            print("   Current: \(state.freeMB)MB, Need: \(testWeight.thresholdMB)MB")
            
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        
        return false
    }
    
    /// Print current status
    public func printStatus() {
        let state = getCurrentState()
        let trend = getMemoryTrend()
        
        print("")
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║           ADAPTIVE THRESHOLD MANAGER STATUS                  ║")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║  Free Memory:      \(state.freeMB)MB / \(state.totalMB)MB           ║")
        print("║  Pressure Level:   \(state.pressureLevel) (0=normal, 2=critical)       ║")
        print("║  Trend:            \(trend)                                    ║")
        print("║  Current Adaptive:  \(currentAdaptiveThreshold)                               ║")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║  Test Availability:                                          ║")
        print("║    Heavy (450MB):   \(state.canRunHeavy ? "✅ YES" : "❌ NO")                    ║")
        print("║    Medium (270MB):   \(state.canRunMedium ? "✅ YES" : "❌ NO")                    ║")
        print("║    Light (140MB):    \(state.canRunLightweight ? "✅ YES" : "❌ NO")                    ║")
        print("╚══════════════════════════════════════════════════════════════╝")
        print("")
    }
}

// MARK: - Integration with MemoryGuardTrait

public extension MemoryGuardTrait {
    /// Check with adaptive threshold manager
    static func checkAdaptive(for test: Testing.Test) async -> Bool {
        let manager = AdaptiveThresholdManager.shared
        let weight = getTestWeight(from: test)
        return await manager.canRun(testWeight: weight)
    }
    
    private static func getTestWeight(from test: Testing.Test) -> AdaptiveThresholdManager.TestWeight {
        let name = test.name.lowercased()
        if name.contains("heavy") || name.contains("wordpress") || name.contains("mysql") {
            return .heavy
        } else if name.contains("medium") || name.contains("postgres") || name.contains("redis") {
            return .medium
        }
        return .lightweight
    }
}
