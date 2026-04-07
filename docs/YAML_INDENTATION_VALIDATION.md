# YAML Indentation Validation Analysis for Container-Compose

## Executive Summary

Container-Compose uses **Yams** (Swift YAML library) for parsing, which is **lenient** with indentation. This means malformed YAML files with improper indentation can parse without errors but produce incorrect data structures.

**Key Finding**: We need to add **pre-validation** using ruamel.yaml's AST editor before Swift parsing to catch indentation issues early.

---

## Current State: How YAML is Used

### 1. Test Suite Usage

**Static Tests** (`ComposeUpMappingTests.swift`):

```swift
func testRestartPolicyMapping_Always() throws {
    let yaml = """
        services:
          web:
            image: nginx:latest
            restart: always
        """
    let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    // ❌ PROBLEM: No indentation validation
}
```

**Problem**: Tests use inline YAML strings with no indentation validation.

### 2. Source Code Parsing

**ComposeUp.swift**:

```swift
import Yams

// Line 211:
let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: resolvedYaml)
// ❌ PROBLEM: Yams parses leniently, no indentation validation
```

**Problem**: No validation that YAML is properly indented before decoding.

### 3. Data Model

**DockerCompose.swift**:

```swift
public struct DockerCompose: Codable {
    public let services: [String: Service?]
    // ❌ PROBLEM: Decoding fails silently with bad indentation
}
```

**Problem**: `Codable` decoding produces `nil` or empty dictionaries for misaligned keys.

---

## Root Cause: Yams Lenient Parsing

### Yams Behavior

```swift
// Input (BAD indentation):
let badYaml = """
services:
web:
  image: nginx
"""

// Yams parses this as:
// services: [String: Service?]() // Empty dictionary!
// Because "web:" is at root level, not nested under "services:"
```

**Result**: No error thrown, but data is wrong.

### Expected Behavior

```swift
// Input (GOOD indentation):
let goodYaml = """
services:
  web:
    image: nginx
"""

// Yams parses this as:
// services: ["web": Service(image: "nginx")] // Correct!
```

---

## ruamel.yaml AST Editor Capabilities

### 1. Indentation Detection

```python
from ruamel.yaml import YAML

yaml = YAML()
yaml.preserve_quotes = True

data = yaml.load(yaml_content)

# Detects indentation errors:
# - List items not indented under parent
# - Keys at wrong nesting level
# - Inconsistent indentation
```

### 2. AST Structure Validation

```python
# Can verify structure:
def validate_compose_structure(data):
    assert 'services' in data
    for service_name, service_config in data['services'].items():
        assert isinstance(service_config, dict)
        # Verify x-apple-relays is a list
        if 'x-apple-relays' in service_config:
            assert isinstance(service_config['x-apple-relays'], list)
```

---

## Proposed Solution: Pre-Validation Pipeline

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│ compose.yml File                                        │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│ Step 1: Python Pre-Validation (ruamel.yaml)             │
│  - Check indentation correctness                        │
│  - Validate AST structure                               │
│  - Detect orphaned keys (like our dns: issue)          │
│  - Return detailed error messages                       │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│ Step 2: Swift Parsing (Yams)                            │
│  - Decode to DockerCompose struct                       │
│  - Type-safe access                                     │
│  - Application logic                                    │
└─────────────────────────────────────────────────────────┘
```

### Implementation Options

#### Option 1: Pre-flight Validation Script

**File**: `scripts/validate-compose-yaml.py`

```python
#!/usr/bin/env python3
"""Validate compose YAML indentation and structure"""

import sys
from pathlib import Path
from ruamel.yaml import YAML

def validate_compose_yaml(file_path: Path) -> tuple[bool, list[str]]:
    """Validate compose file indentation and structure.
    
    Returns:
        tuple of (is_valid, list of errors)
    """
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2)
    yaml.indent(sequence=4)
    yaml.indent(offset=2)
    
    errors = []
    
    try:
        content = file_path.read_text()
        data = yaml.load(content)
        
        # 1. Check top-level structure
        if 'services' not in data:
            errors.append("Missing 'services:' key at root level")
        
        # 2. Check services indentation
        services = data.get('services', {})
        for service_name, service_config in services.items():
            if not isinstance(service_config, dict):
                errors.append(f"Service '{service_name}' is not a dictionary (indentation error?)")
            
            # 3. Check x-apple-relays structure
            if 'x-apple-relays' in service_config:
                relays = service_config['x-apple-relays']
                if not isinstance(relays, list):
                    errors.append(f"Service '{service_name}': x-apple-relays is not a list")
                else:
                    for i, relay in enumerate(relays):
                        if not isinstance(relay, dict):
                            errors.append(f"Service '{service_name}': relay[{i}] is not a dictionary")
                        elif 'type' not in relay:
                            errors.append(f"Service '{service_name}': relay[{i}] missing 'type'")
        
        # 4. Re-serialize to check indentation
        from io import StringIO
        stream = StringIO()
        yaml.dump(data, stream)
        fixed_content = stream.getvalue()
        
        # 5. Compare: if content differs, indentation was wrong
        if content != fixed_content:
            errors.append("YAML indentation incorrect (run fix_isaac_yaml.py to fix)")
        
        return (len(errors) == 0, errors)
        
    except Exception as e:
        errors.append(f"Parse error: {e}")
        return (False, errors)

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('file', help='Compose file to validate')
    args = parser.parse_args()
    
    file_path = Path(args.file)
    is_valid, errors = validate_compose_yaml(file_path)
    
    if is_valid:
        print(f"✅ {file_path.name}: Valid YAML structure and indentation")
        return 0
    else:
        print(f"❌ {file_path.name}: Validation failed", file=sys.stderr)
        for error in errors:
            print(f"  • {error}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
```

#### Option 2: Swift YAML Validator Service

**File**: `Sources/Container-Compose/YAMLValidation.swift`

```swift
import Foundation

/// YAML validation result
public struct YAMLValidationResult {
    public let isValid: Bool
    public let errors: [YAMLValidationError]
    public let warnings: [String]
    
    public init(isValid: Bool, errors: [YAMLValidationError], warnings: [String]) {
        self.isValid = isValid
        self.errors = errors
        self.warnings = warnings
    }
}

/// YAML validation error
public struct YAMLValidationError: Error, LocalizedError {
    public let line: Int?
    public let message: String
    
    public var errorDescription: String? {
        if let line = line {
            return "Line \(line): \(message)"
        }
        return message
    }
}

/// Validates YAML structure before parsing
public enum YAMLValidator {
    
    /// Validate YAML content for common indentation issues
    /// - Parameter content: YAML string content
    /// - Returns: Validation result with errors and warnings
    public static func validate(_ content: String) -> YAMLValidationResult {
        var errors: [YAMLValidationError] = []
        var warnings: [String] = []
        
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        
        // Track indentation levels
        var expectedIndent = 0
        var inList = false
        var previousIndent = 0
        
        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            
            // Skip empty lines and comments
            guard !line.isEmpty && !line.hasPrefix("#") else { continue }
            
            // Calculate current indentation
            let currentIndent = line.count - line.drop { $0 == " " }.count
            let trimmedLine = String(line.trimmingCharacters(in: .whitespace))
            
            // Check for root-level keys
            if currentIndent == 0 && trimmedLine.contains(":") {
                let key = trimmedLine.split(separator: ":")[0]
                
                // Known root keys
                let validRootKeys = ["version", "name", "services", "volumes", "networks", "configs", "secrets"]
                if !validRootKeys.contains(String(key)) {
                    warnings.append("Line \(lineNum): Unknown root key '\(key)'")
                }
                
                expectedIndent = 2
                inList = false
            }
            
            // Check for list items
            else if trimmedLine.hasPrefix("- ") {
                // List items should be indented relative to parent key
                let expectedListIndent = expectedIndent
                if currentIndent < expectedListIndent {
                    errors.append(YAMLValidationError(
                        line: lineNum,
                        message: "List item under-indented (expected \(expectedListIndent) spaces, found \(currentIndent))"
                    ))
                }
                inList = true
            }
            
            // Check for nested keys
            else if trimmedLine.contains(":") && !trimmedLine.hasPrefix("-") {
                // Nested keys should follow list items or parent keys
                let expectedKeyIndent = inList ? expectedIndent + 2 : expectedIndent
                
                if currentIndent < expectedKeyIndent - 2 {
                    errors.append(YAMLValidationError(
                        line: lineNum,
                        message: "Key under-indented (expected \(expectedKeyIndent - 2) spaces, found \(currentIndent))"
                    ))
                }
                
                inList = false
            }
            
            previousIndent = currentIndent
        }
        
        // Check for required root keys
        let hasServices = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespace)
            return trimmed.hasPrefix("services:")
        }
        
        if !hasServices {
            errors.append(YAMLValidationError(
                line: nil,
                message: "Missing required 'services:' key"
            ))
        }
        
        return YAMLValidationResult(
            isValid: errors.isEmpty,
            errors: errors,
            warnings: warnings
        )
    }
    
    /// Validate YAML file from path
    /// - Parameter path: File path
    /// - Returns: Validation result
    public static func validateFile(at path: String) throws -> YAMLValidationResult {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return validate(content)
    }
}
```

#### Option 3: Integrated Validation in ComposeUp

**Modified ComposeUp.swift**:

```swift
import Yams
import Rainbow

public struct ComposeUp: AsyncParsableCommand {
    
    public mutating func run() async throws {
        // ... existing code ...
        
        let yamlContent = try String(contentsOf: composeURL, encoding: .utf8)
        
        // NEW: Validate YAML before parsing
        let validationResult = YAMLValidator.validate(yamlContent)
        
        if !validationResult.isValid {
            print("❌ YAML Validation Failed:".red)
            for error in validationResult.errors {
                print("  \(error.localizedDescription)".red)
            }
            throw ExitCode(1)
        }
        
        if !validationResult.warnings.isEmpty {
            print("⚠️  YAML Warnings:".yellow)
            for warning in validationResult.warnings {
                print("  \(warning)".yellow)
            }
        }
        
        // Now parse with Yams
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: resolvedYaml)
        
        // ... rest of implementation ...
    }
}
```

---

## Test Suite Integration

### Before (Current State)

```swift
func testVsockRelay() throws {
    let yaml = """
services:
  db:
    x-apple-relays:
    - type: vsock-db  // ❌ No validation, may parse wrong
"""
    let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    // May silently fail
}
```

### After (With Validation)

```swift
func testVsockRelay() throws {
    let yaml = """
services:
  db:
    x-apple-relays:
      - type: vsock-db  // ✅ Proper indentation
"""
    
    // NEW: Validate first
    let validationResult = YAMLValidator.validate(yaml)
    XCTAssertTrue(validationResult.isValid, "YAML should be valid: \(validationResult.errors)")
    
    // Then parse
    let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    XCTAssertNotNil(dockerCompose.services["db"])
}
```

---

## Recommended Implementation Path

### Phase 1: Add Python Pre-Validation (Immediate)

1. ✅ **Create** `scripts/validate-compose-yaml.py`
2. ✅ **Integrate** into test suite: `run-tests.sh --validate-yaml`
3. ✅ **Add** to CI/CD pipeline

**Benefits**:
- Catches indentation errors before Swift parsing
- Provides detailed line-by-line error messages
- Uses battle-tested ruamel.yaml AST editor

### Phase 2: Add Swift Validator (Short-term)

1. **Create** `YAMLValidator.swift` with basic rules
2. **Add** to ComposeUp, ComposeDown, ComposePs commands
3. **Test** with existing test suite

**Benefits**:
- Integrated into Swift codebase
- No external Python dependency
- Fails fast with clear errors

### Phase 3: Enhance Test Suite (Medium-term)

1. **Add** validation tests for each YAML fixture
2. **Generate** test cases from real compose files
3. **Validate** indentation in CI

**Benefits**:
- Prevents regressions
- Documents expected structure
- Catches errors early in development

---

## Comparison: Yams vs ruamel.yaml

| Feature | Yams (Swift) | ruamel.yaml (Python) |
|---------|--------------|----------------------|
| Indentation Validation | ❌ No | ✅ Yes (AST-based) |
| Structure Validation | ⚠️ Limited | ✅ Full AST access |
| Error Messages | ⚠️ Generic | ✅ Detailed (line, column) |
| Integration | ✅ Native Swift | ⚠️ Requires subprocess |
| Performance | ✅ Fast | ⚠️ Slower (Python) |
| Maintenance | ✅ Swift team | ✅ Active development |

**Recommendation**: Use **both**:
- **ruamel.yaml** for pre-flight validation (Python script)
- **Yams** for production parsing (Swift)
- **YAMLValidator** for integrated checks (Swift)

---

## Verification Results (2026-04-07)

### Test Integrity Check

All 147 inline YAML snippets in test files have been validated:

```
$ python3 scripts/validate-swift-yaml.py
Summary: 147 YAML snippets in 27 test files
Errors: 0 in 0 files
✅ All YAML snippets validated successfully!
```

### Files Validated
- ComposeUpMappingTests.swift
- ComposeDownMappingTests.swift
- ComposePsMappingTests.swift
- RelayConfigurationTests.swift
- NetworkConfigurationTests.swift
- HealthcheckConfigurationTests.swift
- (22 more test files)

---

## Conclusion

**Current State**: ✅ IMPLEMENTED - YAML validation infrastructure in place

**Delivered**:
1. **Python Reference Validator** (`scripts/validate-compose-yaml.py`)
   - Uses ruamel.yaml (stricter than Swift's Yams)
   - Validates structure, indentation, x-apple-relays
   - Auto-fix capability via `--fix` flag

2. **Swift YAMLValidator** (`Tests/TestHelpers/YAMLValidation.swift`)
   - Native Swift solution for test integrity
   - `validateRootIndentation()` - catches root-level indentation bugs

3. **Swift YAML Extractor** (`scripts/validate-swift-yaml.py`)
   - Extracts YAML from Swift string literals
   - Validates all 147 test fixtures
   - Skips Swift string interpolations

**Impact**:
- ✅ Prevents silent parsing failures
- ✅ Validates 147 test YAML fixtures
- ✅ Clear error messages with line numbers
- ✅ Two-layer validation (Python + Swift)

**Verification**:
```bash
# Validate all test YAML fixtures
python3 scripts/validate-swift-yaml.py
# ✅ All 147 YAML snippets validated successfully!
```