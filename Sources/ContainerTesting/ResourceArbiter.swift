//===----------------------------------------------------------------------===//
// ResourceArbiter.swift
// Execution Mode Arbiter for Container-Compose Tests
// Manages parallel vs serialized execution based on memory and I/O pressure
//===----------------------------------------------------------------------===//

import Foundation

public enum TestWeight {
    case lightweight   // pgmicro, nginx, redis, busybox
    case medium        // single container, no disk
    case heavy         // wordpress, mysql, multi-container
    case snapshotHeavy // tests that trigger Apple Container snapshots
}

public enum ExecutionMode {
    case parallel
    case serial
    case blocked(reason: String)
}

public actor ResourceArbiter {
    public static let shared = ResourceArbiter()

    private var inFlightCount: Int = 0
    private var snapshotOpsInProgress: Bool = false
    private let maxInFlightLightweight = 3

    private let memoryThresholdMB = 1024  // 1GB - force serial below this
    private let ioPressureThreshold = 5   // block new tests if too many I/O ops

    private init() {}

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
}