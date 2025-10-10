#!/usr/bin/env python3

"""
ZigCat Docker Test System - YAML Configuration Parser
Provides YAML parsing functionality as a fallback when yq is not available.
Uses a simple YAML parser that doesn't require external dependencies.
"""

import sys
import json
import argparse
import re
from pathlib import Path

def simple_yaml_load(file_path):
    """Simple YAML parser for basic configuration files."""
    config = {}
    current_section = None
    current_subsection = None
    indent_stack = []
    
    with open(file_path, 'r') as f:
        lines = f.readlines()
    
    for line_num, line in enumerate(lines, 1):
        line = line.rstrip('\n\r')
        
        # Skip empty lines and comments
        if not line.strip() or line.strip().startswith('#'):
            continue
        
        # Calculate indentation
        indent = len(line) - len(line.lstrip())
        content = line.strip()
        
        # Handle list items
        if content.startswith('- '):
            list_item = content[2:].strip()
            
            # Handle list of strings
            if ':' not in list_item:
                if current_subsection and isinstance(config[current_section][current_subsection], list):
                    config[current_section][current_subsection].append(list_item)
                elif current_section and isinstance(config[current_section], list):
                    config[current_section].append(list_item)
                continue
            
            # Handle list of objects
            if current_section and current_section not in config:
                config[current_section] = []
            
            # Parse key-value in list item
            if ':' in list_item:
                key, value = list_item.split(':', 1)
                key = key.strip()
                value = value.strip()
                
                # Start new list item object
                list_obj = {key: parse_value(value)}
                config[current_section].append(list_obj)
                current_list_obj = list_obj
            continue
        
        # Handle key-value pairs
        if ':' in content:
            key, value = content.split(':', 1)
            key = key.strip()
            value = value.strip()
            
            # Determine nesting level
            if indent == 0:
                # Top level
                current_section = key
                current_subsection = None
                if value:
                    config[key] = parse_value(value)
                else:
                    config[key] = {}
            elif indent == 2:
                # Second level
                if current_section:
                    if current_section not in config:
                        config[current_section] = {}
                    current_subsection = key
                    if value:
                        config[current_section][key] = parse_value(value)
                    else:
                        config[current_section][key] = {}
            elif indent == 4:
                # Third level
                if current_section and current_subsection:
                    if current_subsection not in config[current_section]:
                        config[current_section][current_subsection] = {}
                    config[current_section][current_subsection][key] = parse_value(value)
                elif current_section and isinstance(config[current_section], list) and config[current_section]:
                    # Add to last list item
                    config[current_section][-1][key] = parse_value(value)
            elif indent == 6:
                # Fourth level (for nested mappings in list items)
                if (current_section and isinstance(config[current_section], list) and 
                    config[current_section] and isinstance(config[current_section][-1], dict)):
                    # Find the parent key in the last list item
                    last_item = config[current_section][-1]
                    for parent_key in reversed(list(last_item.keys())):
                        if isinstance(last_item[parent_key], dict):
                            last_item[parent_key][key] = parse_value(value)
                            break
    
    return config

def parse_value(value):
    """Parse a YAML value to appropriate Python type."""
    if not value:
        return None
    
    # Boolean values
    if value.lower() in ('true', 'yes', 'on'):
        return True
    if value.lower() in ('false', 'no', 'off'):
        return False
    
    # Null values
    if value.lower() in ('null', 'none', '~'):
        return None
    
    # Numeric values
    if value.isdigit():
        return int(value)
    
    try:
        return float(value)
    except ValueError:
        pass
    
    # String values (remove quotes if present)
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    
    return value

def load_config(config_file):
    """Load and parse YAML configuration file."""
    try:
        return simple_yaml_load(config_file)
    except FileNotFoundError:
        print(f"Error: Configuration file not found: {config_file}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: Failed to parse YAML: {e}", file=sys.stderr)
        sys.exit(1)

def get_value_by_path(data, path):
    """Get value from nested dictionary using dot notation path."""
    keys = path.split('.')
    current = data
    
    for key in keys:
        if isinstance(current, dict) and key in current:
            current = current[key]
        elif isinstance(current, list) and key.isdigit():
            index = int(key)
            if 0 <= index < len(current):
                current = current[index]
            else:
                return None
        else:
            return None
    
    return current

def get_enabled_platforms(config):
    """Get list of enabled platforms."""
    platforms = config.get('platforms', [])
    return [p['name'] for p in platforms if p.get('enabled', True)]

def get_enabled_test_suites(config):
    """Get list of enabled test suites."""
    test_suites = config.get('test_suites', {})
    return [name for name, suite in test_suites.items() if suite.get('enabled', True)]

def get_platform_architectures(config, platform_name):
    """Get architectures for a specific platform."""
    platforms = config.get('platforms', [])
    for platform in platforms:
        if platform['name'] == platform_name:
            return platform.get('architectures', [])
    return []

def get_zig_target(config, platform_name, arch):
    """Get Zig target for platform and architecture combination."""
    platforms = config.get('platforms', [])
    for platform in platforms:
        if platform['name'] == platform_name:
            zig_target_map = platform.get('zig_target_map', {})
            return zig_target_map.get(arch)
    return None

def validate_config(config):
    """Validate configuration structure and required fields."""
    errors = []
    
    # Check platforms
    platforms = config.get('platforms', [])
    if not platforms:
        errors.append("No platforms defined")
    
    for platform in platforms:
        name = platform.get('name')
        if not name:
            errors.append("Platform missing name")
            continue
            
        if not platform.get('base_image'):
            errors.append(f"Platform {name} missing base_image")
            
        if not platform.get('dockerfile'):
            errors.append(f"Platform {name} missing dockerfile")
            
        architectures = platform.get('architectures', [])
        if not architectures:
            errors.append(f"Platform {name} has no architectures")
            
        zig_target_map = platform.get('zig_target_map', {})
        for arch in architectures:
            if arch not in zig_target_map:
                errors.append(f"Platform {name} missing Zig target for architecture {arch}")
    
    # Check test suites
    test_suites = config.get('test_suites', {})
    if not test_suites:
        errors.append("No test suites defined")
    
    for suite_name, suite in test_suites.items():
        if not suite.get('timeout'):
            errors.append(f"Test suite {suite_name} missing timeout")
            
        if not suite.get('tests'):
            errors.append(f"Test suite {suite_name} has no tests")
    
    # Check timeouts
    timeouts = config.get('timeouts', {})
    required_timeouts = ['global', 'build', 'test', 'cleanup']
    for timeout_name in required_timeouts:
        if timeout_name not in timeouts:
            errors.append(f"Missing timeout: {timeout_name}")
        elif not isinstance(timeouts[timeout_name], int) or timeouts[timeout_name] <= 0:
            errors.append(f"Invalid timeout value for {timeout_name}")
    
    return errors

def main():
    parser = argparse.ArgumentParser(description='YAML Configuration Parser for ZigCat Docker Tests')
    parser.add_argument('config_file', help='Path to YAML configuration file')
    parser.add_argument('command', help='Command to execute')
    parser.add_argument('args', nargs='*', help='Additional arguments')
    
    args = parser.parse_args()
    
    config = load_config(args.config_file)
    
    if args.command == 'validate':
        errors = validate_config(config)
        if errors:
            for error in errors:
                print(f"Error: {error}", file=sys.stderr)
            sys.exit(1)
        else:
            print("Configuration is valid")
            
    elif args.command == 'platforms':
        platforms = get_enabled_platforms(config)
        for platform in platforms:
            print(platform)
            
    elif args.command == 'test-suites':
        suites = get_enabled_test_suites(config)
        for suite in suites:
            print(suite)
            
    elif args.command == 'platform-archs':
        if not args.args:
            print("Error: platform name required", file=sys.stderr)
            sys.exit(1)
        archs = get_platform_architectures(config, args.args[0])
        for arch in archs:
            print(arch)
            
    elif args.command == 'zig-target':
        if len(args.args) < 2:
            print("Error: platform and architecture required", file=sys.stderr)
            sys.exit(1)
        target = get_zig_target(config, args.args[0], args.args[1])
        if target:
            print(target)
        else:
            sys.exit(1)
            
    elif args.command == 'config-value':
        if not args.args:
            print("Error: config path required", file=sys.stderr)
            sys.exit(1)
        value = get_value_by_path(config, args.args[0])
        if value is not None:
            if isinstance(value, (dict, list)):
                print(json.dumps(value))
            else:
                print(value)
        else:
            sys.exit(1)
            
    elif args.command == 'summary':
        print("Configuration Summary:")
        print("Enabled Platforms:")
        for platform in get_enabled_platforms(config):
            print(f"  - {platform}")
            for arch in get_platform_architectures(config, platform):
                target = get_zig_target(config, platform, arch)
                print(f"    - {arch} ({target})")
        
        print("\nEnabled Test Suites:")
        for suite in get_enabled_test_suites(config):
            timeout = get_value_by_path(config, f'test_suites.{suite}.timeout')
            print(f"  - {suite} (timeout: {timeout}s)")
        
        timeouts = config.get('timeouts', {})
        print("\nGlobal Timeouts:")
        for timeout_name in ['global', 'build', 'test', 'cleanup']:
            value = timeouts.get(timeout_name, 'unknown')
            print(f"  - {timeout_name.title()}: {value}s")
            
    else:
        print(f"Error: Unknown command: {args.command}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()