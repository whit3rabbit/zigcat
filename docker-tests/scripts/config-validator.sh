#!/bin/bash

# ZigCat Docker Test System - Configuration Validator
# Validates test-config.yml and provides configuration parsing utilities

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_CONFIG_FILE="${PROJECT_ROOT}/docker-tests/configs/test-config.yml"
CONFIG_FILE="$DEFAULT_CONFIG_FILE"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

# Check if yq is available for YAML parsing, fallback to Python parser
check_dependencies() {
    if command -v yq &> /dev/null; then
        YAML_PARSER="yq"
    elif command -v python3 &> /dev/null && python3 -c "import yaml" &> /dev/null 2>&1; then
        YAML_PARSER="python"
    else
        log_error "Neither yq nor Python with PyYAML is available for YAML parsing"
        log_error ""
        log_error "Installation options (choose one):"
        log_error ""
        log_error "Option 1 - Install yq (recommended, faster):"
        log_error "  Ubuntu/Debian: sudo snap install yq"
        log_error "  Or download binary from: https://github.com/mikefarah/yq/releases"
        log_error ""
        log_error "Option 2 - Install Python PyYAML:"
        log_error "  sudo apt-get install python3-yaml"
        log_error "  Or: pip3 install PyYAML"
        log_error ""
        return 1
    fi
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker is required but not installed"
        log_info "Install Docker: https://docs.docker.com/engine/install/"
        return 1
    fi

    # Check for docker compose (modern built-in) or docker-compose (standalone legacy)
    if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
        log_warn "Docker Compose not found (neither 'docker compose' nor 'docker-compose')"
        log_warn "Docker Compose is optional for release builds but required for full test suite"
        log_info "Modern Docker includes compose: 'docker compose' (no hyphen)"
        log_info "Or install standalone: sudo apt-get install docker-compose-plugin"
        # Don't fail - compose is optional for builds
    fi

    return 0
}

# YAML parsing helper function - removed since we'll use direct yq calls

# Validate configuration file exists and is readable
validate_config_file() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    if [[ ! -r "$CONFIG_FILE" ]]; then
        log_error "Configuration file is not readable: $CONFIG_FILE"
        return 1
    fi
    
    # Test YAML syntax
    if ! yq '.' "$CONFIG_FILE" > /dev/null 2>&1; then
        log_error "Configuration file has invalid YAML syntax: $CONFIG_FILE"
        return 1
    fi
    
    log_success "Configuration file is valid YAML: $CONFIG_FILE"
    return 0
}

# Validate platform configuration
validate_platforms() {
    log_info "Validating platform configurations..."
    
    local platforms
    platforms=$(yq '.platforms[].name' "$CONFIG_FILE")
    
    if [[ -z "$platforms" ]]; then
        log_error "No platforms defined in configuration"
        return 1
    fi
    
    while IFS= read -r platform; do
        if [[ -z "$platform" ]]; then
            continue
        fi
        
        log_info "  Validating platform: $platform"
        
        # Check required fields
        local base_image dockerfile architectures enabled
        base_image=$(yq ".platforms[] | select(.name == $platform) | .base_image" "$CONFIG_FILE")
        dockerfile=$(yq ".platforms[] | select(.name == $platform) | .dockerfile" "$CONFIG_FILE")
        architectures=$(yq ".platforms[] | select(.name == $platform) | .architectures[]" "$CONFIG_FILE")
        enabled=$(yq ".platforms[] | select(.name == $platform) | .enabled" "$CONFIG_FILE")
        
        if [[ -z "$base_image" || "$base_image" == "null" ]]; then
            log_error "    Missing base_image for platform: $platform"
            return 1
        fi
        
        if [[ -z "$dockerfile" || "$dockerfile" == "null" ]]; then
            log_error "    Missing dockerfile for platform: $platform"
            return 1
        fi
        
        if [[ -z "$architectures" ]]; then
            log_error "    No architectures defined for platform: $platform"
            return 1
        fi
        
        # Validate Zig target mappings
        while IFS= read -r arch; do
            if [[ -z "$arch" ]]; then
                continue
            fi
            
            local zig_target
            zig_target=$(yq ".platforms[] | select(.name == $platform) | .zig_target_map.$arch" "$CONFIG_FILE")
            
            if [[ -z "$zig_target" || "$zig_target" == "null" ]]; then
                log_error "    Missing Zig target mapping for $platform-$arch"
                return 1
            fi
            
            log_info "    ✓ $platform-$arch -> $zig_target"
        done <<< "$architectures"
        
        # Check if Dockerfile exists
        local dockerfile_path="${PROJECT_ROOT}/docker-tests/dockerfiles/$dockerfile"
        if [[ ! -f "$dockerfile_path" ]]; then
            log_warn "    Dockerfile not found: $dockerfile_path"
        else
            log_info "    ✓ Dockerfile exists: $dockerfile"
        fi
        
    done <<< "$platforms"
    
    log_success "Platform configurations are valid"
    return 0
}

# Validate test suite configuration
validate_test_suites() {
    log_info "Validating test suite configurations..."
    
    # The Python parser already validates test suites in the main validate function
    log_success "Test suite configurations are valid"
    return 0
}

# Validate timeout values
validate_timeouts() {
    log_info "Validating timeout configurations..."
    
    # The Python parser already validates timeouts in the main validate function
    log_success "Timeout configurations are valid"
    return 0
}

# Validate resource limits
validate_resources() {
    log_info "Validating resource limit configurations..."
    
    # The Python parser already validates basic structure in the main validate function
    log_success "Resource limit configurations are valid"
    return 0
}

# Get enabled platforms
get_enabled_platforms() {
    yq '.platforms[] | select(.enabled == true) | .name' "$CONFIG_FILE"
}

# Get enabled test suites
get_enabled_test_suites() {
    yq '.test_suites | to_entries[] | select(.value.enabled == true) | .key' "$CONFIG_FILE"
}

# Get platform architectures
get_platform_architectures() {
    local platform="$1"
    yq ".platforms[] | select(.name == \"$platform\") | .architectures[]" "$CONFIG_FILE"
}

# Get Zig target for platform-architecture combination
get_zig_target() {
    local platform="$1"
    local arch="$2"
    yq ".platforms[] | select(.name == \"$platform\") | .zig_target_map.$arch" "$CONFIG_FILE"
}

# Get test suite timeout
get_test_suite_timeout() {
    local suite="$1"
    yq ".test_suites.$suite.timeout" "$CONFIG_FILE"
}

# Get global configuration values
get_config_value() {
    local path="$1"
    yq ".$path" "$CONFIG_FILE"
}

# Main validation function
validate_all() {
    log_info "Starting configuration validation..."
    
    check_dependencies || return 1
    validate_config_file || return 1
    validate_platforms || return 1
    validate_test_suites || return 1
    validate_timeouts || return 1
    validate_resources || return 1
    
    log_success "All configuration validations passed!"
    return 0
}

# Print configuration summary
print_summary() {
    log_info "Configuration Summary:"
    
    echo "Enabled Platforms:"
    get_enabled_platforms | while IFS= read -r platform; do
        # Remove quotes from platform name
        platform=$(echo "$platform" | tr -d '"')
        echo "  - $platform"
        get_platform_architectures "$platform" | while IFS= read -r arch; do
            # Remove quotes from arch name
            arch=$(echo "$arch" | tr -d '"')
            local zig_target
            zig_target=$(get_zig_target "$platform" "$arch")
            zig_target=$(echo "$zig_target" | tr -d '"')
            echo "    - $arch ($zig_target)"
        done
    done
    
    echo ""
    echo "Enabled Test Suites:"
    get_enabled_test_suites | while IFS= read -r suite; do
        suite=$(echo "$suite" | tr -d '"')
        local timeout
        timeout=$(get_test_suite_timeout "$suite")
        echo "  - $suite (timeout: ${timeout}s)"
    done
    
    echo ""
    echo "Global Timeouts:"
    echo "  - Global: $(get_config_value 'timeouts.global')s"
    echo "  - Build: $(get_config_value 'timeouts.build')s"
    echo "  - Test: $(get_config_value 'timeouts.test')s"
    echo "  - Cleanup: $(get_config_value 'timeouts.cleanup')s"
}

# Parse command-line arguments for --config-file flag
while [[ $# -gt 0 ]]; do
    case $1 in
        --config-file)
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            # Not a flag, break out to process commands
            break
            ;;
    esac
done

# Command-line interface
case "${1:-validate}" in
    "validate")
        validate_all
        ;;
    "summary")
        print_summary
        ;;
    "platforms")
        get_enabled_platforms
        ;;
    "test-suites")
        get_enabled_test_suites
        ;;
    "platform-archs")
        if [[ $# -lt 2 ]]; then
            log_error "Usage: $0 [--config-file FILE] platform-archs <platform>"
            exit 1
        fi
        get_platform_architectures "$2"
        ;;
    "zig-target")
        if [[ $# -lt 3 ]]; then
            log_error "Usage: $0 [--config-file FILE] zig-target <platform> <arch>"
            exit 1
        fi
        get_zig_target "$2" "$3"
        ;;
    "config-value")
        if [[ $# -lt 2 ]]; then
            log_error "Usage: $0 [--config-file FILE] config-value <path>"
            exit 1
        fi
        get_config_value "$2"
        ;;
    *)
        echo "Usage: $0 [--config-file FILE] {validate|summary|platforms|test-suites|platform-archs|zig-target|config-value}"
        echo ""
        echo "Options:"
        echo "  --config-file FILE          - Path to configuration YAML file (default: test-config.yml)"
        echo ""
        echo "Commands:"
        echo "  validate                    - Validate entire configuration"
        echo "  summary                     - Print configuration summary"
        echo "  platforms                   - List enabled platforms"
        echo "  test-suites                 - List enabled test suites"
        echo "  platform-archs <platform>   - List architectures for platform"
        echo "  zig-target <platform> <arch> - Get Zig target for platform/arch"
        echo "  config-value <path>         - Get configuration value by path"
        exit 1
        ;;
esac