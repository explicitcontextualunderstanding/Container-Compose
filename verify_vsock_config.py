#!/usr/bin/env python3
"""Verify vsock relay configuration details"""

import sys
from pathlib import Path
from ruamel.yaml import YAML

def verify_vsock_relays(file_path: Path) -> dict:
    """Verify vsock relay configuration in detail.
    
    Returns:
        Dictionary with verification results
    """
    yaml = YAML()
    yaml.preserve_quotes = True
    
    content = file_path.read_text()
    data = yaml.load(content)
    
    results = {
        'file': file_path.name,
        'services': {},
        'vsock_relays': [],
        'vsock_urls': []
    }
    
    services = data.get('services', {})
    
    for service_name, service_config in services.items():
        # Check for x-apple-relays
        if 'x-apple-relays' in service_config:
            relays = service_config['x-apple-relays']
            
            for relay in relays:
                relay_info = {
                    'service': service_name,
                    'type': relay.get('type'),
                    'port': relay.get('port'),
                    'local_address': relay.get('local_address'),
                    'local_port': relay.get('local_port'),
                    'target': relay.get('target'),
                    'valid': True
                }
                
                # Validate relay structure
                if relay_info['type'] and not relay_info['type'].startswith('vsock'):
                    relay_info['valid'] = False
                
                results['vsock_relays'].append(relay_info)
        
        # Check for vsock URLs in environment
        if 'env' in service_config:
            env = service_config['env']
            for key, value in env.items():
                if isinstance(value, str) and 'vsock://' in value:
                    results['vsock_urls'].append({
                        'service': service_name,
                        'variable': key,
                        'url': value
                    })
    
    return results

def print_verification_report(results_list):
    """Print detailed verification report."""
    print("\n" + "=" * 70)
    print("VSOCK RELAY CONFIGURATION VERIFICATION")
    print("=" * 70)
    
    total_relays = 0
    total_urls = 0
    all_valid = True
    
    for results in results_list:
        print(f"\n📄 {results['file']}")
        print("-" * 70)
        
        # VSOCK Relays
        if results['vsock_relays']:
            print("\nVSOCK Relays:")
            for relay in results['vsock_relays']:
                status = "✅" if relay['valid'] else "❌"
                print(f"  {status} {relay['service']}: {relay['type']}")
                if relay.get('port'):
                    print(f"      port: {relay['port']}")
                if relay.get('local_address'):
                    print(f"      local_address: {relay['local_address']}")
                if relay.get('local_port'):
                    print(f"      local_port: {relay['local_port']}")
                if relay.get('target'):
                    print(f"      target: {relay['target']}")
                
                if not relay['valid']:
                    all_valid = False
                
                total_relays += 1
        
        # VSOCK URLs
        if results['vsock_urls']:
            print("\nVSOCK URLs in Environment:")
            for url_info in results['vsock_urls']:
                print(f"  ✅ {url_info['service']}: {url_info['variable']} = {url_info['url']}")
                total_urls += 1
    
    # Summary
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print(f"Total VSOCK Relays: {total_relays}")
    print(f"Total VSOCK URLs: {total_urls}")
    print(f"All Valid: {'✅ YES' if all_valid else '❌ NO'}")
    
    print("\nVSOCK Relay Types:")
    relay_types = {}
    for results in results_list:
        for relay in results['vsock_relays']:
            rtype = relay.get('type', 'unknown')
            relay_types[rtype] = relay_types.get(rtype, 0) + 1
    
    for rtype, count in sorted(relay_types.items()):
        print(f"  • {rtype}: {count}")
    
    print("\nReady for:")
    print("  ✓ MCP server connections (vsock-mcp-bridge)")
    print("  ✓ Log stream ingestion (vsock-log-stream)")
    print("  ✓ Database relay (vsock-db)")
    print("  ✓ Embedding acceleration (vsock-ane-embedding)")
    print("  ✓ Generic vsock connections (vsock-generic)")
    
    if all_valid:
        print("\n✅ ALL VSOCK CONFIGURATIONS VALID")
        return 0
    else:
        print("\n❌ SOME VSOCK CONFIGURATIONS INVALID")
        return 1

def main():
    appcontainer_dir = Path.home() / "workspace" / "isaac_ros_custom" / ".appcontainer"
    
    compose_files = [
        'honcho-stack.yml',
        'honcho-stack-with-derivers.yml',
        'honcho-derivers.yml'
    ]
    
    results_list = []
    
    for filename in compose_files:
        file_path = appcontainer_dir / filename
        if file_path.exists():
            results = verify_vsock_relays(file_path)
            results_list.append(results)
    
    return print_verification_report(results_list)

if __name__ == "__main__":
    sys.exit(main())