import Foundation
import ContainerComposeCore
import ContainerCommands
import ContainerAPIClient

public enum ContainerTestError: Error, CustomStringConvertible {
    case xpcTimeout(String)
    case containerNotReady(String)
    case stateMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .xpcTimeout(let message):
            return "XPC timeout: \(message)"
        case .containerNotReady(let name):
            return "Container not ready: \(name)"
        case .stateMismatch(let expected, let actual):
            return "State mismatch: expected \(expected), got \(actual)"
        }
    }
}

public actor ContainerReliabilityHelper {
    private let maxRetries: Int
    private let retryDelay: UInt64
    private let statePollingTimeout: TimeInterval

    public init(
        maxRetries: Int = 3,
        retryDelaySeconds: Double = 2.0,
        statePollingTimeout: TimeInterval = 30.0
    ) {
        self.maxRetries = maxRetries
        self.retryDelay = UInt64(retryDelaySeconds * 1_000_000_000)
        self.statePollingTimeout = statePollingTimeout
    }

    public func stopWithRetry(container: ClientContainer, name: String) async throws {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                try await container.stop()
                return
            } catch {
                lastError = error
                let errorString = String(describing: error)

                if errorString.contains("XPC timeout") || errorString.contains("timeout") {
                    print("Warning: XPC timeout on stop attempt \(attempt)/\(maxRetries) for \(name)")
                    if attempt < maxRetries {
                        try await Task.sleep(nanoseconds: retryDelay)
                    }
                } else {
                    throw error
                }
            }
        }

        if let error = lastError {
            print("Warning: All \(maxRetries) stop attempts failed for \(name), container may still be stopping")
        }
    }

    public func waitForState(
        container: ClientContainer,
        expectedState: ContainerStatus,
        timeout: TimeInterval? = nil
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout ?? statePollingTimeout)

        while Date() < deadline {
            let refreshed = try await ClientContainer.get(id: container.configuration.id)
            if refreshed.status == expectedState {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw ContainerTestError.stateMismatch(
            expected: String(describing: expectedState),
            actual: String(describing: container.status)
        )
    }

    public func withRetry<T>(
        maxAttempts: Int = 3,
        delay_ns: UInt64 = 2_000_000_000,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                let errorString = String(describing: error)

                if errorString.contains("XPC timeout") || errorString.contains("timeout") {
                    print("Warning: XPC error on attempt \(attempt)/\(maxAttempts)")
                    if attempt < maxAttempts {
                        try await Task.sleep(nanoseconds: delay_ns)
                    }
                } else {
                    throw error
                }
            }
        }

        throw lastError ?? ContainerTestError.xpcTimeout("All attempts failed")
    }

    public func cleanupContainer(id: String) async {
        do {
            if let container = try? await ClientContainer.get(id: id) {
                try? await stopWithRetry(container: container, name: id)
                try? await container.delete()
            }
        } catch {
            print("Warning: Failed to cleanup container \(id): \(error)")
        }
    }
}

public struct ContainerTestCleanup: @unchecked Sendable {
    private let helper: ContainerReliabilityHelper
    private let containerIds: [String]

    public init(ids: [String]) {
        self.helper = ContainerReliabilityHelper()
        self.containerIds = ids
    }

    public func perform() async {
        for id in containerIds {
            await helper.cleanupContainer(id: id)
        }
    }
}