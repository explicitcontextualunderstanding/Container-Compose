#!/usr/bin/env python3
"""Extract and validate YAML from Swift test files"""

import re
import sys
from pathlib import Path

YAML_PATTERN = r'let\s+yaml\s*=\s*"""([\s\S]*?)"""'

def extract_yaml_from_swift(file_path: Path) -> list[tuple[int, str]]:
    """Extract YAML strings from Swift file, returns list of (line_number, yaml_content)"""
    content = file_path.read_text()
    matches = re.finditer(YAML_PATTERN, content)
    results = []
    for match in matches:
        yaml_content = match.group(1)
        line_num = content[:match.start()].count('\n') + 1
        results.append((line_num, yaml_content))
    return results

def validate_yaml(yaml: str) -> list[str]:
    """Validate YAML and return list of errors"""
    from ruamel.yaml import YAML
    yaml_parser = YAML()
    yaml_parser.preserve_quotes = True
    
    errors = []
    
    # Skip Swift string interpolations - these are test fixtures, not real YAML
    if '\\(' in yaml or '$(' in yaml:
        return []  # Skip validation for Swift interpolations
    
    try:
        data = yaml_parser.load(yaml)
        if data is None:
            errors.append("Empty document")
            return errors
    except Exception as e:
        errors.append(f"Parse error: {e}")
        return errors
    
    # Check structure
    if not isinstance(data, dict):
        errors.append("Root must be a mapping")
        return errors
    
    return errors

def main():
    test_dir = Path("Tests")
    yaml_files = list(test_dir.rglob("*Tests*.swift"))
    
    total_yamls = 0
    total_errors = 0
    files_with_errors = []
    
    for swift_file in yaml_files:
        yaml_snippets = extract_yaml_from_swift(swift_file)
        if not yaml_snippets:
            continue
            
        file_errors = 0
        for line_num, yaml in yaml_snippets:
            total_yamls += 1
            errors = validate_yaml(yaml)
            if errors:
                file_errors += 1
                total_errors += len(errors)
                print(f"❌ {swift_file.name}:{line_num}")
                for err in errors:
                    print(f"   - {err}")
        
        if file_errors > 0:
            files_with_errors.append((swift_file.name, file_errors))
    
    print(f"\n{'='*50}")
    print(f"Summary: {total_yamls} YAML snippets in {len(yaml_files)} test files")
    print(f"Errors: {total_errors} in {len(files_with_errors)} files")
    
    if files_with_errors:
        print(f"\nFiles with errors:")
        for name, count in files_with_errors:
            print(f"  - {name}: {count} error(s)")
    else:
        print("✅ All YAML snippets validated successfully!")

if __name__ == "__main__":
    main()