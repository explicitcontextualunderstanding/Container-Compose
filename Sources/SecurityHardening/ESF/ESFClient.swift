// ESFClient.swift
// Component 2: ESF Audit Logging Client
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import Foundation
import EndpointSecurity

/// ESF Client for audit logging of VM start events
/// Logs ES_EVENT_TYPE_NOTIFY_VM_START events per SECURITY_CONTAINER.md requirements
public actor ESFClient: Sendable {
    /// Log entry for security audit trail
    public struct LogEntry: Codable, Sendable, Equatable {
        public let timestamp: Date
        public let eventType: String
        public let cid: UInt32?
        public let process: String
        public let details: String

        public init(timestamp: Date, eventType: String, cid: UInt32? = nil, process: String, details: String) {
            self.timestamp = timestamp
            self.eventType = eventType
            self.cid = cid
            self.process = process
            self.details = details
        }
    }

    /// Configuration for ESF client
    public struct Configuration: Sendable {
        public let logPath: String
        public let logLevel: LogLevel
        public let maxFileSize: Int64
        public let maxFiles: Int

        public init(
            logPath: String = "~/Library/Logs/container-compose/security.log",
            logLevel: LogLevel = .info,
            maxFileSize: Int64 = 10 * 1024 * 1024, // 10MB
            maxFiles: Int = 5
        ) {
            self.logPath = (logPath as NSString).expandingTildeInPath
            self.logLevel = logLevel
            self.maxFileSize = maxFileSize
            self.maxFiles = maxFiles
        }
    }

    public enum LogLevel: Int, Sendable, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3

        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private let configuration: Configuration
    private var logFileHandle: FileHandle?
    private let dateFormatter: DateFormatter
    private let encoder: JSONEncoder

    /// Current log entries in memory (for recent queries)
    private var recentEntries: [LogEntry] = []
    private let maxRecentEntries = 1000

    /// Errors that can occur during ESF operations
    public enum ESFError: Error, Sendable, Equatable {
        case clientCreationFailed
        case subscriptionFailed
        case logFileCreationFailed
        case logWriteFailed
        case invalidCID
        case notRunning
    }

    /// Creates ESF client with configuration
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration

        // Date formatter for ISO-8601 timestamps
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        self.dateFormatter.timeZone = TimeZone(identifier: "UTC")

        // JSON encoder for structured logging
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = .sortedKeys
    }

    deinit {
        logFileHandle?.closeFile()
    }

    // MARK: - Initialization

    /// Initializes the ESF client and log file
    /// Creates log directory and file with restricted permissions (0o600)
    public func initialize() async throws {
        // Create log directory if needed
        let logDir = (configuration.logPath as NSString).deletingLastPathComponent

        if !FileManager.default.fileExists(atPath: logDir) {
            try FileManager.default.createDirectory(
                atPath: logDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700] // Owner rwx only
            )
        }

        // Create or open log file
        if !FileManager.default.fileExists(atPath: configuration.logPath) {
            let created = FileManager.default.createFile(
                atPath: configuration.logPath,
                contents: nil,
                attributes: [.posixPermissions: 0o600] // Owner rw only
            )
            guard created else {
                throw ESFError.logFileCreationFailed
            }
        }

        guard let handle = FileHandle(forWritingAtPath: configuration.logPath) else {
            throw ESFError.logFileCreationFailed
        }

        // Append to end of file
        handle.seekToEndOfFile()
        self.logFileHandle = handle

        // Log initialization
        try await log(
            eventType: "ESF_CLIENT_INIT",
            cid: nil,
            process: ProcessInfo.processInfo.processName,
            details: "ESF client initialized, log path: \(configuration.logPath)"
        )
    }

    // MARK: - Logging

    /// Logs a VM start event (ES_EVENT_TYPE_NOTIFY_VM_START)
    /// Called when Virtualization.framework starts a VM
    public func logVMStart(cid: UInt32, processName: String, details: String = "") async throws {
        try await log(
            eventType: "ES_EVENT_TYPE_NOTIFY_VM_START",
            cid: cid,
            process: processName,
            details: details
        )
    }

    /// Logs a generic security event
    public func logSecurityEvent(eventType: String, cid: UInt32?, process: String, details: String) async throws {
        try await log(
            eventType: eventType,
            cid: cid,
            process: process,
            details: details
        )
    }

    // MARK: - Private Implementation
    private func log(eventType: String, cid: UInt32?, process: String, details: String) async throws {
        guard configuration.logLevel <= .info else { return }

        let entry = LogEntry(
            timestamp: Date(),
            eventType: eventType,
            cid: cid,
            process: process,
            details: details
        )

        // Add to recent entries (capped)
        recentEntries.append(entry)
        if recentEntries.count > maxRecentEntries {
            recentEntries.removeFirst(recentEntries.count - maxRecentEntries)
        }

        // Write to file
        let jsonData = try encoder.encode(entry)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ESFError.logWriteFailed
        }

        guard let handle = logFileHandle else {
            throw ESFError.notRunning
        }

        guard let data = (jsonString + "\n").data(using: .utf8) else {
            throw ESFError.logWriteFailed
        }

        handle.write(data)
        handle.synchronizeFile() // Ensure data is written before reading

        // Check rotation
        try await checkRotation()
    }

    // MARK: - Log Rotation

    private func checkRotation() async throws {
        guard let handle = logFileHandle else { return }

        let currentOffset = handle.offsetInFile
        if currentOffset >= configuration.maxFileSize {
            try await rotateLog()
        }
    }

    private func rotateLog() async throws {
        logFileHandle?.closeFile()
        logFileHandle = nil

        let basePath = configuration.logPath

        // Shift existing rotated files
        for i in (1..<configuration.maxFiles).reversed() {
            let oldPath = "\(basePath).\(i)"
            let newPath = "\(basePath).\(i + 1)"

            if FileManager.default.fileExists(atPath: oldPath) {
                try? FileManager.default.removeItem(atPath: newPath)
                try? FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
            }
        }

        // Rotate current file
        try? FileManager.default.removeItem(atPath: "\(basePath).1")
        try? FileManager.default.moveItem(atPath: basePath, toPath: "\(basePath).1")

        // Create new log file
        FileManager.default.createFile(
            atPath: basePath,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )

        guard let handle = FileHandle(forWritingAtPath: basePath) else {
            throw ESFError.logFileCreationFailed
        }

        logFileHandle = handle
    }

    // MARK: - Query

    /// Returns recent log entries from memory
    public func recentLogEntries() async -> [LogEntry] {
        return recentEntries
    }

    /// Queries log file for entries matching criteria
    public func queryLog(eventType: String? = nil, since: Date? = nil, limit: Int = 100) async throws -> [LogEntry] {
        guard FileManager.default.fileExists(atPath: configuration.logPath) else {
            return []
        }

        guard let data = FileManager.default.contents(atPath: configuration.logPath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = content.split(separator: "\n")
        var entries: [LogEntry] = []

        for line in lines.suffix(limit * 2) { // Read extra to filter
            guard let lineData = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(LogEntry.self, from: lineData) else {
                continue
            }

            // Apply filters
            if let eventType = eventType, entry.eventType != eventType {
                continue
            }
            if let since = since, entry.timestamp < since {
                continue
            }

            entries.append(entry)
        }

        return Array(entries.suffix(limit))
    }

    // MARK: - Shutdown

    public func shutdown() async {
        // Log shutdown
        _ = try? await log(
            eventType: "ESF_CLIENT_SHUTDOWN",
            cid: nil,
            process: ProcessInfo.processInfo.processName,
            details: "ESF client shutting down"
        )

        logFileHandle?.closeFile()
        logFileHandle = nil
    }
}

// MARK: - Convenience Methods

public extension ESFClient {
    /// Quick log for VM start events
    func notifyVMStarted(cid: UInt32, process: String = "container-compose") async {
        _ = try? await logVMStart(cid: cid, processName: process)
    }

    /// Log relay events
    func logRelayStarted(port: UInt32, transport: String) async {
        _ = try? await log(
            eventType: "RELAY_STARTED",
            cid: nil,
            process: ProcessInfo.processInfo.processName,
            details: "Relay started: port=\(port), transport=\(transport)"
        )
    }
}
