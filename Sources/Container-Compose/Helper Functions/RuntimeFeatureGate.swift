import Foundation

/// Apple Container runtime feature detection and gating
/// Provides compatibility layer for 0.10.0 and 0.11.0 runtimes
public enum RuntimeFeatureGate {
    
    // MARK: - Feature Flags
    
    /// Features available in 0.11.0+ only
    public enum Feature: String, CaseIterable {
        case scheme = "--scheme flag for registry protocol control"
        case buildSecrets = "--secret flag for build-time secrets"
        case containerDefaultPlatform = "CONTAINER_DEFAULT_PLATFORM env var"
        case containerPrune = "Container prune on startup"
        
        var minimumVersion: String {
            switch self {
            case .scheme, .buildSecrets, .containerDefaultPlatform, .containerPrune:
                return "0.11.0"
            }
        }
    }
    
    // MARK: - Version Detection
    
  /// Cached runtime version (computed once)
  private static let cachedVersion: String? = {
    // Check common container binary locations
    let possiblePaths = ["/usr/local/bin/container", "/usr/bin/container", "/opt/homebrew/bin/container"]
    guard let containerPath = possiblePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      return nil
    }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: containerPath)
    process.arguments = ["--version"]

let pipe = Pipe()
process.standardOutput = pipe
process.standardError = FileHandle.nullDevice

do {
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else { return nil }

let data = pipe.fileHandleForReading.readDataToEndOfFile()
let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

// Parse "container CLI version X.Y.Z (git: ...)"
let versionPattern = #"container CLI version (\d+\.\d+\.\d+)"#
guard let range = output.range(of: versionPattern, options: .regularExpression) else {
return nil
}

let versionString = String(output[range].dropFirst("container CLI version ".count))
return versionString
} catch {
return nil
}
}()
    
    /// Get current runtime version
    public static var currentVersion: String {
        return cachedVersion ?? "0.10.0" // Default to 0.10.0 if detection fails
    }
    
    // MARK: - Feature Availability
    
    /// Check if a feature is available in current runtime
    public static func isAvailable(_ feature: Feature) -> Bool {
        return isVersionAtLeast(feature.minimumVersion)
    }
    
    /// Compare version strings (returns true if current >= required)
    public static func isVersionAtLeast(_ required: String) -> Bool {
        let current = currentVersion
        
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let requiredParts = required.split(separator: ".").compactMap { Int($0) }
        
        guard !currentParts.isEmpty, !requiredParts.isEmpty else {
            return false
        }
        
        // Pad with zeros to equal length
        let maxLength = max(currentParts.count, requiredParts.count)
        let paddedCurrent = currentParts + Array(repeating: 0, count: maxLength - currentParts.count)
        let paddedRequired = requiredParts + Array(repeating: 0, count: maxLength - requiredParts.count)
        
        // Compare version parts
        for (current, required) in zip(paddedCurrent, paddedRequired) {
            if current > required { return true }
            if current < required { return false }
        }
        
        return true // Versions are equal
    }
    
    // MARK: - Conditional Execution
    
    /// Execute a block only if the feature is available
    public static func ifAvailable(_ feature: Feature, execute: () throws -> Void) rethrows {
        if isAvailable(feature) {
            try execute()
        }
    }
    
    /// Execute a block with feature flag, providing fallback for older runtimes
    public static func withFeature<T>(_ feature: Feature, 
                                       ifAvailable: () throws -> T, 
                                       fallback: () throws -> T) rethrows -> T {
        if isAvailable(feature) {
            return try ifAvailable()
        } else {
            return try fallback()
        }
    }
    
    // MARK: - Environment Override
    
    /// Check if features are explicitly disabled via environment variable
    public static func isFeatureDisabled(_ feature: Feature) -> Bool {
        let envKey = "DISABLE_\(feature.rawValue.uppercased().replacingOccurrences(of: " ", with: "_"))"
        return ProcessInfo.processInfo.environment[envKey] == "1"
    }
    
    /// Force disable a feature (useful for testing)
    public static func disableFeature(_ feature: Feature) {
        let envKey = "DISABLE_\(feature.rawValue.uppercased().replacingOccurrences(of: " ", with: "_"))"
        setenv(envKey, "1", 1)
    }
}
