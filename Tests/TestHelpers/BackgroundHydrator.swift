//===----------------------------------------------------------------------===//
// BackgroundHydrator.swift
// Sub-second SQL reset with background hydration
// Cleans containers before next test to eliminate wait time
//===----------------------------------------------------------------------===//

import Foundation
import ContainerAPIClient

/// Performs background hydration and cleanup
public actor BackgroundHydrator {
    public static let shared = BackgroundHydrator()
    
    /// Hydration queue
    private var hydrationQueue: [(containerId: String, config: ContainerPoolConfig, timestamp: Date)] = []
    
    /// Background task
    private var hydrationTask: Task<Void, Never>?
    
    /// Minimum memory for background operations (600MB)
    private let minMemoryMB = 600
    
    /// Hydration statistics
    public struct HydrationStats: Sendable {
        public var containersHydrated: Int = 0
        public var containersCleaned: Int = 0
        public var avgHydrationTimeMs: Double = 0
        public var hydrationPaused: Int = 0
    }
    
    public var stats = HydrationStats()
    
    /// Start background hydration
    public func start() {
        guard hydrationTask == nil else { return }
        
        hydrationTask = Task {
            while !Task.isCancelled {
                await processHydrationQueue()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        
        print("BackgroundHydrator: Started")
    }
    
    /// Stop background hydration
    public func stop() {
        hydrationTask?.cancel()
        hydrationTask = nil
    }
    
    /// Queue container for hydration
    public func queueHydration(containerId: String, config: ContainerPoolConfig) {
        hydrationQueue.insert((containerId, config, Date()), at: 0)
    }
    
    /// Process hydration queue
    private func processHydrationQueue() async {
        guard await hasSufficientMemory() else {
            stats.hydrationPaused += 1
            return
        }
        
        guard !hydrationQueue.isEmpty else { return }
        
        let item = hydrationQueue.removeLast()
        let startTime = Date()
        
        await hydrateContainer(item.containerId, config: item.config)
        
        let duration = Date().timeIntervalSince(startTime)
        updateStats(duration: duration)
    }
    
    /// Hydrate container based on type
    private func hydrateContainer(_ containerId: String, config: ContainerPoolConfig) async {
        let image = config.image.lowercased()
        
        if image.contains("wordpress") {
            await hydrateWordPress(containerId)
        } else if image.contains("mysql") || image.contains("mariadb") {
            await hydrateMySQL(containerId)
        } else if image.contains("postgres") || image.contains("pgmicro") {
            await hydratePostgreSQL(containerId)
        } else if image.contains("redis") {
            await hydrateRedis(containerId)
        } else {
            await performGenericReset(containerId, config: config)
        }
    }
    
    /// WordPress-specific hydration
    private func hydrateWordPress(_ containerId: String) async {
        let cmd = """
            wp transient delete --all 2>/dev/null || true; \\
            wp cache flush 2>/dev/null || true; \\
            rm -rf /var/www/html/wp-content/uploads/* 2>/dev/null || true
            """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["exec", containerId, "sh", "-c", cmd]
        
        do {
            try process.run()
            process.waitUntilExit()
            stats.containersHydrated += 1
        } catch {}
    }
    
    /// MySQL-specific hydration
    private func hydrateMySQL(_ containerId: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = [
            "exec", containerId, "sh", "-c",
            "mysql -e 'SHOW TABLES' 2>/dev/null | tail -n +2 | xargs -I {} mysql -e 'DROP TABLE IF EXISTS {}' 2>/dev/null || true"
        ]
        
        do {
            try process.run()
            process.waitUntilExit()
            stats.containersCleaned += 1
        } catch {}
    }
    
    /// PostgreSQL-specific hydration
    private func hydratePostgreSQL(_ containerId: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = [
            "exec", containerId, "sh", "-c",
            "psql -U postgres -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;' 2>/dev/null || true"
        ]
        
        do {
            try process.run()
            process.waitUntilExit()
            stats.containersCleaned += 1
        } catch {}
    }
    
    /// Redis-specific hydration
    private func hydrateRedis(_ containerId: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["exec", containerId, "redis-cli", "FLUSHALL"]
        
        do {
            try process.run()
            process.waitUntilExit()
            stats.containersCleaned += 1
        } catch {}
    }
    
    /// Generic reset
    private func performGenericReset(_ containerId: String, config: ContainerPoolConfig) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["exec", containerId, "sh", "-c", "rm -rf /tmp/* /var/tmp/* 2>/dev/null || true"]
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }
    
    /// Check if sufficient memory available
    private func hasSufficientMemory() async -> Bool {
        let freeMB = await getFreeMemoryMB()
        return freeMB >= minMemoryMB
    }
    
    /// Get free memory
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
    
    /// Update statistics
    private func updateStats(duration: TimeInterval) {
        let durationMs = duration * 1000
        let total = Double(stats.containersHydrated + stats.containersCleaned)
        guard total > 0 else { return }
        stats.avgHydrationTimeMs = (stats.avgHydrationTimeMs * (total - 1) + durationMs) / total
    }
    
    /// Print statistics
    public func printStats() {
        let hydrated = stats.containersHydrated
        let cleaned = stats.containersCleaned
        let avgTime = stats.avgHydrationTimeMs
        let paused = stats.hydrationPaused
        let queueSize = hydrationQueue.count
        
        print("")
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║           BackgroundHydrator Statistics                      ║")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║  Containers Hydrated: \(hydrated)")
        print("║  Containers Cleaned:  \(cleaned)")
        print("║  Avg Hydration Time:  \(String(format: "%.0f", avgTime))ms")
        print("║  Hydrations Paused:   \(paused)")
        print("║  Queue Size:         \(queueSize)")
        print("╚══════════════════════════════════════════════════════════════╝")
        print("")
    }
}

// MARK: - ContainerPool Integration

public extension ContainerPool {
    /// Release container with background hydration
    func releaseWithHydration(_ container: PooledContainer) async {
        container.isCheckedOut = false
        container.lastUsed = Date()
        
        await BackgroundHydrator.shared.queueHydration(
            containerId: container.id,
            config: container.config
        )
    }
}
