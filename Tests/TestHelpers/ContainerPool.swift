//===----------------------------------------------------------------------===//
// ContainerPool.swift
// Transactional container pool for 8GB M2 optimization
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import ContainerCommands
import ContainerAPIClient

// MARK: - Configuration

public struct ContainerPoolConfig: Sendable {
    public let image: String
    public let tag: String
    public let memoryLimitMB: Int
    public let cpuLimit: Int
    public let envVars: [String: String]
    public let volumes: [String]
    public let resetCommand: ResetCommand
    
    public init(
        image: String,
        tag: String = "latest",
        memoryLimitMB: Int = 128,
        cpuLimit: Int = 1,
        envVars: [String: String] = [:],
        volumes: [String] = [],
        resetCommand: ResetCommand = .auto
    ) {
        self.image = image
        self.tag = tag
        self.memoryLimitMB = memoryLimitMB
        self.cpuLimit = cpuLimit
        self.envVars = envVars
        self.volumes = volumes
        self.resetCommand = resetCommand
    }
    
    public var fullImage: String { "\(image):\(tag)" }
    public var estimatedMemoryMB: Int { memoryLimitMB + 50 }
}

public enum ResetCommand: Sendable {
    case auto
    case truncate(tables: [String])
    case flushAll
    case wipe(path: String)
    case custom([String])
    case none
    
    public static func detect(from image: String) -> ResetCommand {
        let lower = image.lowercased()
        if lower.contains("redis") { return .flushAll }
        if lower.contains("postgres") || lower.contains("pgmicro") { return .truncate(tables: ["*"]) }
        if lower.contains("nginx") { return .wipe(path: "/usr/share/nginx/html/*") }
        return .none
    }
}

// MARK: - Pooled Container

public final class PooledContainer: @unchecked Sendable {
    public let id: String
    public let config: ContainerPoolConfig
    public let creationTime: Date
    internal var lastUsed: Date
    internal var useCount: Int
    internal var isCheckedOut: Bool
    
    public init(id: String, config: ContainerPoolConfig) {
        self.id = id
        self.config = config
        self.creationTime = Date()
        self.lastUsed = Date()
        self.useCount = 0
        self.isCheckedOut = false
    }
}

// MARK: - Memory Budget

public actor MemoryBudget {
    public static let shared = MemoryBudget()
    public static let maxPooledMemoryMB = 1536
    private var allocatedMB: Int = 0
    
    public func reserve(_ mb: Int) -> Bool {
        let newTotal = allocatedMB + mb
        guard newTotal <= MemoryBudget.maxPooledMemoryMB else { return false }
        allocatedMB = newTotal
        return true
    }
    
    public func release(_ mb: Int) {
        allocatedMB = max(0, allocatedMB - mb)
    }
    
    public func available() -> Int {
        MemoryBudget.maxPooledMemoryMB - allocatedMB
    }
    
    public func reset() {
        allocatedMB = 0
    }
}

// MARK: - Container Pool

public actor ContainerPool {
    public static let shared = ContainerPool()
    
    internal var pool: [String: [PooledContainer]] = [:]
    private let maxIdleTime: TimeInterval = 300
    private let maxAge: TimeInterval = 1800
    
    public struct PoolStats: Sendable {
        public var warmHits: Int = 0
        public var coldStarts: Int = 0
        public var evictions: Int = 0
        public var totalResetTime: TimeInterval = 0
        public var totalCreationTime: TimeInterval = 0
        
        public var warmHitRate: Double {
            let total = warmHits + coldStarts
            return total > 0 ? Double(warmHits) / Double(total) : 0
        }
        
        public var averageResetTimeMs: Double {
            return warmHits > 0 ? (totalResetTime / Double(warmHits)) * 1000 : 0
        }
        
        public var averageCreationTimeMs: Double {
            return coldStarts > 0 ? (totalCreationTime / Double(coldStarts)) * 1000 : 0
        }
        
        public var timeSavingsPercent: Double {
            let avgReset = averageResetTimeMs
            let avgCreate = averageCreationTimeMs
            return avgCreate > 0 ? ((avgCreate - avgReset) / avgCreate) * 100 : 0
        }
    }
    
    public var stats = PoolStats()
    
    private func poolKey(for config: ContainerPoolConfig) -> String {
        return "\(config.image):\(config.tag)|mem:\(config.memoryLimitMB)"
    }
    
    public func warm(config: ContainerPoolConfig) async -> PooledContainer? {
        let key = poolKey(for: config)
        
        guard await MemoryBudget.shared.reserve(config.estimatedMemoryMB) else {
            print("ContainerPool: Memory budget exceeded")
            return nil
        }
        
        let startTime = Date()
        let containerName = "pool_\(key.hashValue)_\(UUID().uuidString.prefix(8))"
        
        var args = [
            "run", "-d",
            "--name", containerName,
            "--memory", "\(config.memoryLimitMB)m",
            "--cpus", "\(config.cpuLimit)",
            "--label", "com.container-compose.pool=true",
            "--label", "com.container-compose.pool-key=\(key)"
        ]
        
        for (k, v) in config.envVars {
            args.append(contentsOf: ["--env", "\(k)=\(v)"])
        }
        
        args.append(config.fullImage)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = args
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                await MemoryBudget.shared.release(config.estimatedMemoryMB)
                return nil
            }
            
            stats.totalCreationTime += Date().timeIntervalSince(startTime)
            
            let pooled = PooledContainer(id: containerName, config: config)
            if pool[key] == nil { pool[key] = [] }
            pool[key]?.append(pooled)
            
            print("ContainerPool: Warmed \(config.fullImage)")
            return pooled
        } catch {
            await MemoryBudget.shared.release(config.estimatedMemoryMB)
            return nil
        }
    }
    
    public func acquire(config: ContainerPoolConfig) async -> PooledContainer? {
        let key = poolKey(for: config)
        
        if let containers = pool[key] {
            if let index = containers.firstIndex(where: { !$0.isCheckedOut }) {
                let container = containers[index]
                container.isCheckedOut = true
                container.useCount += 1
                container.lastUsed = Date()
                
                let resetStart = Date()
                await executeReset(for: container)
                let resetTime = Date().timeIntervalSince(resetStart)
                
                stats.warmHits += 1
                stats.totalResetTime += resetTime
                
                print("ContainerPool: Warm hit for \(config.fullImage)")
                return container
            }
        }
        
        stats.coldStarts += 1
        print("ContainerPool: Cold start for \(config.fullImage)")
        return nil
    }
    
    public func release(_ container: PooledContainer) async {
        container.isCheckedOut = false
        container.lastUsed = Date()
        
        if shouldEvict(container) {
            await evict(container)
        }
    }
    
    private func executeReset(for container: PooledContainer) async {
        let cmd: ResetCommand
        switch container.config.resetCommand {
        case .auto: cmd = ResetCommand.detect(from: container.config.image)
        default: cmd = container.config.resetCommand
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["exec", container.id]
        
        switch cmd {
        case .flushAll:
            process.arguments?.append(contentsOf: ["redis-cli", "FLUSHALL"])
        case .wipe(let path):
            process.arguments?.append(contentsOf: ["sh", "-c", "rm -rf \(path) && mkdir -p \(path)"])
        case .truncate:
            process.arguments?.append(contentsOf: ["sh", "-c", "psql -c 'TRUNCATE ALL TABLES CASCADE;' 2>/dev/null || true"])
        default: return
        }
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }
    
    private func shouldEvict(_ container: PooledContainer) -> Bool {
        Date().timeIntervalSince(container.lastUsed) > maxIdleTime ||
        Date().timeIntervalSince(container.creationTime) > maxAge
    }
    
    private func evict(_ container: PooledContainer) async {
        pool[poolKey(for: container.config)]?.removeAll { $0.id == container.id }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["rm", "-f", container.id]
        
        do {
            try process.run()
            process.waitUntilExit()
            await MemoryBudget.shared.release(container.config.estimatedMemoryMB)
            stats.evictions += 1
        } catch {}
    }
    
    public func getStats() -> PoolStats { stats }
    
    // MARK: - Reaper Integration
    
    func importPooledContainer(_ container: PooledContainer, key: String) {
        if pool[key] == nil { pool[key] = [] }
        pool[key]?.append(container)
    }
}

// MARK: - Presets

public extension ContainerPoolConfig {
    static var nginx: ContainerPoolConfig {
        ContainerPoolConfig(
            image: "nginx",
            tag: "alpine",
            memoryLimitMB: 64,
            resetCommand: .wipe(path: "/usr/share/nginx/html/*")
        )
    }
    
    static var redis: ContainerPoolConfig {
        ContainerPoolConfig(
            image: "redis",
            tag: "alpine",
            memoryLimitMB: 64,
            resetCommand: .flushAll
        )
    }
}
