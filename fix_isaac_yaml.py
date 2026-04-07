#!/usr/bin/env python3
"""Fix YAML indentation in isaac_ros_custom compose files using ruamel.yaml AST editor"""

import sys
import re
from pathlib import Path
from ruamel.yaml import YAML
from ruamel.yaml.main import round_trip_dump
from io import StringIO

def fix_yaml_indentation(file_path: Path) -> tuple[bool, list[str]]:
    """Fix YAML indentation in a compose file.
    
    Returns:
        tuple of (success, list of changes made)
    """
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2)
    yaml.indent(sequence=4)
    yaml.indent(offset=2)
    
    try:
        # Read the file
        content = file_path.read_text()
        data = yaml.load(content)
        
        # Dump it back with correct indentation
        stream = StringIO()
        yaml.dump(data, stream)
        fixed_content = stream.getvalue()
        
        # Check if there were changes
        if content == fixed_content:
            return (False, [])
        
        # Count changes
        changes = []
        original_lines = content.split('\n')
        fixed_lines = fixed_content.split('\n')
        
        for i, (orig, fixed) in enumerate(zip(original_lines, fixed_lines)):
            if orig != fixed:
                changes.append(f"Line {i+1}: '{orig}' -> '{fixed}'")
        
        # Write back
        file_path.write_text(fixed_content)
        return (True, changes)
        
    except Exception as e:
        print(f"Error processing {file_path}: {e}", file=sys.stderr)
        return (False, [f"Error: {e}"])

def fix_dns_indentation(content: str) -> str:
    """Fix DNS list indentation specifically.
    
    The diff showed dns entries moving from:
      dns:
        - 8.8.8.8
    to:
      dns:
      - 8.8.8.8
    
    This function reverts those changes.
    """
    lines = content.split('\n')
    fixed_lines = []
    i = 0
    
    while i < len(lines):
        line = lines[i]
        
        # Check for dns: followed by incorrectly indented list item
        if line.strip() == 'dns:':
            fixed_lines.append(line)
            # Check next line
            if i + 1 < len(lines):
                next_line = lines[i + 1]
                # If next line starts with '- ' (list item) without proper indentation
                if next_line.strip().startswith('- ') and not next_line.startswith('      -'):
                    # Get the indentation of the dns: line
                    dns_indent = len(line) - len(line.lstrip())
                    # List items should be indented 2 more spaces
                    proper_indent = ' ' * (dns_indent + 2)
                    list_item = next_line.strip()
                    fixed_lines.append(f"{proper_indent}{list_item}")
                    i += 2
                    continue
        
        # Fix other list items under keys (volumes, x-apple-relays, command, etc.)
        if ':' in line and not line.strip().startswith('#') and not line.strip().startswith('-'):
            key_part = line.split(':')[0].strip()
            if key_part in ['volumes', 'x-apple-relays', 'command', 'dns', 'env', 'healthcheck', 'test']:
                fixed_lines.append(line)
                # Check next lines for list items
                i += 1
                key_indent = len(line) - len(line.lstrip())
                
                while i < len(lines):
                    next_line = lines[i]
                    # If it's a list item but not properly indented
                    if next_line.strip().startswith('- '):
                        proper_indent = ' ' * (key_indent + 2)
                        # Check if it's already properly indented
                        if next_line.startswith(' ' * (key_indent + 2)):
                            # Already correct
                            fixed_lines.append(next_line)
                        elif next_line.startswith(' ' * key_indent) and next_line[key_indent] in ' -':
                            # Needs fixing - list item at wrong level
                            list_item = next_line.strip()
                            fixed_lines.append(f"{proper_indent}{list_item}")
                        else:
                            fixed_lines.append(next_line)
                        i += 1
                    elif next_line.strip() == '':
                        fixed_lines.append(next_line)
                        i += 1
                    elif len(next_line) - len(next_line.lstrip()) <= key_indent:
                        # Back to parent level, done with this key
                        break
                    else:
                        # Continuation of the same key
                        fixed_lines.append(next_line)
                        i += 1
                continue
        
        fixed_lines.append(line)
        i += 1
    
    return '\n'.join(fixed_lines)

def fix_all_compose_files(directory: Path) -> None:
    """Fix all compose files in directory."""
    compose_files = list(directory.glob('*.yml')) + list(directory.glob('*.yaml'))
    
    total_fixed = 0
    for compose_file in compose_files:
        # Skip backup files
        if '.bak' in str(compose_file):
            print(f"Skipping backup file: {compose_file.name}")
            continue
        
        print(f"\nProcessing: {compose_file.name}")
        
        # First apply ruamel.yaml formatting
        success, changes = fix_yaml_indentation(compose_file)
        
        if success:
            print(f"  ✅ Fixed {len(changes)} indentation issues")
            total_fixed += 1
            for change in changes[:5]:  # Show first 5 changes
                print(f"    {change}")
            if len(changes) > 5:
                print(f"    ... and {len(changes) - 5} more")
        else:
            print(f"  ℹ️  No changes needed")

def main():
    appcontainer_dir = Path.home() / "workspace" / "isaac_ros_custom" / ".appcontainer"
    
    if not appcontainer_dir.exists():
        print(f"Error: Directory not found: {appcontainer_dir}", file=sys.stderr)
        sys.exit(1)
    
    print("Fixing YAML indentation in isaac_ros_custom compose files")
    print("=" * 60)
    
    fix_all_compose_files(appcontainer_dir)
    
    print("\n" + "=" * 60)
    print("Done! All compose files processed.")

if __name__ == "__main__":
    main()