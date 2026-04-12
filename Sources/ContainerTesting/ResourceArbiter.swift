//===----------------------------------------------------------------------===//
// ResourceArbiter.swift
// Execution Mode Arbiter for Container-Compose Tests
// Manages parallel vs serialized execution based on memory and I/O pressure
// CONTINUOUS DYNAMIC ADJUSTMENT - monitors memory every second
//===----------------------------------------------------------------------===//

import Foundation

public enum TestWeight {
    case lightweight
    case medium
    case heavy
    case snapshotHeavy
}

public enum ExecutionMode {
    case parallel
    case serial
    case blocked(reason: String)
}

/// Shared state for signal handling
nonisolated(unsafe) private var _cleanupRunId: String?
nonisolated(unsafe) private var _cleanupEnabled = false

/// Continuous memory monitor for dynamic adjustment
public actor ResourceArbiter {
    public static let shared = ResourceArbiter()
    
    // Dynamic concurrency control
    private var currentMaxInFlight: Int = 4
    private var inFlightCount: Int = 0
    private var snapshotOpsInProgress: Bool = false
    
    // Memory thresholds (dynamically adjusted)
    private var criticalThresholdMB: Int = 300
    private var warningThresholdMB: Int = 500
    private var comfortableThresholdMB: Int = 800
    
    // Cleanup configuration
    private var currentRunId: String?
    private let cleanupScriptPath: String
    
    // Continuous monitoring
    private var monitoringTask: Task<Void, Never>?
    private var isMonitoring: Bool = false
    
    private init() {
        let possiblePaths = [
            "scripts/cleanup-orchestrator.sh",
            "../scripts/cleanup-orchestrator.sh",
            "../../scripts/cleanup-orchestrator.sh",
            "./cleanup-orchestrator.sh"
        ]
        
        var foundPath: String? = nil
        let fileManager = FileManager.default
        
        for path in possiblePaths {
            if fileManager.fileExists(atPath: path) {
                foundPath = path
                break
            }
        }
        
        self.cleanupScriptPath = foundPath ?? "scripts/cleanup-orchestrator.sh"
        
        // Auto-initialize RUN_ID
        if let envRunId = ProcessInfo.processInfo.environment["CCT_RUN_ID"] {
            self.currentRunId = envRunId
            _cleanupRunId = envRunId
            _cleanupEnabled = true
        }
        
        // Install signal handlers
        signal(SIGINT) { _ in handleCleanupSignal(Int32(SIGINT)) }
        signal(SIGTERM) { _ in handleCleanupSignal(Int32(SIGTERM)) }
        
        // Start continuous memory monitoring (async from init)
        Task {
            await startContinuousMonitoring()
        }
    }
    
    /// Continuous memory monitoring - adjusts concurrency every second
    private func startContinuousMonitoring() async {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        while isMonitoring && !Task.isCancelled {
            await adjustConcurrencyBasedOnMemory()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
    }
    
    /// Adjust maxInFlight dynamically based on current memory
    private func adjustConcurrencyBasedOnMemory() async {
        guard let available = ResourceHelper.getSystemFreeMemoryPublic() else { return }
        
        let oldMax = currentMaxInFlight
        
        if available < criticalThresholdMB {
            // Critical: Only 1 test at a time
            currentMaxInFlight = 1
            print("[ResourceArbiter] CRITICAL: Available memory \(available)MB < \(criticalThresholdMB)MB")
            print("[ResourceArbiter] Reducing concurrency to 1 (was \(oldMax))")
        } else if available < warningThresholdMB {
            // Warning: Reduce to 2 tests
            currentMaxInFlight = 2
            if oldMax != 2 {
                print("[ResourceArbiter] WARNING: Available memory \(available)MB < \(warningThresholdMB)MB")
                print("[ResourceArbiter] Reducing concurrency to 2 (was \(oldMax))")
            }
        } else if available < comfortableThresholdMB {
            // Moderate: 3 tests
            currentMaxInFlight = 3
            if oldMax != 3 {
                print("[ResourceArbiter] MODERATE: Available memory \(available)MB")
                print("[ResourceArbiter] Setting concurrency to 3 (was \(oldMax))")
            }
        } else {
            // Comfortable: Full concurrency
            currentMaxInFlight = 4
            if oldMax != 4 {
                print("[ResourceArbiter] COMFORTABLE: Available memory \(available)MB")
                print("[ResourceArbiter] Restoring full concurrency to 4 (was \(oldMax))")
            }
        }
    }
    
    /// Request execution slot with continuous adjustment
    public func requestExecutionSlot(for weight: TestWeight) -> ExecutionMode {
        // Check snapshot operations first
        if weight == .snapshotHeavy || snapshotOpsInProgress {
            return .blocked(reason: "Snapshot operation in progress")
        }
        
        // Heavy tests always serial
        if weight == .heavy {
            return .serial
        }
        
        // Check current in-flight against DYNAMIC max
        if inFlightCount >= currentMaxInFlight {
            return .blocked(reason: "Max in-flight (\(currentMaxInFlight)) reached - memory pressure")
        }
        
        inFlightCount += 1
        return .parallel
    }
    
    public func releaseExecutionSlot(for weight: TestWeight) {
        if inFlightCount > 0 {
            inFlightCount -= 1
        }
    }
    
    public func beginSnapshotOperation() {
        snapshotOpsInProgress = true
    }
    
    public func endSnapshotOperation() {
        snapshotOpsInProgress = false
    }
    
    public func getStatus() -> (inFlight: Int, maxInFlight: Int, memoryMB: Int?) {
        let memory = ResourceHelper.getSystemFreeMemoryPublic()
        return (inFlightCount, currentMaxInFlight, memory)
    }
    
    public func setRunId(_ runId: String) {
        self.currentRunId = runId
        _cleanupRunId = runId
        _cleanupEnabled = true
    }
    
    public func getRunId() -> String? {
        return currentRunId
    }
    
    public func cleanupOnInterrupt() async {
        guard let runId = currentRunId else { return }
        print("[ResourceArbiter] Executing graceful cleanup for RUN_ID: \(runId)")
        
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cleanupScriptPath) else {
            print("[ResourceArbiter] Cleanup script not found")
            return
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [cleanupScriptPath, runId, "--graceful"]
        task.environment = ProcessInfo.processInfo.environment
        
        do {
            try task.run()
            task.waitUntilExit()
            print("[ResourceArbiter] Cleanup completed")
        } catch {
            print("[ResourceArbiter] Cleanup failed: \(error)")
        }
    }
}

private func handleCleanupSignal(_ signal: Int32) {
    guard _cleanupEnabled, let runId = _cleanupRunId else {
        exit(Int32(128) + signal)
    }
    
    print("\n[ResourceArbiter] Signal \(signal) received, triggering cleanup for RUN_ID: \(runId)")
    
    let scriptPath = "scripts/cleanup-orchestrator.sh"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [scriptPath, runId, "--graceful"]
    task.environment = ProcessInfo.processInfo.environment
    
    do {
        try task.run()
        task.waitUntilExit()
        print("[ResourceArbiter] Cleanup completed")
    } catch {
        print("[ResourceArbiter] Cleanup failed: \(error)")
    }
    
    exit(Int32(128) + signal)
}
