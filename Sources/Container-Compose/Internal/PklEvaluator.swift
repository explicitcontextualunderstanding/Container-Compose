import Foundation

/// PklEvaluator handles the evaluation of Pkl-based orchestration schemas.
/// It injects host telemetry (CPU/Memory) into the evaluation environment to enforce hardware constraints.
public enum PklEvaluator {
    /// Errors thrown by the PklEvaluator
    public enum Error: Swift.Error, CustomStringConvertible {
        case pklNotFound(path: String)
        case evaluationFailed(message: String)
        case decodingFailed(underlying: Swift.Error)
        case schemaNotFound(path: String)

        public var description: String {
            switch self {
            case .pklNotFound(let path): return "Pkl binary not found at \(path)"
            case .evaluationFailed(let msg): return "Pkl evaluation failed: \(msg)"
            case .decodingFailed(let err): return "Failed to decode Pkl output: \(err)"
            case .schemaNotFound(let path): return "Pkl schema not found at \(path)"
            }
        }
    }

    /// Evaluates a Pkl file and decodes it into a DockerCompose struct.
    /// - Parameter pklFile: The URL of the .pkl file to evaluate.
    /// - Returns: A decoded DockerCompose struct.
    public static func evaluate(pklFile: URL) throws -> DockerCompose {
        let pklBinary = detectPklBinary()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: pklBinary)
        process.arguments = ["eval", "--format", "json", pklFile.path]
        
        // Inject host telemetry
        var pklEnv = ProcessInfo.processInfo.environment
        pklEnv["HOST_MAX_CPU"] = String(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        pklEnv["HOST_MAX_MEMORY"] = String(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        process.environment = pklEnv

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw Error.evaluationFailed(message: error.localizedDescription)
        }

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrString = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
            throw Error.evaluationFailed(message: stderrString)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        do {
            return try JSONDecoder().decode(DockerCompose.self, from: stdoutData)
        } catch {
            throw Error.decodingFailed(underlying: error)
        }
    }

    /// Resolves the Pkl binary path using standard locations and PKL_EXEC override.
    private static func detectPklBinary() -> String {
        if let env = ProcessInfo.processInfo.environment["PKL_EXEC"],
           FileManager.default.fileExists(atPath: env) { return env }
        for candidate in ["/opt/homebrew/bin/pkl", "/usr/local/bin/pkl"] {
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        fatalError("pkl binary not found. Set PKL_EXEC or install via brew install pkl")
    }
}
