import ArgumentParser
import Foundation
import ContainerizationExtras
import ContainerAPIClient

/// Error thrown when checkpoint operations fail.
public struct CheckpointError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(_ message: String) {
        self.message = message
    }
}

public struct CheckpointCommand: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(commandName: "checkpoint", abstract: "Commit/export a running service container to an image")

    @Argument(help: "Service name to checkpoint")
    var service: String

    @Option(name: .long, help: "Image tag to use for the checkpointed image")
    var tag: String?

    @Flag(name: .long, help: "Skip validation that container is running (may create stale checkpoint)")
    var force: Bool = false

    public mutating func run() async throws {
        let project = try deriveProjectName(cwd: FileManager.default.currentDirectoryPath)
        let containerName = "\(project)-\(service)"
        let imageTag: String
        if let t = tag {
            imageTag = t
        } else {
            let ts = Int(Date().timeIntervalSince1970)
            imageTag = "\(project)-\(service):checkpoint-\(ts)"
        }

        // Pre-flight check: verify container exists
        let containers = try await ClientContainer.list()
        guard let container = containers.first(where: { $0.configuration.id == containerName }) else {
            throw CheckpointError("Container '\(containerName)' not found. Is the service running?")
        }

        // Pre-flight check: verify container is running (unless --force)
        if !force && container.status != .running {
            throw CheckpointError("Container '\(containerName)' is not running (status: \(container.status)). Use --force to checkpoint anyway, but the image may be stale.")
        }

        let args = Self.makeCommitArgs(containerName: containerName, imageName: imageTag)

        print("Executing: container \(args.joined(separator: " "))")
        let exitCode = try await streamCommand("container", args: args, cwd: FileManager.default.currentDirectoryPath, onStdout: { print($0) }, onStderr: { print($0) })

        // Verify commit succeeded
        guard exitCode == 0 else {
            throw CheckpointError("Checkpoint failed with exit code \(exitCode). Check output above for details.")
        }

        print("Checkpointed \(containerName) -> \(imageTag)")
    }

    // Builds the CLI args to pass to `container` for committing/exporting a container to an image.
    public static func makeCommitArgs(containerName: String, imageName: String) -> [String] {
        // Upstream container supports `commit` or `export` depending on version; prefer 'commit' if available.
        // Construct: ["commit", "<container>", "--output", "<image>"] or ["export", "<container>", "--tag", "<image>"]
        // For broad compatibility, use `commit` followed by container and image tag as arguments.
        return ["commit", containerName, imageName]
    }
}
