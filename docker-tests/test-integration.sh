#!/bin/bash

# Simple integration test for the Docker test system
# Verifies that the test execution environment works correctly

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Test script permissions
test_script_permissions() {
    log_info "Testing script permissions..."
    
    local scripts=(
        "scripts/execute-zig-tests.sh"
        "scripts/orchestrate-tests.sh"
        "scripts/parse-zig-test-output.py"
        "scripts/setup-test-network.sh"
        "scripts/run-platform-tests.sh"
    )
    
    for script in "${scripts[@]}"; do
        local script_path="${SCRIPT_DIR}/${script}"
        if [[ -x "${script_path}" ]]; then
            log_success "${script} is executable"
        else
            log_error "${script} is not executable"
            return 1
        fi
    done
}

# Test Docker Compose configuration
test_docker_compose_config() {
    log_info "Testing Docker Compose configuration..."
    
    if [[ ! -f "${PROJECT_ROOT}/docker-compose.test.yml" ]]; then
        log_error "Docker Compose file not found"
        return 1
    fi
    
    # Validate compose file syntax
    if docker-compose -f "${PROJECT_ROOT}/docker-compose.test.yml" config >/dev/null 2>&1; then
        log_success "Docker Compose configuration is valid"
    else
        log_error "Docker Compose configuration is invalid"
        return 1
    fi
}

# Test configuration files
test_configuration_files() {
    log_info "Testing configuration files..."
    
    local config_files=(
        "configs/test-config.yml"
    )
    
    for config in "${config_files[@]}"; do
        local config_path="${SCRIPT_DIR}/${config}"
        if [[ -f "${config_path}" ]]; then
            log_success "${config} exists"
        else
            log_error "${config} not found"
            return 1
        fi
    done
}

# Test Dockerfile syntax
test_dockerfiles() {
    log_info "Testing Dockerfile syntax..."
    
    local dockerfiles=(
        "dockerfiles/Dockerfile.linux"
        "dockerfiles/Dockerfile.alpine"
        "dockerfiles/Dockerfile.freebsd"
    )
    
    for dockerfile in "${dockerfiles[@]}"; do
        local dockerfile_path="${SCRIPT_DIR}/${dockerfile}"
        if [[ -f "${dockerfile_path}" ]]; then
            log_success "${dockerfile} exists"
            
            # Basic syntax check
            if grep -q "FROM" "${dockerfile_path}" && grep -q "WORKDIR" "${dockerfile_path}"; then
                log_success "${dockerfile} has basic Dockerfile structure"
            else
                log_error "${dockerfile} missing basic Dockerfile structure"
                return 1
            fi
        else
            log_error "${dockerfile} not found"
            return 1
        fi
    done
}

# Test Python script syntax
test_python_scripts() {
    log_info "Testing Python script syntax..."
    
    if command -v python3 >/dev/null 2>&1; then
        local python_scripts=(
            "scripts/parse-zig-test-output.py"
        )
        
        for script in "${python_scripts[@]}"; do
            local script_path="${SCRIPT_DIR}/${script}"
            if python3 -m py_compile "${script_path}" 2>/dev/null; then
                log_success "${script} syntax is valid"
            else
                log_error "${script} has syntax errors"
                return 1
            fi
        done
    else
        log_info "Python3 not available, skipping Python syntax tests"
    fi
}

# Test directory structure
test_directory_structure() {
    log_info "Testing directory structure..."
    
    local required_dirs=(
        "scripts"
        "configs"
        "dockerfiles"
        "results"
    )
    
    for dir in "${required_dirs[@]}"; do
        local dir_path="${SCRIPT_DIR}/${dir}"
        if [[ -d "${dir_path}" ]]; then
            log_success "Directory ${dir} exists"
        else
            log_error "Directory ${dir} not found"
            return 1
        fi
    done
}

# Main test function
main() {
    log_info "Running Docker test system integration tests..."
    
    local failed_tests=0
    
    # Run all tests
    test_directory_structure || ((failed_tests++))
    test_script_permissions || ((failed_tests++))
    test_configuration_files || ((failed_tests++))
    test_dockerfiles || ((failed_tests++))
    test_python_scripts || ((failed_tests++))
    test_docker_compose_config || ((failed_tests++))
    
    echo
    if [[ ${failed_tests} -eq 0 ]]; then
        log_success "All integration tests passed!"
        log_info "Docker test system is ready for use"
        echo
        log_info "To run tests:"
        echo "  ./docker-tests/scripts/orchestrate-tests.sh --platforms linux,alpine --verbose"
        exit 0
    else
        log_error "${failed_tests} integration tests failed"
        exit 1
    fi
}

main "$@"