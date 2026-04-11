//===----------------------------------------------------------------------===//
// ContainerLogStreamer.swift
// Contextual log streaming from active test containers
// Prevents log flood on small M2 screen
//===----------------------------------------------------------------------===//

import Foundation
import ContainerAPIClient

/// Streams logs from active test containers with contextual prefixing
public actor ContainerLogStreamer {
    public static let shared = ContainerLogStreamer()
    
    /// Active stream sessions
    private var activeStreams: [String: StreamSession] = [:]
    
    /// Stream session tracking
    private struct StreamSession {
        let containerId: String
        let testName: String
        let task: Task<Void, Never>
        let startTime: Date
    }
    
    /// Configuration for log streaming
    public struct StreamConfig: Sendable {
        public let prefix: String
        public let maxLines: Int?
        public let follow: Bool
        public let since: TimeInterval?
        
        public init(
            prefix: String? = nil,
            maxLines: Int? = nil,
            follow: Bool = true,
            since: TimeInterval? = nil
        ) {
            self.prefix = prefix ?? "TEST"
            self.maxLines = maxLines
            self.follow = follow
            self.since = since
        }
    }
    
    /// Statistics
    public struct StreamStats: Sendable {
        public var streamsStarted: Int = 0
        public var streamsStopped: Int = 0
        public var totalLinesStreamed: Int = 0
    }
    
    public var stats = StreamStats()
    
    /// Color codes for terminal output
    private let colors = [
        "\u{001B}[36m", // Cyan
        "\u{001B}[32m", // Green
        "\u{001B}[33m", // Yellow
        "\u{001B}[35m", // Magenta
        "\u{001B}[34m", // Blue
    ]
    private let resetColor = "\u{001B}[0m"
    
    /// Color index for cycling through colors
    private var colorIndex = 0
    
    /// Start streaming logs from a container
    public func startStream(
        containerId: String,
        testName: String,
        config: StreamConfig = StreamConfig()
    ) {
        // Stop existing stream for this container
        stopStream(containerId: containerId)
        
        let color = colors[colorIndex % colors.count]
        colorIndex += 1
        
        let prefix = "\(color)[\(config.prefix)]\(resetColor)"
        
        let task = Task {
            await streamLogs(
                containerId: containerId,
                testName: testName,
                prefix: prefix,
                config: config
            )
        }
        
        activeStreams[containerId] = StreamSession(
            containerId: containerId,
            testName: testName,
            task: task,
            startTime: Date()
        )
        
        stats.streamsStarted += 1
        print("\(prefix) Started log stream for \(testName)")
    }
    
    /// Stop streaming logs from a container
    public func stopStream(containerId: String) {
        if let session = activeStreams.removeValue(forKey: containerId) {
            session.task.cancel()
            stats.streamsStopped += 1
            
            let duration = Date().timeIntervalSince(session.startTime)
            print("[STOP] Log stream for \(session.testName) (duration: \(String(format: "%.1f", duration))s)")
        }
    }
    
    /// Stop all active streams
    public func stopAllStreams() {
        for (containerId, _) in activeStreams {
            stopStream(containerId: containerId)
        }
        activeStreams.removeAll()
    }
    
    /// Stream logs implementation
    private func streamLogs(
        containerId: String,
        testName: String,
        prefix: String,
        config: StreamConfig
    ) async {
        var lineCount = 0
        
        // Build log command arguments
        var args = ["logs"]
        
        if config.follow {
            args.append("-f")
        }
        
        if let since = config.since {
            let sinceTime = Int(since)
            args.append(contentsOf: ["--since", "\(sinceTime)s"])
        }
        
        if let maxLines = config.maxLines {
            args.append(contentsOf: ["--tail", "\(maxLines)"])
        }
        
        args.append(containerId)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            
            // Read output asynchronously
            let fileHandle = pipe.fileHandleForReading
            
            while !Task.isCancelled {
                let data = fileHandle.availableData
                guard !data.isEmpty else {
                    // Check if process terminated
                    if !process.isRunning {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    continue
                }
                
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.components(separatedBy: .newlines)
                    for line in lines where !line.isEmpty {
                        print("\(prefix) \(line)")
                        lineCount += 1
                        stats.totalLinesStreamed += 1
                        
                        // Respect max lines limit
                        if let max = config.maxLines, lineCount >= max {
                            break
                        }
                    }
                }
                
                // Respect max lines limit
                if let max = config.maxLines, lineCount >= max {
                    break
                }
            }
            
            process.terminate()
            
        } catch {
            print("\(prefix) Log stream error: \(error)")
        }
    }
    
    /// Get logs for a specific container (one-shot)
    public func getLogs(
        containerId: String,
        tail: Int = 100
    ) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/container")
        process.arguments = ["logs", "--tail", "\(tail)", containerId]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Failed to get logs: \(error)"
        }
    }
    
    /// Stream logs for the duration of a test
    public func withLogStream<T>(
        containerId: String,
        testName: String,
        config: StreamConfig = StreamConfig(),
        operation: () async throws -> T
    ) async rethrows -> T {
        startStream(containerId: containerId, testName: testName, config: config)
        defer { stopStream(containerId: containerId) }
        return try await operation()
    }
    
    /// Print stream statistics
    public func printStats() {
        let activeCount = activeStreams.count
        let started = stats.streamsStarted
        let stopped = stats.streamsStopped
        let lines = stats.totalLinesStreamed
        
        print("""
        
        ╔══════════════════════════════════════════════════════════════╗
        ║              ContainerLogStreamer Statistics                 ║
        ╠══════════════════════════════════════════════════════════════╣
        ║  Active Streams:   \(activeCount)                                       ║
        ║  Streams Started:  \(started)                                       ║
        ║  Streams Stopped:  \(stopped)                                       ║
        ║  Total Lines:      \(lines)                                       ║
        ╚══════════════════════════════════════════════════════════════╝
        
        """)
    }
    
    /// List active streams
    public func listActiveStreams() -> [(containerId: String, testName: String, duration: TimeInterval)] {
        let now = Date()
        return activeStreams.map { (id, session) in
            (id, session.testName, now.timeIntervalSince(session.startTime))
        }
    }
}

// MARK: - Swift Testing Integration

#if canImport(Testing)
import Testing

public extension ContainerLogStreamer {
    /// Start stream for current test
    func startStreamForCurrentTest(
        containerId: String,
        test: Test,
        config: StreamConfig = StreamConfig()
    ) {
        let customConfig = StreamConfig(
            prefix: test.name,
            maxLines: config.maxLines,
            follow: config.follow,
            since: config.since
        )
        startStream(containerId: containerId, testName: test.name, config: customConfig)
    }
}
#endif
