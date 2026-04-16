import Foundation
import ContainerAPIClient
import Testing

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

  // Apple Container runtime adds CCT_orphan_ prefix to container names
  private static let appleContainerPrefix = "CCT_orphan_"

  public init(
    maxRetries: Int = 3,
    retryDelaySeconds: Double = 2.0,
    statePollingTimeout: TimeInterval = 30.0
  ) {
    self.maxRetries = maxRetries
    self.retryDelay = UInt64(retryDelaySeconds * 1_000_000_000)
    self.statePollingTimeout = statePollingTimeout
  }

  /// Resolves a container name/ID to its actual container ID, handling Apple Container's
  /// `CCT_orphan_` prefix that gets added to container identifiers.
  /// - Parameter name: The container name or ID to resolve
  /// - Returns: The resolved container
  /// - Throws: ContainerTestError if the container cannot be found
  public func resolveContainer(name: String) async throws -> ClientContainer {
    // Try exact match first
    do {
      return try await ClientContainer.get(id: name)
    } catch {
      // Not found with exact name, try with Apple Container prefix
    }

    // If name already has the prefix, it's not going to be found
    if name.hasPrefix(Self.appleContainerPrefix) {
      throw ContainerTestError.containerNotReady(
        "Container '\(name)' not found. " +
        "Note: Apple Container may have modified the container identifier."
      )
    }

    // Try with Apple Container prefix
    let prefixedName = Self.appleContainerPrefix + name
    do {
      return try await ClientContainer.get(id: prefixedName)
    } catch {
      // Not found with prefix either
    }

    // Try searching all containers for CCT_<runId>_ prefixed match
    // Apple Container adds CCT_<runId>_ prefix (e.g., CCT_t20953_ps_stop_...)
    let allContainers = try await ClientContainer.list()
    if let match = allContainers.first(where: { c in
      let id = c.configuration.id
      if id.hasPrefix("CCT_"), let secondUnderscore = id.dropFirst(4).firstIndex(of: "_") {
        return String(id[id.index(after: secondUnderscore)...]) == name
      }
      return false
    }) {
      return match
    }

    throw ContainerTestError.containerNotReady(
      "Container '\(name)' not found (tried exact, CCT_orphan_, and CCT_<runId>_ prefixes). " +
      "The container may have been removed or the name may be incorrect."
    )
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
        expectedStatus: String,
        timeout: TimeInterval? = nil
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout ?? statePollingTimeout)

        while Date() < deadline {
            let refreshed = try await ClientContainer.get(id: container.configuration.id)
            if String(describing: refreshed.status) == expectedStatus {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw ContainerTestError.stateMismatch(
            expected: expectedStatus,
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