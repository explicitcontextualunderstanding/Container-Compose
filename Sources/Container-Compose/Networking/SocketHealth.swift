//===----------------------------------------------------------------------===//
// SocketHealth.swift
// Reliable socket readiness verification with circuit breaker and diagnostics
// Inspired by XPCHealth pattern for production-grade reliability
//===----------------------------------------------------------------------===//

import ContainerAPIClient
import Foundation

/// Socket readiness verification with circuit breaker pattern
public enum SocketHealth {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let socketTimeout: TimeInterval
        public let circuitBreakerThreshold: Int
        public let circuitBreakerResetDuration: TimeInterval
        public let initialPollingInterval: TimeInterval
        public let maxPollingInterval: TimeInterval
        public let backoffMultiplier: Double
        public let verifyContainerRunning: Bool
        public let containerStartupTimeout: TimeInterval

        public init(
            socketTimeout: TimeInterval = 60,
            circuitBreakerThreshold: Int = 5,
            circuitBreakerResetDuration: TimeInterval = 60,
            initialPollingInterval: TimeInterval = 0.05,
            maxPollingInterval: TimeInterval = 1.0,
            backoffMultiplier: Double = 1.5,
            verifyContainerRunning: Bool = true,
            containerStartupTimeout: TimeInterval = 30
        ) {
            self.socketTimeout = socketTimeout
            self.circuitBreakerThreshold = circuitBreakerThreshold
            self.circuitBreakerResetDuration = circuitBreakerResetDuration
            self.initialPollingInterval = initialPollingInterval
            self.maxPollingInterval = maxPollingInterval
            self.backoffMultiplier = backoffMultiplier
            self.verifyContainerRunning = verifyContainerRunning
            self.containerStartupTimeout = containerStartupTimeout
        }
    }

    // MARK: - Circuit Breaker

    public enum CircuitState: String, Sendable {
        case closed, open, halfOpen
    }

    actor CircuitBreaker {
        private var failureCount = 0
        private var lastFailureTime: Date?
        private var state: CircuitState = .closed

        func canExecute(config: Configuration) -> Bool {
            switch state {
            case .closed: return true
            case .open:
                if let lastFail = lastFailureTime,
                   Date().timeIntervalSince(lastFail) >= config.circuitBreakerResetDuration {
                    state = .halfOpen
                    return true
                }
                return false
            case .halfOpen: return true
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

        func getState() -> CircuitState { state }
    }

    // MARK: - Circuit Breaker Registry (Actor-protected)

    actor CircuitBreakerRegistry {
        private var circuitBreakers: [String: CircuitBreaker] = [:]

        func getCircuitBreaker(for path: String) -> CircuitBreaker {
            if let existing = circuitBreakers[path] { return existing }
            let new = CircuitBreaker()
            circuitBreakers[path] = new
            return new
        }

        func removeCircuitBreaker(for path: String) {
            circuitBreakers.removeValue(forKey: path)
        }

        func getCircuitState(for path: String) async -> CircuitState? {
            await circuitBreakers[path]?.getState()
        }
    }

    private static let registry = CircuitBreakerRegistry()

    private static func getCircuitBreaker(for path: String) async -> CircuitBreaker {
        await registry.getCircuitBreaker(for: path)
    }

    // MARK: - Result Types

    public struct SocketStatus: Sendable {
        public let isReady: Bool
        public let circuitState: CircuitState
        public let attempts: Int
        public let totalWaitTime: TimeInterval
        public let error: SocketError?

        public init(isReady: Bool, circuitState: CircuitState, attempts: Int, totalWaitTime: TimeInterval, error: SocketError? = nil) {
            self.isReady = isReady
            self.circuitState = circuitState
            self.attempts = attempts
            self.totalWaitTime = totalWaitTime
            self.error = error
        }
    }

    public enum SocketError: Error, Sendable {
        case circuitBreakerOpen
        case timeout(waited: TimeInterval, attempts: Int)
        case notSocket(path: String)
        case containerNotRunning(containerId: String)
        case containerStartupTimeout(containerId: String, waited: TimeInterval)

        public var description: String {
            switch self {
            case .circuitBreakerOpen:
                return "Circuit breaker open - too many consecutive failures"
            case .timeout(let waited, let attempts):
                return "Socket timeout after \(String(format: "%.1f", waited))s (\(attempts) attempts)"
            case .notSocket(let path):
                return "File exists but is not a socket: \(path)"
            case .containerNotRunning(let id):
                return "Container '\(id)' is not running"
            case .containerStartupTimeout(let id, let waited):
                return "Container '\(id)' did not start within \(String(format: "%.1f", waited))s"
            }
        }
    }

    // MARK: - Public API

    public static let defaultConfiguration = Configuration()

    /// Wait for socket with circuit breaker and exponential backoff
    public static func waitForSocket(
        socketPath: String,
        containerId: String? = nil,
        config: Configuration = defaultConfiguration
    ) async -> SocketStatus {
        let breaker = await getCircuitBreaker(for: socketPath)
        let startTime = Date()

        // Check circuit breaker
        let canExecute = await breaker.canExecute(config: config)
        if !canExecute {
            return SocketStatus(
                isReady: false,
                circuitState: .open,
                attempts: 0,
                totalWaitTime: 0,
                error: .circuitBreakerOpen
            )
        }

        // Wait for container to start (if specified)
        if let cid = containerId, config.verifyContainerRunning {
            let containerStart = Date()
            var containerRunning = false

            while Date().timeIntervalSince(containerStart) < config.containerStartupTimeout {
                do {
                    let container = try await ClientContainer.get(id: cid)
                    if container.status == .running {
                        containerRunning = true
                        break
                    }
                } catch {
                    // Container may not exist yet
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            if !containerRunning {
                await breaker.recordFailure(config: config)
                return SocketStatus(
                    isReady: false,
                    circuitState: await breaker.getState(),
                    attempts: 0,
                    totalWaitTime: Date().timeIntervalSince(startTime),
                    error: .containerStartupTimeout(containerId: cid, waited: config.containerStartupTimeout)
                )
            }
        }

        // Poll for socket with exponential backoff
        var currentInterval = config.initialPollingInterval
        var attempts = 0
        let fileManager = FileManager.default

        while Date().timeIntervalSince(startTime) < config.socketTimeout {
            attempts += 1

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: socketPath, isDirectory: &isDirectory) {
                var statInfo = stat()
                if stat(socketPath, &statInfo) == 0 {
                    if (statInfo.st_mode & S_IFMT) == S_IFSOCK {
                        await breaker.recordSuccess()
                        return SocketStatus(
                            isReady: true,
                            circuitState: .closed,
                            attempts: attempts,
                            totalWaitTime: Date().timeIntervalSince(startTime)
                        )
                    } else {
                        await breaker.recordFailure(config: config)
                        return SocketStatus(
                            isReady: false,
                            circuitState: await breaker.getState(),
                            attempts: attempts,
                            totalWaitTime: Date().timeIntervalSince(startTime),
                            error: .notSocket(path: socketPath)
                        )
                    }
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))
            currentInterval = min(currentInterval * config.backoffMultiplier, config.maxPollingInterval)
        }

        await breaker.recordFailure(config: config)
        return SocketStatus(
            isReady: false,
            circuitState: await breaker.getState(),
            attempts: attempts,
            totalWaitTime: Date().timeIntervalSince(startTime),
            error: .timeout(waited: config.socketTimeout, attempts: attempts)
        )
    }

    /// Reset circuit breaker for a specific socket path
    public static func resetCircuitBreaker(for socketPath: String) {
        Task {
            await registry.removeCircuitBreaker(for: socketPath)
        }
    }

    /// Get circuit breaker state for diagnostics
    public static func getCircuitState(for socketPath: String) async -> CircuitState {
        if let state = await registry.getCircuitState(for: socketPath) {
            return state
        }
        return .closed
    }
}
