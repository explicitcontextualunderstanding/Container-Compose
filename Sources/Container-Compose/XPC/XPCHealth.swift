//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
// Rights reserved as per Apache License 2.0
//===----------------------------------------------------------------------===//

import ContainerAPIClient
import Foundation

/// XPC health verification and diagnostics for Apple Container runtime
/// Provides pre-flight checks and detailed diagnostics for XPC connections
public enum XPCHealth {

  // MARK: - Configuration

  /// Configuration for XPC health monitoring
  public struct Configuration: Sendable {
    /// Timeout for health check operations (seconds)
    public let healthCheckTimeout: TimeInterval
    /// Maximum consecutive failures before circuit opens
    public let circuitBreakerThreshold: Int
    /// Duration to keep circuit open before retry
    public let circuitBreakerResetDuration: TimeInterval
    /// Maximum retries for health check
    public let maxRetries: Int
    /// Delay between retries (seconds)
    public let retryDelay: TimeInterval

    public init(
      healthCheckTimeout: TimeInterval = 10,
      circuitBreakerThreshold: Int = 3,
      circuitBreakerResetDuration: TimeInterval = 30,
      maxRetries: Int = 2,
      retryDelay: TimeInterval = 1.0
    ) {
      self.healthCheckTimeout = healthCheckTimeout
      self.circuitBreakerThreshold = circuitBreakerThreshold
      self.circuitBreakerResetDuration = circuitBreakerResetDuration
      self.maxRetries = maxRetries
      self.retryDelay = retryDelay
    }
  }

  // MARK: - Circuit Breaker State

  /// Circuit breaker states
  public enum CircuitState: String, Sendable, CustomStringConvertible {
    case closed      // Normal operation
    case open        // Failing fast
    case halfOpen    // Testing recovery

    public var description: String {
      switch self {
      case .closed: return "closed"
      case .open: return "open"
      case .halfOpen: return "half-open"
      }
    }
  }

  /// Thread-safe circuit breaker state
  actor CircuitBreaker {
    private var failureCount: Int = 0
    private var lastFailureTime: Date?
    private var state: XPCHealth.CircuitState = .closed

    func canExecute(config: Configuration) -> Bool {
      switch state {
      case .closed:
        return true
      case .open:
        // Check if we should transition to half-open
        if let lastFail = lastFailureTime,
           Date().timeIntervalSince(lastFail) >= config.circuitBreakerResetDuration {
          state = .halfOpen
          return true
        }
        return false
      case .halfOpen:
        return true
      }
    }

    func recordSuccess() {
      failureCount = 0
      lastFailureTime = nil
      state = .closed
    }

    func recordFailure(config: Configuration) {
      failureCount += 1
      lastFailureTime = Date()

      if failureCount >= config.circuitBreakerThreshold {
        state = .open
      }
    }

    func getState() -> CircuitState {
      state
    }
  }

  // Shared circuit breaker instance
  private static let circuitBreaker = CircuitBreaker()

  // MARK: - Health Check Results

  /// Result of XPC health verification
  public struct HealthStatus: Sendable {
    public let isHealthy: Bool
    public let daemonRunning: Bool
    public let connectionValid: Bool
    public let apiResponsive: Bool
    public let diagnostics: XPCDiagnostics
    public let issues: [XPCIssue]
    public let circuitState: CircuitState

    public init(
      isHealthy: Bool,
      daemonRunning: Bool,
      connectionValid: Bool,
      apiResponsive: Bool,
      diagnostics: XPCDiagnostics,
      issues: [XPCIssue],
      circuitState: CircuitState = .closed
    ) {
      self.isHealthy = isHealthy
      self.daemonRunning = daemonRunning
      self.connectionValid = connectionValid
      self.apiResponsive = apiResponsive
      self.diagnostics = diagnostics
      self.issues = issues
      self.circuitState = circuitState
    }
  }

  /// Collected diagnostic information
  public struct XPCDiagnostics: Sendable {
    public let containerVersion: String?
    public let daemonPID: Int?
    public let connectionState: String
    public let lastSuccessfulCheck: Date
    public let systemLoad: Double?
    public let availableMemory: UInt64?
    public let responseTime: TimeInterval?
    public let consecutiveFailures: Int

    public init(
      containerVersion: String? = nil,
      daemonPID: Int? = nil,
      connectionState: String = "unknown",
      lastSuccessfulCheck: Date = Date(),
      systemLoad: Double? = nil,
      availableMemory: UInt64? = nil,
      responseTime: TimeInterval? = nil,
      consecutiveFailures: Int = 0
    ) {
      self.containerVersion = containerVersion
      self.daemonPID = daemonPID
      self.connectionState = connectionState
      self.lastSuccessfulCheck = lastSuccessfulCheck
      self.systemLoad = systemLoad
      self.availableMemory = availableMemory
      self.responseTime = responseTime
      self.consecutiveFailures = consecutiveFailures
    }
  }

  /// Represents a detected issue with XPC
  public enum XPCIssue: Error, Sendable {
    case daemonNotRunning
    case connectionInvalid
    case apiTimeout
    case daemonUnresponsive
    case circuitBreakerOpen
    case unknown(String)

    public var description: String {
      switch self {
      case .daemonNotRunning:
        return "Apple Container daemon is not running"
      case .connectionInvalid:
        return "XPC connection is invalid (run 'container system-reset' to fix)"
      case .apiTimeout:
        return "Container API timed out during health check"
      case .daemonUnresponsive:
        return "Container daemon is not responding to XPC messages"
      case .circuitBreakerOpen:
        return "Circuit breaker is open - too many consecutive failures"
      case .unknown(let message):
        return "Unknown XPC issue: \(message)"
      }
    }
  }

  // MARK: - Public API

  /// Default configuration
  public static let defaultConfiguration = Configuration()

  /// Verify XPC connection can send/receive messages with timeout protection
  /// - Parameters:
  ///   - config: Health check configuration (uses defaults if not provided)
  /// - Returns: Health status with detailed diagnostics
  /// - Throws: XPCIssue if critical problems detected
  public static func verifyConnection(
    config: Configuration = defaultConfiguration
  ) async throws -> HealthStatus {
    // Check circuit breaker
    let canExecute = await circuitBreaker.canExecute(config: config)
    if !canExecute {
      let diagnostics = XPCDiagnostics(
        connectionState: "circuit_breaker_open",
        consecutiveFailures: config.circuitBreakerThreshold
      )
      return HealthStatus(
        isHealthy: false,
        daemonRunning: false,
        connectionValid: false,
        apiResponsive: false,
        diagnostics: diagnostics,
        issues: [.circuitBreakerOpen],
        circuitState: .open
      )
    }

    // Perform health check with retries
    var lastError: Error?
    var lastDiagnostics: XPCDiagnostics?

    for attempt in 0..<config.maxRetries {
      if attempt > 0 {
        try await Task.sleep(nanoseconds: UInt64(config.retryDelay * 1_000_000_000))
      }

      do {
        let startTime = Date()
        let status = try await performHealthCheck(
          config: config,
          startTime: startTime
        )

        // Record success in circuit breaker
        await circuitBreaker.recordSuccess()
        return status

      } catch let error as XPCIssue {
        lastError = error
        lastDiagnostics = XPCDiagnostics(
          connectionState: "error: \(error.description)",
          lastSuccessfulCheck: Date(),
          consecutiveFailures: attempt + 1
        )

        // Don't retry on circuit breaker or daemon not running
        if case .circuitBreakerOpen = error {
          break
        }
        if case .daemonNotRunning = error {
          break
        }
      }
    }

    // Record failure in circuit breaker
    await circuitBreaker.recordFailure(config: config)

    // Return final health status with failure info
    return HealthStatus(
      isHealthy: false,
      daemonRunning: lastDiagnostics?.daemonPID != nil,
      connectionValid: false,
      apiResponsive: false,
      diagnostics: lastDiagnostics ?? XPCDiagnostics(connectionState: "unknown"),
      issues: [lastError as? XPCIssue ?? .unknown("\(lastError ?? "Unknown error")")],
      circuitState: await circuitBreaker.getState()
    )
  }

  /// Perform actual health check with timeout
  private static func performHealthCheck(
    config: Configuration,
    startTime: Date
  ) async throws -> HealthStatus {
    // Collect diagnostics with timeout protection
    let daemonPID = getDaemonPID()
    let load = getSystemLoad()
    let memory = getAvailableMemory()

    // Check daemon running
    guard daemonPID != nil else {
      throw XPCIssue.daemonNotRunning
    }

    // Test connection with timeout
    let connectionResult = try await withTimeout(
      seconds: config.healthCheckTimeout
    ) {
      await testConnectionState()
    }

    let connectionValid = connectionResult == "connected"

    // Get version with timeout
    var version: String?
    var responseTime: TimeInterval?
    do {
      let versionStart = Date()
      version = try await withTimeout(seconds: config.healthCheckTimeout) {
        try await getContainerVersion()
      }
      responseTime = Date().timeIntervalSince(versionStart)
    } catch {
      // Version check failed but we have a valid connection
      version = nil
      responseTime = Date().timeIntervalSince(startTime)
    }

    let apiResponsive = version != nil
    let diagnostics = XPCDiagnostics(
      containerVersion: version,
      daemonPID: daemonPID,
      connectionState: connectionResult,
      lastSuccessfulCheck: Date(),
      systemLoad: load,
      availableMemory: memory,
      responseTime: responseTime
    )

    // Build issues list
    var issues: [XPCIssue] = []
    if !connectionValid {
      issues.append(.connectionInvalid)
    }
    if !apiResponsive && connectionValid {
      issues.append(.daemonUnresponsive)
    }

    let isHealthy = issues.isEmpty && connectionValid && apiResponsive

    return HealthStatus(
      isHealthy: isHealthy,
      daemonRunning: true,
      connectionValid: connectionValid,
      apiResponsive: apiResponsive,
      diagnostics: diagnostics,
      issues: issues,
      circuitState: await circuitBreaker.getState()
    )
  }

  /// Quick health check without detailed diagnostics
  /// - Returns: true if XPC is healthy, false otherwise
  public static func isHealthy(config: Configuration = defaultConfiguration) async -> Bool {
    do {
      let status = try await verifyConnection(config: config)
      return status.isHealthy
    } catch {
      return false
    }
  }

  /// Check if container daemon is running
  /// - Returns: PID of daemon if running, nil otherwise
  public static func getDaemonPID() -> Int? {
    // Check if daemon is running via launchctl
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["list"]

    let pipe = Pipe()
    task.standardOutput = pipe

    do {
      try task.run()
      task.waitUntilExit()

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      guard let output = String(data: data, encoding: .utf8) else {
        return nil
      }

      // Look for com.apple.container process
      // Format: PID Status Label
      // Example: 12345 0 com.apple.container
      let lines = output.split(separator: "\n")
      for line in lines {
        if line.contains("com.apple.container") {
          let parts = line.split(separator: " ", omittingEmptySubsequences: true)
          if let pidString = parts.first, let pid = Int(pidString) {
            return pid
          }
        }
      }

      return nil
    } catch {
      return nil
    }
  }

  /// Find the container CLI executable in common locations
  /// - Returns: Path to container CLI if found, nil otherwise
  private static func findContainerCLI() -> String? {
    let paths = [
      "/usr/local/bin/container",
      "/usr/bin/container",
      "/opt/homebrew/bin/container"
    ]

    for path in paths {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }

    // Try to find in PATH
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      let pathDirs = path.split(separator: ":")
      for dir in pathDirs {
        let containerPath = "\(dir)/container"
        if FileManager.default.isExecutableFile(atPath: containerPath) {
          return containerPath
        }
      }
    }

    return nil
  }

  /// Actor to track continuation resume state
  private actor ContinuationTracker<T: Sendable> {
    private var resumed = false
    private let continuation: CheckedContinuation<T, Error>

    init(continuation: CheckedContinuation<T, Error>) {
      self.continuation = continuation
    }

    func resume(returning value: T) {
      guard !resumed else { return }
      resumed = true
      continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
      guard !resumed else { return }
      resumed = true
      continuation.resume(throwing: error)
    }
  }

  /// Get container CLI version (tests API responsiveness) with timeout
  /// - Returns: Version string if API is responsive
  /// - Throws: Error if API is unresponsive
  public static func getContainerVersion(timeout: TimeInterval = 10) async throws -> String {
    guard let containerPath = findContainerCLI() else {
      throw XPCIssue.daemonNotRunning
    }

    return try await withCheckedThrowingContinuation { continuation in
      let task = Process()
      task.executableURL = URL(fileURLWithPath: containerPath)
      task.arguments = ["--version"]

      let pipe = Pipe()
      task.standardOutput = pipe

      // Use actor for thread-safe continuation tracking
      let tracker = ContinuationTracker<String>(continuation: continuation)

      // Set up timeout
      let timeoutTask = Task {
        do {
          try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
          task.terminate()
          await tracker.resume(throwing: XPCIssue.apiTimeout)
        } catch {
          // Task was cancelled, don't resume
        }
      }

      task.terminationHandler = { _ in
        timeoutTask.cancel()

        Task {
          guard task.terminationStatus == 0 else {
            if task.terminationStatus == SIGTERM {
              await tracker.resume(throwing: XPCIssue.apiTimeout)
            } else {
              await tracker.resume(throwing: XPCIssue.daemonUnresponsive)
            }
            return
          }

          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          guard let output = String(data: data, encoding: .utf8) else {
            await tracker.resume(throwing: XPCIssue.daemonUnresponsive)
            return
          }

          // Extract version from output
          if let version = extractVersion(from: output) {
            await tracker.resume(returning: version)
          } else {
            // If we got output but couldn't parse version, API is responsive
            await tracker.resume(returning: "unknown")
          }
        }
      }

      do {
        try task.run()
      } catch {
        timeoutTask.cancel()
        Task {
          await tracker.resume(throwing: XPCIssue.daemonUnresponsive)
        }
      }
    }
  }

  /// Extract version string from container CLI output
  private static func extractVersion(from output: String) -> String? {
    // Pattern 1: "container CLI version X.Y.Z"
    let pattern1 = #"container CLI version (\d+\.\d+\.\d+)"#
    if let regex1 = try? NSRegularExpression(pattern: pattern1, options: []),
       let match = regex1.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)),
       let range = Range(match.range(at: 1), in: output) {
      return String(output[range])
    }

    // Pattern 2: "version X.Y.Z"
    let pattern2 = #"version (\d+\.\d+\.\d+)"#
    if let regex2 = try? NSRegularExpression(pattern: pattern2, options: []),
       let match = regex2.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)),
       let range = Range(match.range(at: 1), in: output) {
      return String(output[range])
    }

    return nil
  }

  /// Collect diagnostic information for troubleshooting
  /// - Returns: Detailed diagnostics
  public static func collectDiagnostics(config: Configuration = defaultConfiguration) async -> XPCDiagnostics {
    let startTime = Date()
    do {
      let version = try await withTimeout(seconds: config.healthCheckTimeout) {
        try await getContainerVersion()
      }
      let responseTime = Date().timeIntervalSince(startTime)
      return XPCDiagnostics(
        containerVersion: version,
        daemonPID: getDaemonPID(),
        connectionState: "connected",
        lastSuccessfulCheck: Date(),
        systemLoad: getSystemLoad(),
        availableMemory: getAvailableMemory(),
        responseTime: responseTime
      )
    } catch {
      return XPCDiagnostics(
        containerVersion: nil,
        daemonPID: getDaemonPID(),
        connectionState: "error: \(error.localizedDescription)",
        lastSuccessfulCheck: Date(),
        systemLoad: getSystemLoad(),
        availableMemory: getAvailableMemory(),
        responseTime: Date().timeIntervalSince(startTime)
      )
    }
  }

  /// Execute an operation with a timeout
  /// - Parameters:
  ///   - seconds: Timeout duration
  ///   - operation: Async operation to execute
  /// - Returns: Result of the operation
  /// - Throws: XPCIssue.apiTimeout if operation times out
  public static func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      let task = Task {
        do {
          let result = try await operation()
          continuation.resume(returning: result)
        } catch {
          continuation.resume(throwing: error)
        }
      }

      Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        task.cancel()
        continuation.resume(throwing: XPCIssue.apiTimeout)
      }
    }
  }

  // MARK: - Private Helpers

  /// Test XPC connection state by making a lightweight API call
  private static func testConnectionState() async -> String {
    do {
      // Try a lightweight operation to verify connection
      _ = try await getContainerVersion()
      return "connected"
    } catch {
      // Check if it's a connection issue vs timeout
      let errorMessage = error.localizedDescription.lowercased()
      if errorMessage.contains("connection") || errorMessage.contains("invalid") {
        return "invalid"
      } else if errorMessage.contains("timeout") {
        return "timeout"
      }
      return "error"
    }
  }

  /// Get system load average
  private static func getSystemLoad() -> Double? {
    // getloadavg is thread-safe for reading
    var load = [Double](repeating: 0.0, count: 3)
    let count = getloadavg(&load, 3)
    guard count > 0 else { return nil }
    return load[0] // 1-minute load average
  }

  /// Get available memory in bytes
  private static func getAvailableMemory() -> UInt64? {
    var vmStats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

    let result = withUnsafeMutablePointer(to: &vmStats) { statsPtr in
      statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, ptr, &count)
      }
    }

    guard result == KERN_SUCCESS else { return nil }

    // Get page size using sysctl (thread-safe)
    var pageSize: Int = 0
    var size = MemoryLayout<Int>.size
    let sysctlResult = sysctlbyname("hw.pagesize", &pageSize, &size, nil, 0)
    guard sysctlResult == 0 else { return nil }

    let free = UInt64(vmStats.free_count) * UInt64(pageSize)
    return free
  }
}

// MARK: - Custom String Convertibles

extension XPCHealth.HealthStatus: CustomStringConvertible {
  public var description: String {
    let statusIcon = isHealthy ? "✓" : "✗"
    let statusText = isHealthy ? "Healthy" : "Unhealthy"

    var desc = "\(statusIcon) XPC Health: \(statusText)\n"
    desc += " Circuit State: \(circuitState)\n"
    desc += " Daemon Running: \(daemonRunning ? "✓" : "✗")\n"
    desc += " Connection Valid: \(connectionValid ? "✓" : "✗")\n"
    desc += " API Responsive: \(apiResponsive ? "✓" : "✗")\n"

    if !issues.isEmpty {
      desc += "\nIssues Detected:\n"
      for issue in issues {
        desc += " • \(issue.description)\n"
      }
    }

    desc += "\nDiagnostics:\n"
    if let version = diagnostics.containerVersion {
      desc += " Container Version: \(version)\n"
    }
    if let pid = diagnostics.daemonPID {
      desc += " Daemon PID: \(pid)\n"
    }
    desc += " Connection State: \(diagnostics.connectionState)\n"
    if let load = diagnostics.systemLoad {
      desc += " System Load: \(String(format: "%.2f", load))\n"
    }
    if let memory = diagnostics.availableMemory {
      let mb = Double(memory) / 1_048_576.0
      desc += " Available Memory: \(String(format: "%.1f", mb)) MB\n"
    }
    if let responseTime = diagnostics.responseTime {
      desc += " Response Time: \(String(format: "%.3f", responseTime))s\n"
    }
    if diagnostics.consecutiveFailures > 0 {
      desc += " Consecutive Failures: \(diagnostics.consecutiveFailures)\n"
    }

    return desc
  }
}

extension XPCHealth.XPCDiagnostics: CustomStringConvertible {
  public var description: String {
    var desc = "XPC Diagnostics:\n"
    if let version = containerVersion {
      desc += " Container Version: \(version)\n"
    }
    if let pid = daemonPID {
      desc += " Daemon PID: \(pid)\n"
    }
    desc += " Connection State: \(connectionState)\n"
    if let load = systemLoad {
      desc += " System Load: \(String(format: "%.2f", load))\n"
    }
    if let memory = availableMemory {
      let mb = Double(memory) / 1_048_576.0
      desc += " Available Memory: \(String(format: "%.1f", mb)) MB\n"
    }
    if let responseTime = responseTime {
      desc += " Response Time: \(String(format: "%.3f", responseTime))s\n"
    }
    if consecutiveFailures > 0 {
      desc += " Consecutive Failures: \(consecutiveFailures)\n"
    }
    desc += " Last Check: \(lastSuccessfulCheck)\n"
    return desc
  }
}
