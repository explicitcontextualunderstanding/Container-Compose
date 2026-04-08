#!/usr/bin/env python3
"""Validate compose YAML indentation and structure using ruamel.yaml AST editor"""

import sys
import re
from pathlib import Path
from ruamel.yaml import YAML
from io import StringIO


def check_hardcoded_ips(content: str, file_path: Path, allow_patterns: list[str] | None = None) -> list[str]:
    """Check for hardcoded IP addresses in YAML content (Plan 82 Phase 3).
    
    Categorizes IPs by severity:
    - BLOCK: Container-internal service communication (must use localhost)
    - WARN: Host-side bridge configuration (intentional external connectivity)
    
    Container-internal (BLOCK):
    - DATABASE_URL, DB_CONNECTION_URI (should use localhost:5432)
    - Service-to-service communication
    
    Host-side (WARN - intentional):
    - HOST_LAN_IP environment variable
    - OP_CONNECT_HOST (1Password Connect)
    - K3s API ports (6444, 6445)
    - Port 31307 (1Password Connect)
    
    Args:
        content: YAML file content as string
        file_path: Path for error reporting
        
    Returns:
        List of error messages for hardcoded IPs found (categorized by severity)
    """
    errors = []
    lines = content.split('\n')
    
    # IP patterns to detect
    ip_patterns = [
        # 192.168.x.x (private network)
        (r'192\.168\.\d+\.\d+', '192.168.x.x (private network)'),
        # 10.x.x.x (private network)
        (r'10\.\d+\.\d+\.\d+', '10.x.x.x (private network)'),
        # 172.16-31.x.x (private network)
        (r'172\.(1[6-9]|2\d|3[01])\.\d+\.\d+', '172.16-31.x.x (private network)'),
    ]
    
    # Context patterns that indicate host-side (intentional) usage
    host_side_patterns = [
        r'HOST_LAN_IP',
        r'OP_CONNECT_HOST',
        r':6444',  # K3s API nano1
        r':6445',  # K3s API nano2
        r':31307', # 1Password Connect
        r'kubeconfig',
        r'kubectl',
    ]
    
    # Context patterns that indicate container-internal (should be localhost)
    container_internal_patterns = [
        r'DATABASE_URL',
        r'DB_CONNECTION_URI',
        r'POSTGRES',
        r':5432',  # PostgreSQL
        r':8000',  # Honcho Hub (if not using vsock)
    ]
    
    for line_num, line in enumerate(lines, start=1):
        # Skip comment lines
        stripped = line.strip()
        if stripped.startswith('#'):
            continue
            
        for pattern, ip_desc in ip_patterns:
            matches = re.finditer(pattern, line)
            for match in matches:
                # Check if it's actually localhost (127.0.0.1 is OK)
                ip = match.group()
                if ip == '127.0.0.1' or ip.startswith('127.'):
                    continue
                
                # Get wider context for classification
                context_start = max(0, match.start() - 50)
                context_end = min(len(line), match.end() + 50)
                context = line[context_start:context_end]
                
                # Classify based on context
                is_host_side = any(re.search(p, context, re.IGNORECASE) for p in host_side_patterns)
                is_container_internal = any(re.search(p, context, re.IGNORECASE) for p in container_internal_patterns)
                
                if is_container_internal:
                    # BLOCK: Container-internal should use localhost
                    errors.append(
                        f"[BLOCK] Line {line_num}: Container-internal {ip_desc} IP '{ip}' "
                        f"should use localhost (Plan 82). Context: ...{context!r}..."
                    )
                elif is_host_side:
                    # WARN: Host-side is intentional but should be reviewed
                    errors.append(
                        f"[WARN] Line {line_num}: Host-side {ip_desc} IP '{ip}' "
                        f"(intentional: K3s/1P bridge). Context: ...{context!r}..."
                    )
                else:
                    # Unknown context - flag for review
                    errors.append(
                        f"[REVIEW] Line {line_num}: Hardcoded {ip_desc} IP '{ip}' "
                        f"(context unclear). Context: ...{context!r}..."
                    )
    
    return errors


def validate_compose_yaml(file_path: Path, fix: bool = False, check_hardcoded_ips_flag: bool = False) -> tuple[bool, list[str], str]:
    """Validate compose file indentation and structure.
    
    Args:
        file_path: Path to compose YAML file
        fix: If True, write fixed content back to file
        check_hardcoded_ips_flag: If True, check for hardcoded IPs (Plan 82 Phase 3)
        
    Returns:
        tuple of (is_valid, list of errors, fixed content)
    """
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2)
    yaml.indent(sequence=4)
    yaml.indent(offset=2)
    
    errors = []
    content = ""  # Initialize content for error handling
    
    try:
        content = file_path.read_text()
        
        # Plan 82 Phase 3: Check for hardcoded IPs first
        if check_hardcoded_ips_flag:
            ip_errors = check_hardcoded_ips(content, file_path)
            errors.extend(ip_errors)
        
        # 1. Parse YAML
        data = yaml.load(content)
        
        # 2. Check top-level structure
        if 'services' not in data:
            errors.append("Missing 'services:' key at root level")
            return (False, errors, content)
        
        # 3. Check services structure
        services = data.get('services', {})
        if not isinstance(services, dict):
            errors.append("'services:' value is not a dictionary (indentation error?)")
            return (False, errors, content)
        
        # 4. Validate each service
        for service_name, service_config in services.items():
            if service_config is None:
                errors.append(f"Service '{service_name}' is null (indentation error?)")
                continue
            
            if not isinstance(service_config, dict):
                errors.append(f"Service '{service_name}' is not a dictionary (indentation error?)")
                continue
            
            # 5. Check x-apple-relays structure
            if 'x-apple-relays' in service_config:
                relays = service_config['x-apple-relays']
                
                if not isinstance(relays, list):
                    errors.append(f"Service '{service_name}': x-apple-relays is not a list (indentation error?)")
                else:
                    for i, relay in enumerate(relays):
                        if not isinstance(relay, dict):
                            errors.append(f"Service '{service_name}': relay[{i}] is not a dictionary")
                        elif 'type' not in relay:
                            errors.append(f"Service '{service_name}': relay[{i}] missing 'type' field")
                        else:
                            # Validate relay type
                            relay_type = relay.get('type')
                            valid_types = [
                                'vsock-db', 'vsock-mcp-bridge',
                                'vsock-log-stream', 'vsock-ane-embedding',
                                'vsock-generic'
                            ]
                            if relay_type not in valid_types:
                                errors.append(
                                    f"Service '{service_name}': relay[{i}] "
                                    f"has invalid type '{relay_type}'"
                                )
            
            # 6. Check other list fields
            for field in ['dns', 'volumes', 'command', 'entrypoint']:
                if field in service_config:
                    value = service_config[field]
                    if not isinstance(value, list):
                        errors.append(
                            f"Service '{service_name}': '{field}' should be a list "
                            f"(indentation error?)"
                        )
        
        # Initialize indent_errors counter
        indent_errors = 0
        
        # 7. Re-serialize to check indentation
        stream = StringIO()
        yaml.dump(data, stream)
        fixed_content = stream.getvalue()
        
        # 8. Compare: if content differs, indentation was wrong
        if content != fixed_content:
            # Find specific differences
            original_lines = content.split('\n')
            fixed_lines = fixed_content.split('\n')
            
            # Count indentation errors
            for i, (orig, fixed) in enumerate(zip(original_lines, fixed_lines)):
                if orig != fixed:
                    orig_stripped = orig.lstrip()
                    fixed_stripped = fixed.lstrip()
                    
                    # If content is same but indentation differs
                    if orig_stripped == fixed_stripped:
                        indent_errors += 1
            
            if indent_errors > 0:
                errors.append(
                    f"YAML has {indent_errors} indentation error(s) "
                    f"(run with --fix to auto-correct)"
                )
        
        if fix:
            file_path.write_text(fixed_content)
        
        # Determine validity based on whether any errors exist (including IP errors)
        is_valid = len(errors) == 0
        return (is_valid, errors, fixed_content if fix else content)
        
    except Exception as e:
        errors.append(f"Parse error: {e}")
        return (False, errors, content)


def print_validation_report(file_path: Path, is_valid: bool, errors: list[str]):
    """Print formatted validation report."""
    if is_valid:
        print(f"✅ {file_path.name}: Valid YAML structure and indentation")
    else:
        print(f"❌ {file_path.name}: Validation failed")
        for error in errors:
            print(f" • {error}")


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description="Validate compose YAML files for correct indentation and structure"
    )
    parser.add_argument(
        'files',
        nargs='+',
        help='Compose files to validate'
    )
    parser.add_argument(
        '--fix',
        action='store_true',
        help='Fix indentation errors automatically'
    )
    parser.add_argument(
        '--quiet',
        action='store_true',
        help='Only print errors'
    )
    parser.add_argument(
        '--check-hardcoded-ips',
        action='store_true',
        help='Check for hardcoded IP addresses (Plan 82 Phase 3)'
    )
    
    args = parser.parse_args()
    
    all_valid = True
    
    for file_path_str in args.files:
        file_path = Path(file_path_str)
        
        if not file_path.exists():
            print(f"❌ File not found: {file_path}", file=sys.stderr)
            all_valid = False
            continue
        
        is_valid, errors, _ = validate_compose_yaml(
            file_path,
            fix=args.fix,
            check_hardcoded_ips_flag=args.check_hardcoded_ips
        )
        
        if not args.quiet or not is_valid:
            print_validation_report(file_path, is_valid, errors)
        
        if not is_valid:
            all_valid = False
    
    if all_valid:
        if not args.quiet:
            print("\n✅ All files valid")
        return 0
    else:
        if not args.quiet:
            print("\n❌ Some files have errors")
        return 1


if __name__ == "__main__":
    sys.exit(main())
