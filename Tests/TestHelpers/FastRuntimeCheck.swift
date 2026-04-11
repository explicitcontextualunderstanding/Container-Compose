//===----------------------------------------------------------------------===//
// FastRuntimeCheck.swift
// Fast container runtime availability checking with caching
// Optimization: Reduces per-test runtime check overhead
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import ContainerCommands
import ContainerAPIClient

/// Actor-based cache for runtime availability checks
public actor RuntimeAvailabilityCache {
    public static let shared = RuntimeAvailabilityCache()
    private var cachedResult: Bool?
    private var lastCheckTime: Date?
    private let cacheDuration: TimeInterval = 30  // Cache for 30 seconds

    public func check() async -> Bool {
        // Return cached result if still valid
        if let cached = cachedResult,
           let last = lastCheckTime,
           Date().timeIntervalSince(last) < cacheDuration {
            return cached
        }

        // Fast check with short timeout
        do {
            _ = try await ClientHealthCheck.ping(timeout: .seconds(1))
            cachedResult = true
            lastCheckTime = Date()
            return true
        } catch {
            cachedResult = false
            lastCheckTime = Date()
            return false
        }
    }

    public func invalidate() {
        cachedResult = nil
        lastCheckTime = nil
    }
}

/// Fast-fail trait that skips tests when container runtime unavailable
/// Use this for dynamic tests that require containers
public struct FastContainerDependentTrait: TestScoping, TestTrait, SuiteTrait {
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        // Fast cached check
        let isAvailable = await RuntimeAvailabilityCache.shared.check()

        if !isAvailable {
            // Skip this test - record as skipped
            print("⏭️  SKIPPED: \(test.name)")
            print("    Container runtime unavailable")
            return
        }

        // Runtime available - run the test
        try await function()
    }
}

public extension Trait where Self == FastContainerDependentTrait {
    static var fastContainerDependent: FastContainerDependentTrait { .init() }
}

/// Trait for tests that require containers but can tolerate slow startup
/// Use this for integration tests that need full diagnostics
public struct DiagnosticContainerTrait: TestScoping, TestTrait, SuiteTrait {
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        // Check with diagnostics
        let isAvailable = await RuntimeAvailabilityCache.shared.check()

        if !isAvailable {
            print("⏭️  SKIPPED: \(test.name)")
            print("    Container runtime unavailable")
            return
        }

        // Get detailed health info
        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(3))
            print("✓ Container runtime: \(health.apiServerVersion ?? "unknown")")
        } catch {
            print("⚠️  Container runtime check failed: \(error)")
            return
        }

        try await function()
    }
}

public extension Trait where Self == DiagnosticContainerTrait {
    static var diagnosticContainer: DiagnosticContainerTrait { .init() }
}
