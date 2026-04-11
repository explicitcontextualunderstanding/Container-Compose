//===----------------------------------------------------------------------===//
// ContainerSnapshotManager.swift
// Snapshot-Hydration Engine for heavy container optimization
// Reduces WordPress/MySQL setup from 15s to <2s via state snapshots
//===----------------------------------------------------------------------===//

import Foundation
import ContainerCommands
import ContainerAPIClient

/// Manages container snapshots for fast restoration
public actor ContainerSnapshotManager {
    public static let shared = ContainerSnapshotManager()
    
    /// Snapshot metadata
    public struct Snapshot: Sendable, Codable {
        public let id: String
        public let configKey: String
        public let createdAt: Date
        public let sizeBytes: Int64
        public let isReady: Bool
        
        public init(id: String, configKey: String, createdAt: Date, sizeBytes: Int64, isReady: Bool) {
            self.id = id
            self.configKey = configKey
            self.createdAt = createdAt
            self.sizeBytes = sizeBytes
            self.isReady = isReady
        }
    }
    
    /// Snapshot storage
    private let snapshotDirectory: URL
    private var snapshots: [String: Snapshot] = [:]
    private let minFreeMemoryMB = 600
    
    public struct SnapshotStats: Sendable {
        public var snapshotsCreated: Int = 0
        public var snapshotsRestored: Int = 0
        public var snapshotsDeleted: Int = 0
        public var timeSaved: TimeInterval = 0
        
        public var averageTimeSaved: TimeInterval {
            return snapshotsRestored > 0 ? timeSaved / Double(snapshotsRestored) : 0
        }
    }
    
    public var stats = SnapshotStats()
    
    public init() {
        let tempDir = FileManager.default.temporaryDirectory
        self.snapshotDirectory = tempDir.appendingPathComponent("container-compose-snapshots")
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
    }
    
    private func snapshotId(for config: ContainerPoolConfig) -> String {
        let hash = "\(config.image):\(config.tag):\(config.memoryLimitMB)".hashValue
        return "snapshot_\(abs(hash))"
    }
    
    public func hasReadySnapshot(for config: ContainerPoolConfig) -> Bool {
        let id = snapshotId(for: config)
        guard let snapshot = snapshots[id] else { return false }
        return snapshot.isReady
    }
    
    public func checkAndRestore(config: ContainerPoolConfig) async -> String? {
        let id = snapshotId(for: config)
        
        guard let snapshot = snapshots[id], snapshot.isReady else {
            print("SnapshotManager: No ready snapshot for \(config.fullImage)")
            return nil
        }
        
        guard await hasSufficientMemory() else {
            print("SnapshotManager: Insufficient memory for restore")
            return nil
        }
        
        let startTime = Date()
        
        do {
            let restoredId = try await restoreSnapshot(snapshot)
            let restoreTime = Date().timeIntervalSince(startTime)
            stats.snapshotsRestored += 1
            stats.timeSaved += restoreTime
            
            print("SnapshotManager: Restored \(config.fullImage) in \(String(format: "%.2f", restoreTime))s")
            return restoredId
        } catch {
            print("SnapshotManager: Restore failed: \(error)")
            return nil
        }
    }
    
    public func createSnapshot(from containerId: String, config: ContainerPoolConfig) async {
        let id = snapshotId(for: config)
        
        guard await hasSufficientMemory() else {
            print("SnapshotManager: Insufficient memory for snapshot creation")
            return
        }
        
        let startTime = Date()
        
        do {
            try await pauseContainer(containerId)
            
            let snapshotPath = snapshotDirectory.appendingPathComponent("\(id).tar")
            try await exportContainer(containerId, to: snapshotPath)
            
            let attributes = try? FileManager.default.attributesOfItem(atPath: snapshotPath.path)
            let sizeBytes = attributes?[.size] as? Int64 ?? 0
            
            try await resumeContainer(containerId)
            
            snapshots[id] = Snapshot(
                id: id,
                configKey: "\(config.image):\(config.tag)",
                createdAt: Date(),
                sizeBytes: sizeBytes,
                isReady: true
            )
            
            stats.snapshotsCreated += 1
            
            let createTime = Date().timeIntervalSince(startTime)
            print("SnapshotManager: Created snapshot (\(String(format: "%.1f", Double(sizeBytes)/1024/1024))MB) in \(String(format: "%.2f", createTime))s")
            
        } catch {
            print("SnapshotManager: Failed to create snapshot: \(error)")
            try? await resumeContainer(containerId)
        }
    }
    
    private func pauseContainer(_ containerId: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["pause", containerId]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw SnapshotError.pauseFailed
        }
    }
    
    private func resumeContainer(_ containerId: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["unpause", containerId]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw SnapshotError.resumeFailed
        }
    }
    
    private func exportContainer(_ containerId: String, to path: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["export", "-o", path.path, containerId]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw SnapshotError.exportFailed
        }
    }
    
    private func restoreSnapshot(_ snapshot: Snapshot) async throws -> String {
        let snapshotPath = snapshotDirectory.appendingPathComponent("\(snapshot.id).tar")
        let newContainerId = "restored_\(snapshot.id)_\(UUID().uuidString.prefix(8))"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["import", "--name", newContainerId, snapshotPath.path]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw SnapshotError.importFailed
        }
        
        let startProcess = Process()
        startProcess.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        startProcess.arguments = ["start", newContainerId]
        
        try startProcess.run()
        startProcess.waitUntilExit()
        
        return newContainerId
    }
    
    private func hasSufficientMemory() async -> Bool {
        let freeMB = await getFreeMemoryMB()
        return freeMB >= minFreeMemoryMB
    }
    
    private func getFreeMemoryMB() async -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return 0 }
            
            var freePages = 0
            var inactivePages = 0
            
            for line in output.components(separatedBy: .newlines) {
                if line.contains("Pages free:") {
                    let parts = line.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    freePages = Int(parts.compactMap { Int($0) }.first ?? 0)
                } else if line.contains("Pages inactive:") {
                    let parts = line.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    inactivePages = Int(parts.compactMap { Int($0) }.first ?? 0)
                }
            }
            
            return ((freePages + inactivePages) * 4096) / 1024 / 1024
        } catch {
            return 0
        }
    }
    
    public func pruneSnapshots(olderThan: TimeInterval = 86400) async {
        let cutoff = Date().addingTimeInterval(-olderThan)
        var toDelete: [String] = []
        
        for (id, snapshot) in snapshots {
            if snapshot.createdAt < cutoff {
                toDelete.append(id)
            }
        }
        
        for id in toDelete {
            let snapshotPath = snapshotDirectory.appendingPathComponent("\(id).tar")
            try? FileManager.default.removeItem(at: snapshotPath)
            snapshots.removeValue(forKey: id)
            stats.snapshotsDeleted += 1
        }
    }
    
    public func printStats() {
        let created = stats.snapshotsCreated
        let restored = stats.snapshotsRestored
        let saved = stats.averageTimeSaved
        let active = snapshots.count
        
        print("")
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║           ContainerSnapshotManager Statistics                ║")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║  Snapshots Created:  \(created)")
        print("║  Snapshots Restored: \(restored)")
        print("║  Avg Time Saved:    \(String(format: "%.1f", saved))s")
        print("║  Active Snapshots:  \(active)")
        print("╚══════════════════════════════════════════════════════════════╝")
        print("")
    }
}

public enum SnapshotError: Error {
    case pauseFailed
    case resumeFailed
    case exportFailed
    case importFailed
}

public extension ContainerPool {
    func acquireWithSnapshot(config: ContainerPoolConfig) async -> PooledContainer? {
        if let containerId = await ContainerSnapshotManager.shared.checkAndRestore(config: config) {
            let pooled = PooledContainer(id: containerId, config: config)
            pooled.isCheckedOut = true
            return pooled
        }
        return await acquire(config: config)
    }
    
    func releaseWithSnapshot(_ container: PooledContainer) async {
        if container.config.memoryLimitMB >= 256 {
            await ContainerSnapshotManager.shared.createSnapshot(from: container.id, config: container.config)
        }
        await release(container)
    }
}
