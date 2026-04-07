import Foundation

public enum YAMLValidationError: Error, CustomStringConvertible {
    case malformedRootIndentation(key: String)
    case structureMismatch(original: Set<String>, decoded: Set<String>)
    case emptyDocument

    public var description: String {
        switch self {
        case .malformedRootIndentation(let key):
            return "Top-level key '\(key)' is improperly indented"
        case .structureMismatch(let original, let decoded):
            return "YAML structure changed during decode: original keys \(original) vs decoded \(decoded)"
        case .emptyDocument:
            return "YAML document is empty"
        }
    }
}

public struct YAMLValidator {
    private static let rootKeys = Set(["services:", "version:", "networks:", "volumes:", "configs:", "secrets:"])

    public static func validateRootIndentation(_ yaml: String) throws {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw YAMLValidationError.emptyDocument
        }

        let lines = yaml.components(separatedBy: .newlines)
        for line in lines {
            let lineTrimmed = line.trimmingCharacters(in: .whitespaces)
            for key in rootKeys where lineTrimmed.hasPrefix(key) {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    throw YAMLValidationError.malformedRootIndentation(key: key)
                }
            }
        }
    }
}