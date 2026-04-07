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
        let lines = yaml.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for key in rootKeys where trimmed.hasPrefix(key) {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    throw YAMLValidationError.malformedRootIndentation(key: key)
                }
            }
        }
    }

    public static func roundTripIntegrity<T: Codable>(yaml: String, as type: T.Type) throws {
        let decoder = YAMLDecoder()
        let encoder = YAMLEncoder()

        let decoded = try decoder.decode(type, from: yaml)
        let reEncoded = try encoder.encode(decoded)

        let originalKeys = Set(getTopLevelKeys(from: yaml))
        let newKeys = Set(getTopLevelKeys(from: reEncoded))

        if originalKeys != newKeys {
            throw YAMLValidationError.structureMismatch(original: originalKeys, decoded: newKeys)
        }
    }

    private static func getTopLevelKeys(from yaml: String) -> [String] {
        let lines = yaml.components(separatedBy: .newlines)
        var keys: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if rootKeys.contains(where: { trimmed.hasPrefix($0.dropLast()) }) {
                let key = String(trimmed.prefix(while: { $0 != ":" }))
                if !key.isEmpty { keys.append(key) }
            }
        }
        return keys
    }
}