#!/bin/bash

# ZigCat Release Checksum Generator
# Generates SHA256SUMS file for release artifacts

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
VERBOSE=false
RELEASE_DIR=""
SIGN_CHECKSUMS=false
GPG_KEY=""

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

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate SHA256 checksums for release artifacts

OPTIONS:
    --release-dir DIR              Release directory containing artifacts
                                   (auto-detected from latest version if not specified)
    --sign                         Sign checksums with GPG
    --gpg-key KEY                  GPG key ID for signing
                                   (default: use default key)
    --verbose                      Enable verbose logging
    -h, --help                     Show this help message

EXAMPLES:
    $0 --release-dir docker-tests/artifacts/releases/v0.1.0
    $0 --release-dir releases/v0.1.0 --sign --gpg-key ABC123

EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --release-dir)
                RELEASE_DIR="$2"
                shift 2
                ;;
            --sign)
                SIGN_CHECKSUMS=true
                shift
                ;;
            --gpg-key)
                GPG_KEY="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Auto-detect release directory if not specified
    if [[ -z "$RELEASE_DIR" ]]; then
        log_info "Auto-detecting release directory..."

        # First, try to get version from build.zig
        local version
        version=$(grep -E 'options\.addOption.*"version"' "$PROJECT_ROOT/build.zig" | sed -E 's/.*"version",[[:space:]]*"([^"]+)".*/\1/')

        if [[ -z "$version" ]]; then
            log_error "Could not auto-detect version from build.zig"
            log_error "Please specify --release-dir explicitly"
            usage
            exit 1
        fi

        # Ensure version starts with 'v'
        if [[ "$version" != v* ]]; then
            version="v$version"
        fi

        # Look for tarballs subdirectory first, then fall back to main release dir
        local potential_dirs=(
            "$PROJECT_ROOT/docker-tests/artifacts/releases/$version/tarballs"
            "$PROJECT_ROOT/docker-tests/artifacts/releases/$version"
        )

        for dir in "${potential_dirs[@]}"; do
            if [[ -d "$dir" ]] && compgen -G "$dir/*.tar.gz" > /dev/null 2>&1; then
                RELEASE_DIR="$dir"
                log_success "Detected release directory: $RELEASE_DIR"
                break
            fi
        done

        if [[ -z "$RELEASE_DIR" ]]; then
            log_error "Could not find release directory for version $version"
            log_error "Looked in: ${potential_dirs[*]}"
            log_error "Please specify --release-dir explicitly"
            exit 1
        fi
    fi
}

# Validate environment
validate_environment() {
    log_info "Validating environment..."

    # Check if release directory exists
    if [[ ! -d "$RELEASE_DIR" ]]; then
        log_error "Release directory not found: $RELEASE_DIR"
        return 1
    fi

    # Check for tarballs
    if ! compgen -G "$RELEASE_DIR/*.tar.gz" > /dev/null; then
        log_error "No tarballs found in release directory"
        return 1
    fi

    # Check for GPG if signing
    if [[ "$SIGN_CHECKSUMS" == "true" ]] && ! command -v gpg &> /dev/null; then
        log_error "GPG not found but signing was requested"
        return 1
    fi

    log_success "Environment validation completed"
    return 0
}

# Generate checksums
generate_checksums() {
    log_info "Generating SHA256 checksums..."

    local checksums_file="$RELEASE_DIR/SHA256SUMS"

    # Remove existing checksums file
    rm -f "$checksums_file"

    # Generate checksums for all tarballs
    cd "$RELEASE_DIR"

    local count=0
    for tarball in *.tar.gz; do
        if [[ ! -f "$tarball" ]]; then
            continue
        fi

        log_debug "  Computing checksum for: $tarball"

        # Compute SHA256 and append to file
        if command -v sha256sum &> /dev/null; then
            sha256sum "$tarball" >> "$checksums_file"
        elif command -v shasum &> /dev/null; then
            shasum -a 256 "$tarball" >> "$checksums_file"
        else
            log_error "Neither sha256sum nor shasum found"
            return 1
        fi

        ((count++))
    done

    cd - > /dev/null

    if [[ $count -eq 0 ]]; then
        log_error "No checksums generated"
        return 1
    fi

    log_success "Generated checksums for $count artifacts: $checksums_file"
    return 0
}

# Sign checksums with GPG
sign_checksums() {
    if [[ "$SIGN_CHECKSUMS" != "true" ]]; then
        return 0
    fi

    log_info "Signing checksums with GPG..."

    local checksums_file="$RELEASE_DIR/SHA256SUMS"
    local signature_file="$RELEASE_DIR/SHA256SUMS.asc"

    # Remove existing signature
    rm -f "$signature_file"

    # Sign checksums
    local gpg_args=()
    gpg_args+=("--armor")
    gpg_args+=("--detach-sign")
    gpg_args+=("--output" "$signature_file")

    if [[ -n "$GPG_KEY" ]]; then
        gpg_args+=("--local-user" "$GPG_KEY")
    fi

    gpg_args+=("$checksums_file")

    if gpg "${gpg_args[@]}"; then
        log_success "Checksums signed: $signature_file"
        return 0
    else
        log_error "GPG signing failed"
        return 1
    fi
}

# Verify checksums
verify_checksums() {
    log_info "Verifying checksums..."

    local checksums_file="$RELEASE_DIR/SHA256SUMS"

    cd "$RELEASE_DIR"

    if command -v sha256sum &> /dev/null; then
        if sha256sum -c "$checksums_file" --quiet; then
            log_success "All checksums verified successfully"
            cd - > /dev/null
            return 0
        else
            log_error "Checksum verification failed"
            cd - > /dev/null
            return 1
        fi
    elif command -v shasum &> /dev/null; then
        if shasum -a 256 -c "$checksums_file" --quiet; then
            log_success "All checksums verified successfully"
            cd - > /dev/null
            return 0
        else
            log_error "Checksum verification failed"
            cd - > /dev/null
            return 1
        fi
    else
        log_warn "Cannot verify checksums (no sha256sum or shasum)"
        cd - > /dev/null
        return 0
    fi
}

# Print checksums
print_checksums() {
    log_info "Checksums:"
    echo ""

    local checksums_file="$RELEASE_DIR/SHA256SUMS"

    if [[ -f "$checksums_file" ]]; then
        while IFS= read -r line; do
            echo "  $line"
        done < "$checksums_file"
    fi

    echo ""
}

# Main function
main() {
    # Parse arguments
    parse_args "$@"

    log_info "ZigCat Release Checksum Generator"

    # Validate environment
    validate_environment || exit 1

    # Generate checksums
    if ! generate_checksums; then
        log_error "Checksum generation failed"
        exit 1
    fi

    # Sign checksums (if requested)
    if ! sign_checksums; then
        log_error "Checksum signing failed"
        exit 1
    fi

    # Verify checksums
    if ! verify_checksums; then
        log_error "Checksum verification failed"
        exit 1
    fi

    # Print checksums
    if [[ "$VERBOSE" == "true" ]]; then
        print_checksums
    fi

    log_success "Checksum generation completed successfully!"
    exit 0
}

# Run main
main "$@"
