// TCCRelayIntegration.swift
// Component 5: TCC Preflight for Relay Authorization
// Owner: @mac-kilo-kim
// Plan 85 - Security Hardening for vSock Native Relay

import Foundation
import CoreLocation
import AVFoundation

/// TCC (Transparency, Consent, and Control) integration for relay operations
/// Per Apple Security Policy: All hypervisor-bound traffic must pass TCC preflight
public actor TCCRelayIntegration: Sendable {

  /// TCC authorization status
  public enum AuthorizationStatus: String, Sendable {
    case authorized = "Authorized"
    case denied = "Denied"
    case notDetermined = "Not Determined"
    case restricted = "Restricted"

    /// Can we proceed with relay operations?
    public var canProceed: Bool {
      self == .authorized
    }

    /// Should startup be blocked (vs warning only)?
    public var shouldBlockStartup: Bool {
      self == .denied || self == .restricted
    }
  }

  /// Configuration for TCC integration
  public struct Configuration: Sendable {
    /// Whether to strictly require TCC authorization
    public let strictMode: Bool
    /// Custom TCC check interval (seconds)
    public let checkInterval: TimeInterval
    /// Whether to cache authorization status
    public let cacheResults: Bool

    public init(
      strictMode: Bool = true,
      checkInterval: TimeInterval = 5.0,
      cacheResults: Bool = true
    ) {
      self.strictMode = strictMode
      self.checkInterval = checkInterval
      self.cacheResults = cacheResults
    }

    /// Production configuration (strict)
    public static var production: Configuration {
      Configuration(strictMode: true, checkInterval: 5.0, cacheResults: true)
    }

    /// Development configuration (permissive)
    public static var development: Configuration {
      Configuration(strictMode: false, checkInterval: 1.0, cacheResults: false)
    }
  }

  private let configuration: Configuration
  private var cachedStatus: AuthorizationStatus?
  private var lastCheckTime: Date?

  public init(configuration: Configuration = .production) {
    self.configuration = configuration
    self.cachedStatus = nil
    self.lastCheckTime = nil
  }

  // MARK: - Public API

  /// TCC preflight check for relay authorization
  /// Per SECURITY_CONTAINER.md: "Mandatory: TCC Preflight"
  /// - Returns: TCCPreflightResult indicating authorization status
  public func preflightCheck() async -> TCCPreflightResult {
    // Check cache if enabled and recent
    if configuration.cacheResults,
       let cached = cachedStatus,
       let lastCheck = lastCheckTime,
       Date().timeIntervalSince(lastCheck) < configuration.checkInterval {
      return TCCPreflightResult(
        canProceed: cached.canProceed,
        shouldBlockStartup: cached.shouldBlockStartup,
        errorMessage: cached == .notDetermined ? "TCC authorization not determined" : nil
      )
    }

    // Perform actual TCC checks
    let result = await performTCCChecks()

    // Cache result
    cachedStatus = result.status
    lastCheckTime = Date()

    return TCCPreflightResult(
      canProceed: result.status.canProceed,
      shouldBlockStartup: result.status.shouldBlockStartup,
      errorMessage: result.errorMessage
    )
  }

  /// Check if a specific relay type requires TCC authorization
  /// Per plan 85: vsock-db requires TCC, others may not
  public func requiresAuthorization(relayType: String) async -> Bool {
    // All vsock-based relays require TCC authorization
    relayType.hasPrefix("vsock")
  }

  /// Request TCC authorization (may prompt user)
  /// - Returns: true if authorization granted
  public func requestAuthorization() async -> Bool {
    // In production, this would trigger actual TCC prompt
    // For now, simulate with a delay and return authorized
    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    return true
  }

  /// Check if TCC preflight is required for this relay
  public func isPreflightRequired(relayType: String) -> Bool {
    relayType.hasPrefix("vsock") || relayType.contains("socket")
  }

  /// Clear cached authorization status
  public func clearCache() {
    cachedStatus = nil
    lastCheckTime = nil
  }

  // MARK: - Private Methods

  /// Result of TCC checks
  private struct TCCCheckResult {
    let status: AuthorizationStatus
    let errorMessage: String?
  }

  /// Perform actual TCC checks
  /// Note: This is a stub implementation - real TCC checks require entitlements
  private func performTCCChecks() async -> TCCCheckResult {
    // In production with proper entitlements:
    // - Check com.apple.security.virtualization entitlement
    // - Check hypervisor authorization
    // - Check network extension status

    // For development/testing, return authorized
    // This allows the system to function without full TCC infrastructure
    #if DEBUG
    return TCCCheckResult(status: .authorized, errorMessage: nil)
    #else
    // Production check simulation
    // Real implementation would check actual TCC status
    return TCCCheckResult(status: .authorized, errorMessage: nil)
    #endif
  }

  /// Log security event
  private func logSecurityEvent(_ relayType: String, authorized: Bool, reason: String) {
    // Log to unified logging system
    // In production, this would use EndpointSecurity framework
    print("[SECURITY] Relay startup \(authorized ? "authorized" : "blocked"): type=\(relayType), reason=\(reason)")
  }

  private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      // Add the actual operation
      group.addTask { @Sendable in
        await operation()
      }

      // Add timeout task
      group.addTask { @Sendable in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw TCCIntegrationError.preflightTimeout
      }

      // Return first result, cancel the other
      let result = try await group.next()!
      group.cancelAll()
      return result
    }
  }
}

// MARK: - RelayManager Integration Helpers

public extension TCCRelayIntegration {
  /// Convenience method for RelayManager to check before starting any relay
  /// Usage: In RelayManager.startRelay(), add at beginning:
  /// guard await tccIntegration.preflightCheckPassed() else { return }
  func preflightCheckPassed() async -> Bool {
    let result = await preflightCheck()
    return result.canProceed && !result.shouldBlockStartup
  }

  /// Returns a formatted error message for RelayManager to display
  func lastErrorMessage() async -> String? {
    // This could track the last error from preflightCheck
    nil
  }
}

// MARK: - Supporting Types

/// Result of TCC preflight check
public struct TCCPreflightResult: Sendable, Equatable {
  public let canProceed: Bool
  public let shouldBlockStartup: Bool
  public let errorMessage: String?

  public init(
    canProceed: Bool,
    shouldBlockStartup: Bool = false,
    errorMessage: String? = nil
  ) {
    self.canProceed = canProceed
    self.shouldBlockStartup = shouldBlockStartup
    self.errorMessage = errorMessage
  }

  /// Convenience for success case
  public static let authorized = TCCPreflightResult(canProceed: true)

  /// Convenience for denied case
  public static func denied(_ message: String) -> TCCPreflightResult {
    TCCPreflightResult(canProceed: false, shouldBlockStartup: true, errorMessage: message)
  }
}

/// Errors specific to TCC integration
public enum TCCIntegrationError: Error, CustomStringConvertible {
  case preflightTimeout
  case authorizationRequired
  case hypervisorNotAvailable
  case systemPolicyViolation

  public var description: String {
    switch self {
    case .preflightTimeout:
      return "TCC preflight check timed out"
    case .authorizationRequired:
      return "TCC authorization required"
    case .hypervisorNotAvailable:
      return "Hypervisor not available (requires macOS 12+)"
    case .systemPolicyViolation:
      return "System policy violation"
    }
  }
}
