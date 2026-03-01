import ArgumentParser
import Foundation
import ContainerizationExtras
import ContainerAPIClient

public struct CheckpointCommand: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(commandName: "checkpoint", abstract: "Commit/export a running service container to an image")

    @Argument(help: "Service name to checkpoint")
    var service: String

    @Option(name: .long, help: "Image tag to use for the checkpointed image")
    var tag: String?

    public mutating func run() async throws {
        let project = deriveProjectName(cwd: FileManager.default.currentDirectoryPath)
        let containerName = "\(project)-\(service)"
        let imageTag: String
        if let t = tag {
            imageTag = t
        } else {
            let ts = Int(Date().timeIntervalSince1970)
            imageTag = "\(project)-\(service):checkpoint-\(ts)"
        }

        let args = Self.makeCommitArgs(containerName: containerName, imageName: imageTag)

        print("Executing: container \(args.joined(separator: " "))")
        _ = try await streamCommand("container", args: args, cwd: FileManager.default.currentDirectoryPath, onStdout: { print($0) }, onStderr: { print($0) })
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
