//===----------------------------------------------------------------------===//
// ContainerTelemetry.swift
// Phase-based telemetry for CCT_* test containers
// Captures snapshots at lifecycle boundaries using ContainerAPIClient (no shell)
//===----------------------------------------------------------------------===//

import Foundation
import ContainerAPIClient
import ContainerResource

/// Telemetry snapshot at a specific lifecycle phase.
///
/// Memory values come from `ContainerStats.memoryUsageBytes` (physical working set,
/// not RSS — shared pages are not double-counted on Apple Virtualization Framework).
public struct TelemetrySnapshot: Sendable, Codable {
    public let timestamp: Date
    public let phase: TelemetryPhase
    public let containerId: String
    public let containerName: String
    public let imageReference: String
    public let testName: String?

    // Memory (from ContainerStats)
    public let memoryUsageBytes: UInt64
    public let memoryLimitBytes: UInt64

    // CPU cumulative usage (microseconds, from ContainerStats)
    public let cpuUsageUsec: UInt64

    // Network I/O (cumulative bytes)
    public let networkRxBytes: UInt64
    public let networkTxBytes: UInt64

    // Process count
    public let numProcesses: UInt64

    public var memoryUsageMB: Double {
        Double(memoryUsageBytes) / (1024 * 1024)
    }

    public var memoryLimitMB: Double {
        Double(memoryLimitBytes) / (1024 * 1024)
    }

    public var wasteMB: Double {
        memoryLimitMB - memoryUsageMB
    }

    public var wastePercent: Double {
        guard memoryLimitMB > 0 else { return 0 }
        return (wasteMB / memoryLimitMB) * 100
    }
}

/// Test lifecycle phases for snapshot capture.
public enum TelemetryPhase: String, Sendable, Codable, CaseIterable {
    case created = "created"        // Container created, not yet started
    case started = "started"        // Container running (post-bootstrap)
    case testEntered = "test_enter" // Test body entered (post-setup)
    case peakWorkload = "peak"      // During peak workload
    case released = "released"      // Container released / cleaned up
}

/// Per-image profile derived from telemetry history.
///
/// Persisted to JSON so memory gates survive across test runs.
public struct ContainerProfile: Sendable, Codable {
    public let image: String
    public let meanWorkingSetMB: Double
    public let peakWorkingSetMB: Double
    public let p95WorkingSetMB: Double
    public let sampleCount: Int
    public let lastUpdated: Date

    /// Memory gate threshold (peak + 10% safety margin).
    public var memoryGateMB: Double {
        peakWorkingSetMB * 1.10
    }
}

/// Actor for thread-safe telemetry collection.
///
/// Uses `ClientContainer.stats()` via XPC — no shell-outs, no fragile text parsing.
/// Snapshots are captured at lifecycle boundaries (not polled).
public actor ContainerTelemetry {
    public static let shared = ContainerTelemetry()

    // Per-container snapshot storage
    private var snapshots: [String: [TelemetrySnapshot]] = [:]
    private var containerToTest: [String: String] = [:]

    // CSV output
    private var csvPath: String?
    private var csvFileHandle: FileHandle?

    // Profile persistence
    private static let profilesFileName = ".container_telemetry_profiles.json"

    /// Start telemetry collection with optional CSV output.
    public func start(csvPath: String? = nil) {
        if let path = csvPath {
            self.csvPath = path
            setupCSV(path: path)
        }
    }

    /// Stop telemetry collection and close CSV file.
    public func stop() {
        csvFileHandle?.closeFile()
        csvFileHandle = nil
    }

    /// Capture a snapshot for a single container at a specific phase.
    ///
    /// Uses `ClientContainer.get(id:).stats()` via XPC — zero shell overhead.
    public func captureSnapshot(
        containerId: String,
        phase: TelemetryPhase,
        testName: String? = nil
    ) async {
        let container: ClientContainer
        do {
            container = try await ClientContainer.get(id: containerId)
        } catch {
            return // Container may not exist yet — skip silently
        }

        let stats: ContainerStats
        do {
            stats = try await container.stats()
        } catch {
            return // Stats may not be available for stopped containers
        }

        let snapshot = TelemetrySnapshot(
            timestamp: Date(),
            phase: phase,
            containerId: containerId,
            containerName: container.configuration.id,
            imageReference: container.configuration.image.reference,
            testName: testName ?? containerToTest[containerId],
            memoryUsageBytes: stats.memoryUsageBytes ?? 0,
            memoryLimitBytes: stats.memoryLimitBytes
                ?? container.configuration.resources.memoryInBytes,
            cpuUsageUsec: stats.cpuUsageUsec ?? 0,
            networkRxBytes: stats.networkRxBytes ?? 0,
            networkTxBytes: stats.networkTxBytes ?? 0,
            numProcesses: stats.numProcesses ?? 0
        )

        if snapshots[containerId] == nil {
            snapshots[containerId] = []
        }
        snapshots[containerId]?.append(snapshot)

        if let test = testName {
            containerToTest[containerId] = test
        }

        writeToCSV(snapshot)
    }

    /// Capture snapshots for all CCT_ containers at a phase.
    public func capturePhase(
        _ phase: TelemetryPhase,
        testName: String? = nil
    ) async {
        do {
            let containers = try await ClientContainer.list()
            let cctContainers = containers.filter { $0.configuration.id.hasPrefix("CCT_") }

            for container in cctContainers {
                await captureSnapshot(
                    containerId: container.id,
                    phase: phase,
                    testName: testName
                )
            }
        } catch {
            // Silently continue — telemetry should never block tests
        }
    }

    /// Register a container-to-test mapping (useful before containers exist).
    public func registerContainer(_ containerId: String, testName: String) {
        containerToTest[containerId] = testName
    }

    // MARK: - Profiles

    /// Build `ContainerProfile`s from in-memory snapshots, grouped by image.
    public func buildProfiles() -> [ContainerProfile] {
        var imagePeaks: [String: [Double]] = [:]

        for (_, containerSnapshots) in snapshots {
            guard let image = containerSnapshots.first?.imageReference, !image.isEmpty else { continue }

            if imagePeaks[image] == nil {
                imagePeaks[image] = []
            }
            // Use peak memory from this container's lifecycle
            let peak = containerSnapshots.map(\.memoryUsageMB).max() ?? 0
            imagePeaks[image]?.append(peak)
        }

        var profiles: [ContainerProfile] = []
        for (image, peaks) in imagePeaks {
            let sorted = peaks.sorted()
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            let peak = sorted.last ?? 0
            let p95Index = Int(Double(sorted.count) * 0.95)
            let p95 = sorted[min(p95Index, sorted.count - 1)]

            profiles.append(ContainerProfile(
                image: image,
                meanWorkingSetMB: mean,
                peakWorkingSetMB: peak,
                p95WorkingSetMB: p95,
                sampleCount: sorted.count,
                lastUpdated: Date()
            ))
        }

        return profiles.sorted { $0.peakWorkingSetMB > $1.peakWorkingSetMB }
    }

    /// Save profiles to a JSON file in the project root.
    public func saveProfiles() {
        let profiles = buildProfiles()
        guard !profiles.isEmpty else { return }

        let url = URL(fileURLWithPath: Self.profilesFileName)
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: url)
        } catch {
            // Non-critical — telemetry should never block tests
        }
    }

    /// Load previously saved profiles from disk.
    nonisolated public func loadProfiles() -> [ContainerProfile] {
        let url = URL(fileURLWithPath: Self.profilesFileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ContainerProfile].self, from: data)) ?? []
    }

    /// Detect memory regressions: current run vs saved baseline profiles.
    ///
    /// Flags images whose peak memory increased > 30% from the baseline.
    public func detectRegressions() -> [String] {
        let baseline = loadProfiles()
        guard !baseline.isEmpty else { return [] }

        let current = buildProfiles()
        var regressions: [String] = []

        for cur in current {
            guard let base = baseline.first(where: { $0.image == cur.image }) else { continue }
            guard base.peakWorkingSetMB > 0 else { continue }

            let increase = cur.peakWorkingSetMB - base.peakWorkingSetMB
            let pctIncrease = (increase / base.peakWorkingSetMB) * 100

            if pctIncrease > 30 {
                regressions.append(
                    "\(cur.image): +\(String(format: "%.1f", pctIncrease))% "
                    + "(\(String(format: "%.1f", increase))MB, "
                    + "baseline \(String(format: "%.1f", base.peakWorkingSetMB))MB → "
                    + "current \(String(format: "%.1f", cur.peakWorkingSetMB))MB)"
                )
            }
        }

        return regressions
    }

    /// Check if a set of tests can run in parallel given available memory.
    ///
    /// Sums peak memory per test and checks against availableMB with 10% headroom.
    public func canParallelize(testNames: [String], availableMB: Double) -> Bool {
        var totalPeak: Double = 0

        for testName in testNames {
            let testSnapshots = snapshots.filter { containerToTest[$0.key] == testName }
            let testPeak = testSnapshots.values
                .compactMap { $0.map(\.memoryUsageMB).max() }
                .reduce(0, +)
            totalPeak += testPeak
        }

        return totalPeak * 1.10 < availableMB
    }

    /// Get all snapshots for a specific test name.
    public func getSamples(forTest testName: String) -> [TelemetrySnapshot] {
        snapshots.filter { containerToTest[$0.key] == testName }
            .values
            .flatMap { $0 }
    }

    // MARK: - Summary

    /// Print a summary report of collected telemetry.
    public func printSummary() {
        print("")
        print("═══════════════════════════════════════════════════════════")
        print("           CONTAINER TELEMETRY SUMMARY")
        print("═══════════════════════════════════════════════════════════")

        guard !snapshots.isEmpty else {
            print("No telemetry data collected")
            return
        }

        let profiles = buildProfiles()

        print("")
        print(String(format: "%-30s %10s %10s %10s %8s",
                     "IMAGE", "MEAN(MB)", "PEAK(MB)", "GATE(MB)", "SAMPLES"))
        print(String(repeating: "─", count: 80))

        for profile in profiles {
            print(String(format: "%-30s %10.1f %10.1f %10.1f %8d",
                         String(profile.image.prefix(30)),
                         profile.meanWorkingSetMB,
                         profile.peakWorkingSetMB,
                         profile.memoryGateMB,
                         profile.sampleCount))
        }

        print("═══════════════════════════════════════════════════════════")
        print("")
        print("Containers tracked: \(snapshots.count)")
        print("Total snapshots: \(snapshots.values.map(\.count).reduce(0, +))")

        // Show regressions against saved baseline
        let regressions = detectRegressions()
        if !regressions.isEmpty {
            print("")
            print("REGRESSIONS DETECTED (>30% peak memory increase):")
            for r in regressions {
                print("  \(r)")
            }
        }

        if let path = csvPath {
            print("CSV: \(path)")
        }
        let profilesURL = URL(fileURLWithPath: Self.profilesFileName)
        if FileManager.default.fileExists(atPath: profilesURL.path) {
            print("Profiles: \(Self.profilesFileName)")
        }
    }

    // MARK: - Private (CSV)

    private func setupCSV(path: String) {
        let header = "timestamp,phase,container_id,container_name,image,test_name,"
            + "memory_usage_bytes,memory_limit_bytes,cpu_usec,net_rx,net_tx,pids\n"
        FileManager.default.createFile(
            atPath: path,
            contents: header.data(using: .utf8),
            attributes: nil
        )
        csvFileHandle = FileHandle(forWritingAtPath: path)
    }

    private func writeToCSV(_ snapshot: TelemetrySnapshot) {
        guard let handle = csvFileHandle else { return }

        let line = String(
            format: "%.3f,%@,%@,%@,%@,%@,%llu,%llu,%llu,%llu,%llu,%llu\n",
            snapshot.timestamp.timeIntervalSince1970,
            snapshot.phase.rawValue,
            snapshot.containerId,
            snapshot.containerName,
            snapshot.imageReference,
            snapshot.testName ?? "",
            snapshot.memoryUsageBytes,
            snapshot.memoryLimitBytes,
            snapshot.cpuUsageUsec,
            snapshot.networkRxBytes,
            snapshot.networkTxBytes,
            snapshot.numProcesses
        )

        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }
}
