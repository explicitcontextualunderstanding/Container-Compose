//===----------------------------------------------------------------------===//
// PoolWatcher.swift
// Hot-reload development mode for Container-Compose
// Watches source files and triggers surgical resets on pooled containers
// Prevents expensive full rebuilds on 8GB M2
//===----------------------------------------------------------------------===//

import Foundation
import Dispatch

/// Watches source files and triggers container resets on changes
public actor PoolWatcher {
    public static let shared = PoolWatcher()
    
    private var fileWatchers: [DispatchSourceFileSystemObject] = []
    private var watchedPaths: Set<String> = []
    private var isWatching = false
    
    /// Maps source directories to pool configurations
    public struct WatchMapping: Sendable {
        public let sourcePath: String
        public let poolConfig: ContainerPoolConfig
        public let resetOnChange: Bool
        
        public init(sourcePath: String, poolConfig: ContainerPoolConfig, resetOnChange: Bool = true) {
            self.sourcePath = sourcePath
            self.poolConfig = poolConfig
            self.resetOnChange = resetOnChange
        }
    }
    
    private var mappings: [WatchMapping] = []
    
    /// Statistics for hot-reload
    public struct WatcherStats: Sendable {
        public var filesChanged: Int = 0
        public var containersReset: Int = 0
        public var resetsSkipped: Int = 0
        public var lastChangeTime: Date?
        
        public mutating func recordChange() {
            filesChanged += 1
            lastChangeTime = Date()
        }
        
        public mutating func recordReset() {
            containersReset += 1
        }
    }
    
    public var stats = WatcherStats()
    
    /// Debounce timer to batch rapid changes
    private nonisolated(unsafe) var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.5
    
    /// Default watch mappings for Container-Compose project
    public static var defaultMappings: [WatchMapping] {
        let projectRoot = FileManager.default.currentDirectoryPath
        return [
            WatchMapping(
                sourcePath: "\(projectRoot)/Sources/SecurityHardening",
                poolConfig: ContainerPoolConfig(
                    image: "nginx",
                    tag: "alpine",
                    memoryLimitMB: 64,
                    resetCommand: .wipe(path: "/usr/share/nginx/html/*")
                )
            ),
            WatchMapping(
                sourcePath: "\(projectRoot)/Sources/Container-Compose",
                poolConfig: ContainerPoolConfig(
                    image: resolveImageReference(TestImages.pgmicro),
                    memoryLimitMB: 128,
                    resetCommand: .truncate(tables: ["*"])
                )
            )
        ]
    }
    
    /// Start watching source directories
    public func startWatching(mappings: [WatchMapping] = defaultMappings) {
        guard !isWatching else {
            print("PoolWatcher: Already watching")
            return
        }
        
        self.mappings = mappings
        isWatching = true
        
        for mapping in mappings {
            setupWatcher(for: mapping)
        }
        
        print("PoolWatcher: Started watching \(mappings.count) source directories")
    }
    
    /// Stop all watchers
    public func stopWatching() {
        isWatching = false
        
        for watcher in fileWatchers {
            watcher.cancel()
        }
        fileWatchers.removeAll()
        watchedPaths.removeAll()
        
        debounceTimer?.invalidate()
        debounceTimer = nil
        
        print("PoolWatcher: Stopped watching")
    }
    
    /// Setup file system watcher for a mapping
    private func setupWatcher(for mapping: WatchMapping) {
        let path = mapping.sourcePath
        
        // Expand tilde if present
        let expandedPath = NSString(string: path).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            print("PoolWatcher: Path does not exist: \(expandedPath)")
            return
        }
        
        guard watchedPaths.insert(expandedPath).inserted else {
            print("PoolWatcher: Already watching: \(expandedPath)")
            return
        }
        
        // Open directory for events
        let fileDescriptor = open(expandedPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("PoolWatcher: Failed to open: \(expandedPath)")
            return
        }
        
        // Create dispatch source
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .background)
        )
        
        source.setEventHandler { [weak self] in
            Task {
                await self?.handleFileChange(for: mapping)
            }
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        fileWatchers.append(source)
        
        print("PoolWatcher: Watching \(expandedPath)")
    }
    
    /// Handle file change event with debouncing
    private func handleFileChange(for mapping: WatchMapping) async {
        stats.recordChange()
        
        // Cancel previous debounce timer
        debounceTimer?.invalidate()
        
        // Create new timer
        await MainActor.run {
            debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { _ in
                Task {
                    await self.processDebouncedChange(for: mapping)
                }
            }
        }
    }
    
    /// Process debounced change
    private func processDebouncedChange(for mapping: WatchMapping) async {
        guard mapping.resetOnChange else {
            stats.resetsSkipped += 1
            return
        }
        
        let config = mapping.poolConfig
        let key = "\(config.image):\(config.tag)|mem:\(config.memoryLimitMB)"
        
        // Reset containers matching this configuration
        let resetCount = await ContainerPool.shared.resetContainers(matching: key)
        
        if resetCount > 0 {
            stats.recordReset()
            print("PoolWatcher: Reset \(resetCount) containers for \(mapping.sourcePath)")
        }
    }
    
    /// Print watcher statistics
    public func printStats() {
        print("""
        
        ╔══════════════════════════════════════════════════════════════╗
        ║                PoolWatcher Statistics                        ║
        ╠══════════════════════════════════════════════════════════════╣
        ║  Files Changed:     \(stats.filesChanged)                                    ║
        ║  Containers Reset:  \(stats.containersReset)                                    ║
        ║  Resets Skipped:    \(stats.resetsSkipped)                                    ║
        ║  Last Change:       \(stats.lastChangeTime?.description ?? "N/A")                    ║
        ╚══════════════════════════════════════════════════════════════╝
        
        """)
    }
}

// MARK: - ContainerPool Extension for Watcher

extension ContainerPool {
    /// Reset all containers matching a pool key
    func resetContainers(matching key: String) async -> Int {
        guard let containers = pool[key] else { return 0 }
        
        var resetCount = 0
        for container in containers where !container.isCheckedOut {
            await executeReset(for: container)
            resetCount += 1
        }
        
        return resetCount
    }
    
    /// Execute reset for a specific container
    private func executeReset(for container: PooledContainer) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["exec", container.id]
        
        switch container.config.resetCommand {
        case .flushAll:
            process.arguments?.append(contentsOf: ["redis-cli", "FLUSHALL"])
        case .wipe(let path):
            let cmd = "rm -rf \(path) && mkdir -p \(path)"
            process.arguments?.append(contentsOf: ["sh", "-c", cmd])
        case .truncate:
            let cmd = "psql -c 'TRUNCATE ALL TABLES CASCADE;' 2>/dev/null || true"
            process.arguments?.append(contentsOf: ["sh", "-c", cmd])
        default:
            return
        }
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }
}
