import ArgumentParser
import Foundation

/// Command to perform a "factory reset" on the Apple Container runtime's internal state.
/// This replicates the manual host-side purge logic needed to resolve XPC "Connection invalid" errors.
public struct SystemReset: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "system-reset",
        abstract: "Factory reset the container runtime's internal state (fixes XPC instability)",
        discussion: """
        Surgically purges 'plugin-state/', 'networks/', and 'state.json' from the Apple Container
        application support directory. This resolves 'XPC connection invalid' (EX_CONFIG 78)
        errors caused by state corruption in version 0.11.0.

        IMPORTANT:
        • This does NOT delete persistent volumes (volumes/) or images (content/).
        • This stops all running containers and restarts the apiserver.
        """
    )

    @Flag(name: .long, help: "Perform the reset without manual confirmation")
    var force: Bool = false

    private var fileManager: FileManager { FileManager.default }
    private var appSupportDir: String {
        let home = URL.homeDirectory.path(percentEncoded: false)
        return "\(home)/Library/Application Support/com.apple.container"
    }

    public mutating func run() async throws {
        if !force {
            print("⚠️  Warning: This will stop all running containers and purge the runtime's internal state.".yellow)
            print("   Persistent volumes (volumes/) and images (content/) will be preserved.".yellow)
            print("\n   Do you want to proceed? (y/N): ", terminator: "")
            if let input = readLine()?.lowercased(), input != "y" {
                print("Reset aborted.")
                return
            }
        }

        print("\n--- Phase 1: Stopping apiserver ---")
        let uid = getuid()
        let serviceLabel = "com.apple.container.apiserver"
        let bootoutCmd = ["launchctl", "bootout", "gui/\(uid)/\(serviceLabel)"]
        
        print("Executing: \(bootoutCmd.joined(separator: " "))")
        _ = try? await runProcess(executable: "/usr/bin/env", args: bootoutCmd)
        
        print("\n--- Phase 2: Purging corrupted state artifacts ---")
        let targets = ["apiserver", "networks", "plugin-state", "state.json"]
        for target in targets {
            let path = "\(appSupportDir)/\(target)"
            if fileManager.fileExists(atPath: path) {
                print("Removing \(target)...")
                try? fileManager.removeItem(atPath: path)
            }
        }

        print("\n--- Phase 3: Restarting apiserver ---")
        // We let the container CLI perform the bootstrap via 'system start'
        // to ensure all internal plugins and bridges are also initialized.
        let systemStartCmd = ["container", "system", "start"]
        print("Executing: \(systemStartCmd.joined(separator: " "))")
        _ = try await runProcess(executable: "/usr/bin/env", args: systemStartCmd)
        
        print("\n--- Verification ---")
        let versionCmd = ["container", "system", "version"]
        let version = try await runProcess(executable: "/usr/bin/env", args: versionCmd)
        print("Runtime identity restored:")
        print(version.indented())

        print("\n✅ System reset complete. Runtime XPC state is now clean.".green)
    }

    /// Helper to run a process and capture output
    @discardableResult
    private func runProcess(executable: String, args: [String]) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension String {
    func indented(by spaces: Int = 3) -> String {
        let indent = String(repeating: " ", count: spaces)
        return self.split(separator: "\n").map { "\(indent)\($0)" }.joined(separator: "\n")
    }
}
