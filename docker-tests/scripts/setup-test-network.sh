#!/bin/bash

# ZigCat Test Network Setup
# Configures network namespaces and isolation for testing
# Ensures tests don't interfere with each other or the host system

set -euo pipefail

# Configuration
NETWORK_NAME="${NETWORK_NAME:-zigcat-test}"
SUBNET="${SUBNET:-172.21.0.0/16}"
GATEWAY="${GATEWAY:-172.21.0.1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

# Check if running in container
is_container() {
    [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null
}

# Setup network namespace for testing
setup_network_namespace() {
    local namespace_name="$1"
    
    log_info "Setting up network namespace: ${namespace_name}"
    
    # Create network namespace if it doesn't exist
    if ! ip netns list | grep -q "^${namespace_name}"; then
        ip netns add "${namespace_name}"
        log_success "Created network namespace: ${namespace_name}"
    else
        log_info "Network namespace ${namespace_name} already exists"
    fi
    
    # Set up loopback interface in namespace
    ip netns exec "${namespace_name}" ip link set lo up
    
    # Create veth pair for namespace communication
    local veth_host="veth-${namespace_name}"
    local veth_ns="veth-ns-${namespace_name}"
    
    if ! ip link show "${veth_host}" >/dev/null 2>&1; then
        ip link add "${veth_host}" type veth peer name "${veth_ns}"
        ip link set "${veth_ns}" netns "${namespace_name}"
        
        # Configure host side
        ip addr add "172.21.1.1/24" dev "${veth_host}"
        ip link set "${veth_host}" up
        
        # Configure namespace side
        ip netns exec "${namespace_name}" ip addr add "172.21.1.2/24" dev "${veth_ns}"
        ip netns exec "${namespace_name}" ip link set "${veth_ns}" up
        ip netns exec "${namespace_name}" ip route add default via "172.21.1.1"
        
        log_success "Configured veth pair for namespace ${namespace_name}"
    fi
}

# Setup port ranges for testing
setup_test_ports() {
    log_info "Configuring test port ranges..."
    
    # Reserve port ranges for different test types
    # 12000-12099: Basic connectivity tests
    # 12100-12199: Protocol tests (TLS, proxy)
    # 12200-12299: Feature tests (exec, transfer)
    # 12300-12399: Security tests
    # 12400-12499: Performance tests
    
    # Check if ports are available
    local test_ports=(12345 12346 12347 12348 12349)
    
    for port in "${test_ports[@]}"; do
        if netstat -ln 2>/dev/null | grep -q ":${port} "; then
            log_warn "Port ${port} is already in use"
        else
            log_info "Port ${port} is available for testing"
        fi
    done
}

# Configure firewall rules for testing
setup_firewall_rules() {
    log_info "Configuring firewall rules for testing..."
    
    # Allow loopback traffic
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -i lo -j ACCEPT 2>/dev/null || log_warn "Could not configure iptables rules"
        iptables -I OUTPUT -o lo -j ACCEPT 2>/dev/null || log_warn "Could not configure iptables rules"
        
        # Allow test port ranges
        iptables -I INPUT -p tcp --dport 12000:12499 -j ACCEPT 2>/dev/null || log_warn "Could not configure iptables rules"
        iptables -I INPUT -p udp --dport 12000:12499 -j ACCEPT 2>/dev/null || log_warn "Could not configure iptables rules"
    fi
}

# Setup container network isolation
setup_container_network() {
    log_info "Setting up container network isolation..."
    
    # Configure container-specific networking
    if is_container; then
        log_info "Running in container environment"
        
        # Ensure localhost resolution works
        if ! grep -q "127.0.0.1 localhost" /etc/hosts; then
            echo "127.0.0.1 localhost" >> /etc/hosts
        fi
        
        # Configure DNS for testing
        if [[ -w /etc/resolv.conf ]]; then
            echo "nameserver 8.8.8.8" >> /etc/resolv.conf
            echo "nameserver 8.8.4.4" >> /etc/resolv.conf
        fi
        
        # Set up test-specific network configuration
        sysctl -w net.core.somaxconn=1024 2>/dev/null || log_warn "Could not configure somaxconn"
        sysctl -w net.ipv4.ip_local_port_range="32768 65535" 2>/dev/null || log_warn "Could not configure port range"
        
        log_success "Container network configured"
    else
        log_info "Running on host system"
    fi
}

# Verify network connectivity
verify_network_connectivity() {
    log_info "Verifying network connectivity..."
    
    # Test loopback connectivity
    if ping -c 1 127.0.0.1 >/dev/null 2>&1; then
        log_success "Loopback connectivity verified"
    else
        log_error "Loopback connectivity failed"
        return 1
    fi
    
    # Test localhost resolution
    if ping -c 1 localhost >/dev/null 2>&1; then
        log_success "Localhost resolution verified"
    else
        log_warn "Localhost resolution failed"
    fi
    
    # Test external connectivity (if not in isolated environment)
    if ! is_container || [[ "${ALLOW_EXTERNAL:-false}" == "true" ]]; then
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            log_success "External connectivity verified"
        else
            log_warn "External connectivity not available"
        fi
    fi
}

# Setup test data and fixtures
setup_test_fixtures() {
    log_info "Setting up test fixtures..."
    
    # Create test data directory
    mkdir -p /tmp/zigcat-test-data
    
    # Create test files for transfer tests
    echo "Hello ZigCat Test" > /tmp/zigcat-test-data/test-file.txt
    echo -e "Line 1\nLine 2\nLine 3" > /tmp/zigcat-test-data/multiline-test.txt
    
    # Create binary test data
    dd if=/dev/urandom of=/tmp/zigcat-test-data/binary-test.dat bs=1024 count=1 2>/dev/null || true
    
    # Create large test file for performance tests
    dd if=/dev/zero of=/tmp/zigcat-test-data/large-test.dat bs=1024 count=100 2>/dev/null || true
    
    # Set permissions
    chmod 644 /tmp/zigcat-test-data/*
    
    log_success "Test fixtures created in /tmp/zigcat-test-data/"
}

# Cleanup network configuration
cleanup_network() {
    log_info "Cleaning up network configuration..."
    
    # Remove test network namespaces
    for ns in $(ip netns list | grep "zigcat-test" | awk '{print $1}' 2>/dev/null || true); do
        ip netns delete "${ns}" 2>/dev/null || true
        log_info "Removed network namespace: ${ns}"
    done
    
    # Remove veth interfaces
    for iface in $(ip link show | grep "veth-zigcat" | awk -F: '{print $2}' | awk '{print $1}' 2>/dev/null || true); do
        ip link delete "${iface}" 2>/dev/null || true
        log_info "Removed veth interface: ${iface}"
    done
    
    # Clean up test data
    rm -rf /tmp/zigcat-test-data 2>/dev/null || true
    
    log_success "Network cleanup completed"
}

# Main function
main() {
    local action="${1:-setup}"
    
    case "${action}" in
        "setup")
            log_info "Setting up ZigCat test network environment"
            setup_container_network
            setup_test_ports
            setup_firewall_rules
            setup_test_fixtures
            verify_network_connectivity
            log_success "Test network environment setup completed"
            ;;
        "cleanup")
            cleanup_network
            ;;
        "verify")
            verify_network_connectivity
            ;;
        "namespace")
            local namespace_name="${2:-zigcat-test-ns}"
            setup_network_namespace "${namespace_name}"
            ;;
        *)
            echo "Usage: $0 {setup|cleanup|verify|namespace [name]}"
            echo "  setup     - Set up test network environment"
            echo "  cleanup   - Clean up network configuration"
            echo "  verify    - Verify network connectivity"
            echo "  namespace - Create network namespace for testing"
            exit 1
            ;;
    esac
}

# Handle script termination
trap cleanup_network EXIT INT TERM

# Run main function
main "$@"