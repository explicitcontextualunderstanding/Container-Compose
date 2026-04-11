//===----------------------------------------------------------------------===//
// ContainerReaper.swift
// Self-healing cleanup for orphaned containers
// Prevents memory leaks on 8GB M2 from crashed tests
//===----------------------------------------------------------------------===//

import Foundation
import ContainerCommands
import ContainerAPIClient

/// ContainerReaper provides self-healing cleanup for orphaned containers
/// Uses name-pattern and age-based detection to survive Swift process crashes
public actor ContainerReaper {
    public static let shared = ContainerReaper()
    
    /// Threshold for considering a container orphaned (5 minutes of idle time)
    public static let orphanThreshold: TimeInterval = 300
    
    /// Threshold for force deletion (30 minutes)
    public static let forceDeleteThreshold: TimeInterval = 1800
    
    /// Reaper statistics
    public struct ReaperStats: Sendable {
        public var orphansFound: Int = 0
        public var orphansAdopted: Int = 0
        public var orphansPurged: Int = 0
        public var legacyPurged: Int = 0
    }
    
    public var stats = ReaperStats()
    
    /// Scan for orphaned containers by name patterns
    /// - Returns: Tuple of (pool candidates, stale containers)
    public func scanForOrphans() async -> ([ClientContainer], [ClientContainer]) {
        do {
            let allContainers = try await ClientContainer.list()
            
            var poolCandidates: [ClientContainer] = []
            var stale: [ClientContainer] = []
            
            for container in allContainers {
                let name = container.configuration.id
                
                // Check for pooled containers (pool_* prefix)
                if name.hasPrefix("pool_") {
                    let age = await getContainerAge(container.id)
                    
                    if age > ContainerReaper.forceDeleteThreshold {
                        stale.append(container)
                    } else if age > ContainerReaper.orphanThreshold {
                        poolCandidates.append(container)
                    }
                }
                // Check for test containers with CCT_ prefix
                else if name.hasPrefix("CCT_") || name.contains("_CCT_") {
                    stale.append(container)
                }
            }
            
            stats.orphansFound += poolCandidates.count + stale.count
            return (poolCandidates, stale)
        } catch {
            print("Reaper: Failed to scan containers: \(error)")
            return ([], [])
        }
    }
    
    /// Get container age via inspect
    private func getContainerAge(_ containerId: String) async -> TimeInterval {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["inspect", "--format", "{{.Created}}", containerId]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else { return 0 }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let dateStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let createdDate = ISO8601DateFormatter().date(from: dateStr) else {
                return 0
            }
            
            return Date().timeIntervalSince(createdDate)
        } catch {
            return 0
        }
    }
    
    /// Adopt pool containers back into the pool
    public func adoptOrphans() async -> Int {
        let (candidates, _) = await scanForOrphans()
        var adopted = 0
        
        for container in candidates {
            // Parse config from container name
            let config = parseConfigFromContainerName(container.id)
            
            // Check memory budget
            guard await MemoryBudget.shared.reserve(config.estimatedMemoryMB) else {
                print("Reaper: Memory budget exceeded, cannot adopt \(container.id)")
                continue
            }
            
            // Reset the container
            await resetContainer(container, config: config)
            
            // Import into pool
            let pooled = PooledContainer(id: container.id, config: config)
            let key = "\(config.image):\(config.tag)|mem:\(config.memoryLimitMB)"
            await ContainerPool.shared.importPooledContainer(pooled, key: key)
            
            adopted += 1
            stats.orphansAdopted += 1
            print("Reaper: Adopted orphaned container \(container.id)")
        }
        
        return adopted
    }
    
    /// Reset a container based on its type
    private func resetContainer(_ container: ClientContainer, config: ContainerPoolConfig) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["exec", container.id]
        
        switch config.resetCommand {
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
    
    /// Parse config from container name
    private func parseConfigFromContainerName(_ name: String) -> ContainerPoolConfig {
        if name.contains("nginx") {
            return ContainerPoolConfig(
                image: "nginx",
                tag: "alpine",
                memoryLimitMB: 64,
                resetCommand: .wipe(path: "/usr/share/nginx/html/*")
            )
        } else if name.contains("redis") {
            return ContainerPoolConfig(
                image: "redis",
                tag: "alpine",
                memoryLimitMB: 64,
                resetCommand: .flushAll
            )
        } else if name.contains("pgmicro") || name.contains("postgres") {
            return ContainerPoolConfig(
                image: resolveImageReference(TestImages.pgmicro),
                memoryLimitMB: 128,
                resetCommand: .truncate(tables: ["*"])
            )
        }
        
        return ContainerPoolConfig(
            image: "alpine",
            tag: "latest",
            memoryLimitMB: 32
        )
    }
    
    /// Purge stale containers
    public func purgeStale() async -> Int {
        let (_, stale) = await scanForOrphans()
        var purged = 0
        
        for container in stale {
            do {
                try await deleteContainer(container.id)
                purged += 1
                stats.orphansPurged += 1
                print("Reaper: Purged stale container \(container.id)")
            } catch {
                print("Reaper: Failed to purge \(container.id): \(error)")
            }
        }
        
        return purged
    }
    
    /// Full cleanup cycle
    @discardableResult
    public func cleanupCycle() async -> (adopted: Int, purged: Int) {
        let adopted = await adoptOrphans()
        let purged = await purgeStale()
        return (adopted, purged)
    }
    
    /// CCT_ prefix cleanup for legacy test containers
    public func purgeCCTLegacyContainers() async -> Int {
        do {
            let allContainers = try await ClientContainer.list()
            let legacyContainers = allContainers.filter { container in
                container.configuration.id.hasPrefix("CCT_") ||
                container.configuration.id.contains("_CCT_")
            }
            
            var purged = 0
            for container in legacyContainers {
                do {
                    try await deleteContainer(container.id)
                    purged += 1
                    print("Reaper: Purged legacy CCT container \(container.id)")
                } catch {
                    print("Reaper: Failed to purge legacy \(container.id): \(error)")
                }
            }
            
            stats.legacyPurged += purged
            return purged
        } catch {
            print("Reaper: Failed to list containers: \(error)")
            return 0
        }
    }
    
    /// Print statistics report
    public func printStatsReport() {
        let found = stats.orphansFound
        let adopted = stats.orphansAdopted
        let purged = stats.orphansPurged
        let legacy = stats.legacyPurged
        
        print("")
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║              ContainerReaper Statistics Report               ║")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║  Orphans Found:   \(found)")
        print("║  Orphans Adopted: \(adopted)")
        print("║  Orphans Purged:  \(purged)")
        print("║  Legacy Purged:   \(legacy)")
        print("╚══════════════════════════════════════════════════════════════╝")
        print("")
    }
    
    /// Delete a container
    private func deleteContainer(_ containerId: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["rm", "-f", containerId]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw ReaperError.deleteFailed
        }
    }
}

public enum ReaperError: Error {
    case deleteFailed
}

// MARK: - ContainerPool Extension

public extension ContainerPool {
    /// Import a pooled container from Reaper adoption
    func importPooledContainer(_ container: PooledContainer, key: String) {
        if pool[key] == nil {
            pool[key] = []
        }
        pool[key]?.append(container)
    }
    
    /// Initialize with Reaper cleanup
    func initializeWithReaper() async {
        let (adopted, purged) = await ContainerReaper.shared.cleanupCycle()
        print("Reaper: Adopted \(adopted), purged \(purged) containers")
        
        let legacyPurged = await ContainerReaper.shared.purgeCCTLegacyContainers()
        if legacyPurged > 0 {
            print("Reaper: Purged \(legacyPurged) legacy CCT containers")
        }
    }
}
