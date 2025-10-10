#!/bin/bash
# Platform mapping utilities for Docker to Zig target conversion

# Function to convert Docker platform to Zig target
docker_platform_to_zig_target() {
    local platform="$1"
    case "$platform" in
        "linux/amd64")
            echo "x86_64-linux-gnu"
            ;;
        "linux/arm64")
            echo "aarch64-linux-gnu"
            ;;
        "linux/amd64/musl"|"alpine/amd64")
            echo "x86_64-linux-musl"
            ;;
        "linux/arm64/musl"|"alpine/arm64")
            echo "aarch64-linux-musl"
            ;;
        "freebsd/amd64")
            echo "x86_64-freebsd"
            ;;
        *)
            echo "x86_64-linux-gnu"  # Default fallback
            ;;
    esac
}

# Function to get supported platforms for a given OS
get_supported_platforms() {
    local os="$1"
    case "$os" in
        "linux")
            echo "linux/amd64 linux/arm64"
            ;;
        "alpine")
            echo "linux/amd64 linux/arm64"
            ;;
        "freebsd")
            echo "linux/amd64"  # Cross-compile only
            ;;
        *)
            echo "linux/amd64"
            ;;
    esac
}

# Function to validate platform support
validate_platform() {
    local platform="$1"
    local supported_platforms=(
        "linux/amd64"
        "linux/arm64"
        "linux/amd64/musl"
        "linux/arm64/musl"
        "freebsd/amd64"
    )
    
    for supported in "${supported_platforms[@]}"; do
        if [[ "$platform" == "$supported" ]]; then
            return 0
        fi
    done
    return 1
}

# Export functions if script is sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f docker_platform_to_zig_target
    export -f get_supported_platforms
    export -f validate_platform
fi

# If script is executed directly, provide CLI interface
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        "convert")
            docker_platform_to_zig_target "$2"
            ;;
        "platforms")
            get_supported_platforms "$2"
            ;;
        "validate")
            if validate_platform "$2"; then
                echo "Platform $2 is supported"
                exit 0
            else
                echo "Platform $2 is not supported"
                exit 1
            fi
            ;;
        *)
            echo "Usage: $0 {convert|platforms|validate} [argument]"
            echo "  convert <docker-platform>  - Convert Docker platform to Zig target"
            echo "  platforms <os>             - List supported platforms for OS"
            echo "  validate <platform>        - Validate platform support"
            exit 1
            ;;
    esac
fi