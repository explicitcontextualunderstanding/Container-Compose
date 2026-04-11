//===----------------------------------------------------------------------===//
// ResourceArbiter.swift
// Execution Mode Arbiter for Container-Compose Tests
// Manages parallel vs serialized execution based on memory and I/O pressure
//===----------------------------------------------------------------------===//

import Foundation

public enum TestWeight {
    case lightweight // pgmicro, nginx, redis, busybox
    case medium // single container, no disk
    case heavy // wordpress, mysql, multi-container
    case snapshotHeavy // tests that trigger Apple Container snapshots
}

public enum ExecutionMode {
    case parallel
    case serial
    case blocked(reason: String)
}

/// Shared state for signal handling - marked nonisolated(unsafe) for C interop
nonisolated(unsafe) private var _cleanupRunId: String?
nonisolated(unsafe) private var _cleanupEnabled = false

public actor ResourceArbiter {
    public static let shared = ResourceArbiter()

    private var inFlightCount: Int = 0
    private var snapshotOpsInProgress: Bool = false
    private let maxInFlightLightweight = 3

    private let memoryThresholdMB = 1024 // 1GB - force serial below this
    private let ioPressureThreshold = 5 // block new tests if too many I/O ops

    // Cleanup configuration
    private var currentRunId: String?
    private let cleanupScriptPath: String

    private init() {
        // Determine cleanup script path
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

        // Auto-initialize RUN_ID from environment (set by run-tests.sh)
        if let envRunId = ProcessInfo.processInfo.environment["CCT_RUN_ID"] {
            self.currentRunId = envRunId
            _cleanupRunId = envRunId
            _cleanupEnabled = true
            print("[ResourceArbiter] Auto-initialized from environment: RUN_ID=\(envRunId)")
        }

        // Install signal handlers once at initialization
        signal(SIGINT) { _ in
            handleCleanupSignal(Int32(SIGINT))
        }

        signal(SIGTERM) { _ in
            handleCleanupSignal(Int32(SIGTERM))
        }
    }

    /// Sets the current test run ID for cleanup tracking
    public func setRunId(_ runId: String) {
        self.currentRunId = runId
        // Update global state for signal handler
        _cleanupRunId = runId
        _cleanupEnabled = true
    }

    /// Gets the current test run ID
    public func getRunId() -> String? {
        return currentRunId
    }

    /// Triggered by signal handlers - performs graceful cleanup
    public func cleanupOnInterrupt() async {
        guard let runId = currentRunId else {
            print("[ResourceArbiter] No RUN_ID set, skipping cleanup")
            return
        }

        print("[ResourceArbiter] Executing graceful cleanup for RUN_ID: \(runId)")

        // Check if cleanup script exists
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cleanupScriptPath) else {
            print("[ResourceArbiter] Cleanup script not found at \(cleanupScriptPath)")
            return
        }

        // Execute cleanup script with --graceful mode
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [cleanupScriptPath, runId, "--graceful"]

        // Set environment variables for the script
        var environment = ProcessInfo.processInfo.environment
        environment["TELEMETRY_FILE"] = ResourceHelper.getTelemetryPath()
        task.environment = environment

        // Capture output
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: outputData, encoding: .utf8) {
                print(output)
            }

            if task.terminationStatus == 0 {
                print("[ResourceArbiter] Cleanup completed successfully")
            } else {
                print("[ResourceArbiter] Cleanup exited with status \(task.terminationStatus)")
            }
        } catch {
            print("[ResourceArbiter] Failed to execute cleanup: \(error)")
        }
    }

    /// Called on deinit to ensure cleanup runs
    public func ensureCleanupOnDeinit() {
        guard let runId = currentRunId else { return }

        // Only run cleanup if we have active containers
        if inFlightCount > 0 {
            print("[ResourceArbiter] Deinit guard: Cleaning up RUN_ID \(runId)")

            // Run synchronously since we're in deinit
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [cleanupScriptPath, runId, "--graceful"]

            do {
                try task.run()
                task.waitUntilExit()
                print("[ResourceArbiter] Deinit cleanup completed")
            } catch {
                print("[ResourceArbiter] Deinit cleanup failed: \(error)")
            }
        }
    }

    public func requestExecutionSlot(for weight: TestWeight) -> ExecutionMode {
        let freeMemory = ResourceHelper.getLatestFreeMemory() ?? 8192

        if weight == .snapshotHeavy || snapshotOpsInProgress {
            return .blocked(reason: "Snapshot operation in progress - preventing I/O pile-up")
        }

        if freeMemory < memoryThresholdMB {
            return .serial
        }

        if weight == .heavy {
            return .serial
        }

        if weight == .lightweight {
            if inFlightCount >= maxInFlightLightweight {
                return .blocked(reason: "Max in-flight containers (\(maxInFlightLightweight)) reached")
            }
            inFlightCount += 1
            return .parallel
        }

        return .parallel
    }

    public func releaseExecutionSlot(for weight: TestWeight) {
        if weight == .lightweight && inFlightCount > 0 {
            inFlightCount -= 1
        }
    }

    public func beginSnapshotOperation() {
        snapshotOpsInProgress = true
    }

    public func endSnapshotOperation() {
        snapshotOpsInProgress = false
    }

    public func getStatus() -> (inFlight: Int, snapshotting: Bool, memoryMB: Int?) {
        let freeMemory = ResourceHelper.getLatestFreeMemory()
        return (inFlightCount, snapshotOpsInProgress, freeMemory)
    }

    /// Executes emergency cleanup when memory is critically low
    public func emergencyCleanup() async {
        guard let runId = currentRunId else {
            print("[ResourceArbiter] No RUN_ID set, cannot perform emergency cleanup")
            return
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cleanupScriptPath) else {
            print("[ResourceArbiter] Cleanup script not found")
            return
        }

        print("[ResourceArbiter] Executing EMERGENCY cleanup for RUN_ID: \(runId)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [cleanupScriptPath, runId, "--emergency"]

        var environment = ProcessInfo.processInfo.environment
        environment["TELEMETRY_FILE"] = ResourceHelper.getTelemetryPath()
        task.environment = environment

        do {
            try task.run()
            task.waitUntilExit()
            print("[ResourceArbiter] Emergency cleanup completed")
        } catch {
            print("[ResourceArbiter] Emergency cleanup failed: \(error)")
        }
    }
}

// C-compatible signal handler using the global unsafe state
private func handleCleanupSignal(_ signal: Int32) {
    guard _cleanupEnabled, let runId = _cleanupRunId else {
        exit(Int32(128) + signal)
    }

    print("\n[ResourceArbiter] Signal \(signal) received, triggering cleanup for RUN_ID: \(runId)")

    // Execute cleanup synchronously before exit
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
