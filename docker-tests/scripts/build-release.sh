#!/usr/bin/env bash

# ZigCat Enhanced Release Build Orchestrator v2
# Builds complete release artifacts for all platforms with continue-on-error support
# Creates descriptive filenames and handles failures gracefully

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS_DIR="$PROJECT_ROOT/docker-tests/artifacts"
LOGS_DIR="$PROJECT_ROOT/docker-tests/logs"
DOCKERFILES_DIR="$PROJECT_ROOT/docker-tests/dockerfiles"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
VERBOSE=false
VERSION=""
CONTINUE_ON_ERROR=true
BUILD_TIMEOUT=600
CONFIG_FILE=""
SKIP_BUILD=false
SKIP_PACKAGE=false
CREATE_CHECKSUMS=true
VALIDATE_BINARIES=true
SUCCESSFUL_BUILDS=()
FAILED_BUILDS=()
SKIPPED_BUILDS=()
DEFAULT_ZIG_VERSION="0.15.1"
ZIG_VERSION_OVERRIDE="${ZIG_VERSION_OVERRIDE:-${ZIG_VERSION:-}}"
ZIG_RELEASE_VERSION=""

# Build matrix - explicit platform definitions
declare -A BUILD_MATRIX

# Linux glibc with OpenSSL (64-bit only - glibc doesn't support 32-bit well anymore)
BUILD_MATRIX["linux-x64-openssl"]="linux:amd64:x86_64-linux-gnu:-Dtls=true -Dtls-backend=openssl:glibc-openssl-dynamic"
BUILD_MATRIX["linux-arm64-openssl"]="linux:arm64:aarch64-linux-gnu:-Dtls=true -Dtls-backend=openssl:glibc-openssl-dynamic"

# Linux musl static (all architectures - maximum portability)
BUILD_MATRIX["linux-x64-static"]="linux:amd64:x86_64-linux-musl:-Dstatic=true -Dtls=false:musl-static"
BUILD_MATRIX["linux-arm64-static"]="linux:arm64:aarch64-linux-musl:-Dstatic=true -Dtls=false:musl-static"
BUILD_MATRIX["linux-x86-static"]="linux:386:i386-linux-musl:-Dstatic=true -Dtls=false:musl-static"
BUILD_MATRIX["linux-arm-static"]="linux:arm/v7:arm-linux-musleabihf:-Dstatic=true -Dtls=false:musl-static"

# Alpine with wolfSSL (64-bit + 32-bit)
BUILD_MATRIX["alpine-x64-wolfssl"]="alpine:amd64:x86_64-linux-musl:-Dstatic=true -Dtls=true -Dtls-backend=wolfssl:musl-wolfssl-static"
BUILD_MATRIX["alpine-arm64-wolfssl"]="alpine:arm64:aarch64-linux-musl:-Dstatic=true -Dtls=true -Dtls-backend=wolfssl:musl-wolfssl-static"
BUILD_MATRIX["alpine-x86-wolfssl"]="alpine:386:i386-linux-musl:-Dstatic=true -Dtls=true -Dtls-backend=wolfssl:musl-wolfssl-static"

# FreeBSD (64-bit only)
BUILD_MATRIX["freebsd-x64"]="freebsd:amd64:x86_64-freebsd:-Dtls=false:freebsd"

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

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1" >&2
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

# Determine Zig compiler version to use for Docker builds.
# Respects ZIG_VERSION_OVERRIDE / ZIG_VERSION environment variables or --zig-version flag.
detect_zig_version() {
    if [[ -n "$ZIG_RELEASE_VERSION" ]]; then
        return 0
    fi

    if [[ -n "$ZIG_VERSION_OVERRIDE" ]]; then
        ZIG_RELEASE_VERSION="$ZIG_VERSION_OVERRIDE"
        log_info "Using Zig version override: $ZIG_RELEASE_VERSION"
        return 0
    fi

    log_step "Detecting latest Zig compiler version..."

    local downloader=""
    if command -v curl >/dev/null 2>&1; then
        downloader="curl -fsSL"
    elif command -v wget >/dev/null 2>&1; then
        downloader="wget -qO-"
    else
        log_warn "  Neither curl nor wget available; falling back to default ${DEFAULT_ZIG_VERSION}"
        ZIG_RELEASE_VERSION="$DEFAULT_ZIG_VERSION"
        return 0
    fi

    local index_json=""
    if ! index_json=$($downloader https://ziglang.org/download/index.json 2>/dev/null); then
        log_warn "  Failed to download Zig index; falling back to ${DEFAULT_ZIG_VERSION}"
        ZIG_RELEASE_VERSION="$DEFAULT_ZIG_VERSION"
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "  python3 not found; falling back to ${DEFAULT_ZIG_VERSION}"
        ZIG_RELEASE_VERSION="$DEFAULT_ZIG_VERSION"
        return 0
    fi

    local latest_version=""
    latest_version=$(printf '%s' "$index_json" | python3 - <<'PY' 2>/dev/null
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

def emit(ver):
    if isinstance(ver, str) and ver:
        print(ver)
        sys.exit(0)

stable = data.get("stable")
if isinstance(stable, dict):
    stable = stable.get("version")
emit(stable)

candidates = []
for key, value in data.items():
    if key in ("master", "_meta", "stable"):
        continue
    if isinstance(value, dict):
        ver = value.get("version") or key
    else:
        ver = key
    if isinstance(ver, str) and ver[0].isdigit():
        candidates.append(ver)

if not candidates:
    sys.exit(1)

def parse(ver):
    main, _, suffix = ver.partition('-')
    parts = []
    for piece in main.split('.'):
        try:
            parts.append(int(piece))
        except ValueError:
            parts.append(0)
    if len(parts) < 3:
        parts += [0] * (3 - len(parts))
    return parts, suffix != "", suffix

candidates.sort(key=parse)
print(candidates[-1])
PY
) || true

    if [[ -z "$latest_version" ]]; then
        log_warn "  Unable to determine latest Zig version; falling back to ${DEFAULT_ZIG_VERSION}"
        ZIG_RELEASE_VERSION="$DEFAULT_ZIG_VERSION"
        return 0
    fi

    ZIG_RELEASE_VERSION="$latest_version"
    log_info "Detected Zig compiler version: $ZIG_RELEASE_VERSION"
    return 0
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

ZigCat Enhanced Release Build Orchestrator v2
Build complete release artifacts with descriptive names and continue-on-error

OPTIONS:
    -c, --config FILE          YAML configuration file (optional, uses hardcoded BUILD_MATRIX if not specified)
    -v, --version VERSION      Release version (e.g., v0.0.1, auto-detected from build.zig if not specified)
    --zig-version VERSION      Override Zig compiler version (default: latest stable)
    --continue-on-error        Continue building if individual platforms fail (default: true)
    --stop-on-error            Stop if any platform fails
    --skip-build               Skip build phase (use existing artifacts)
    --skip-package             Skip packaging phase (build only)
    --no-checksums             Don't generate checksums
    --no-validation            Skip binary validation
    --verbose                  Enable verbose logging
    --timeout SECONDS          Build timeout per platform (default: 600)
    -h, --help                 Show this help message

EXAMPLES:
    # Build all platforms (auto-detect version from build.zig)
    $0

    # Build with specific version
    $0 --version v0.0.1

    # Build with verbose output
    $0 --version v0.0.1 --verbose

    # Stop on first failure
    $0 --version v0.0.1 --stop-on-error

    # Build using YAML configuration
    $0 --config docker-tests/configs/releases/release-all.yml --version v0.0.1

    # Build only (skip packaging)
    $0 --skip-package --version v0.0.1

PLATFORMS (Default Hardcoded Matrix):
    64-bit with TLS:
    - Linux x64 glibc+OpenSSL (dynamic, ~6MB)
    - Linux ARM64 glibc+OpenSSL (dynamic, ~6MB)
    - Alpine x64 musl+wolfSSL static (~835KB, GPLv2)
    - Alpine ARM64 musl+wolfSSL static (~865KB, GPLv2)
    - Alpine x86 musl+wolfSSL static (~800KB, GPLv2, 32-bit)

    Portable static (no TLS, zero dependencies):
    - Linux x64 musl static (~2MB)
    - Linux ARM64 musl static (~2MB)
    - Linux x86 musl static (~1.8MB, 32-bit)
    - Linux ARM musl static (~1.9MB, 32-bit ARMv7)

    BSD:
    - FreeBSD x64 (~300KB)

OUTPUT:
    docker-tests/artifacts/{platform}-{arch}/
    ├── zigcat (or zigcat-wolfssl)
    └── build.log

EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -v|--version)
                VERSION="$2"
                shift 2
                ;;
            --zig-version)
                ZIG_VERSION_OVERRIDE="$2"
                shift 2
                ;;
            --continue-on-error)
                CONTINUE_ON_ERROR=true
                shift
                ;;
            --stop-on-error)
                CONTINUE_ON_ERROR=false
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-package)
                SKIP_PACKAGE=true
                shift
                ;;
            --no-checksums)
                CREATE_CHECKSUMS=false
                shift
                ;;
            --no-validation)
                VALIDATE_BINARIES=false
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --timeout)
                BUILD_TIMEOUT="$2"
                shift 2
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
}

# Auto-detect version from build.zig
detect_version() {
    if [[ -n "$VERSION" ]]; then
        log_debug "Using specified version: $VERSION"
        return 0
    fi

    log_info "Auto-detecting version from build.zig..."

    # Extract version from build.zig (line with: options.addOption([]const u8, "version", "x.y.z");)
    local detected_version
    detected_version=$(grep -E 'options\.addOption.*"version"' "$PROJECT_ROOT/build.zig" | sed -E 's/.*"version",[[:space:]]*"([^"]+)".*/\1/')

    if [[ -z "$detected_version" ]]; then
        log_error "Could not auto-detect version from build.zig"
        log_error "Please specify version with --version flag"
        return 1
    fi

    # Ensure version starts with 'v'
    if [[ "$detected_version" != v* ]]; then
        detected_version="v$detected_version"
    fi

    VERSION="$detected_version"
    log_success "Detected version: $VERSION"
    return 0
}

# Detect yq version and set command prefix
detect_yq_version() {
    if ! command -v yq &> /dev/null; then
        return 1
    fi

    # Check if it's mikefarah/yq (Go version) or kislyuk/yq (Python/jq wrapper)
    if yq --version 2>&1 | grep -q "mikefarah"; then
        YQ_CMD="yq eval"
        YQ_TYPE="mikefarah"
    elif yq --version 2>&1 | grep -qi "python\|jq"; then
        YQ_CMD="yq -r"
        YQ_TYPE="kislyuk"
    else
        # Try to detect by testing syntax
        if yq eval '.test' <<< 'test: value' &>/dev/null; then
            YQ_CMD="yq eval"
            YQ_TYPE="mikefarah"
        elif yq -r '.test' <<< '{"test": "value"}' &>/dev/null; then
            YQ_CMD="yq -r"
            YQ_TYPE="kislyuk"
        else
            YQ_CMD="yq eval"
            YQ_TYPE="unknown"
        fi
    fi

    log_debug "Detected yq type: $YQ_TYPE (command: $YQ_CMD)"
    return 0
}

# Load YAML configuration and populate BUILD_MATRIX
load_yaml_config() {
    if [[ -z "$CONFIG_FILE" ]]; then
        log_debug "No config file specified, using hardcoded BUILD_MATRIX"
        return 0
    fi

    log_step "Loading YAML configuration: $CONFIG_FILE"

    # Check if yq is installed
    if ! command -v yq &> /dev/null; then
        log_error "yq is required for YAML config support but not found"
        log_error "Install: brew install yq (macOS) or pip install yq (Linux)"
        log_error "See: https://github.com/mikefarah/yq or https://github.com/kislyuk/yq"
        return 1
    fi

    # Detect yq version
    detect_yq_version

    # Validate config file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi

    # Clear hardcoded BUILD_MATRIX
    declare -gA BUILD_MATRIX=()

    # Parse platforms from YAML (syntax depends on yq version)
    local platform_count
    if [[ "$YQ_TYPE" == "kislyuk" ]]; then
        platform_count=$($YQ_CMD '.platforms | length' "$CONFIG_FILE")
    else
        platform_count=$(yq eval '.platforms | length' "$CONFIG_FILE")
    fi

    for ((i=0; i<platform_count; i++)); do
        local enabled
        if [[ "$YQ_TYPE" == "kislyuk" ]]; then
            enabled=$($YQ_CMD ".platforms[$i].enabled" "$CONFIG_FILE")
        else
            enabled=$(yq eval ".platforms[$i].enabled" "$CONFIG_FILE")
        fi

        if [[ "$enabled" != "true" ]]; then
            log_debug "  Skipping disabled platform at index $i"
            continue
        fi

        local platform_name artifact_suffix arch_count
        if [[ "$YQ_TYPE" == "kislyuk" ]]; then
            platform_name=$($YQ_CMD ".platforms[$i].name" "$CONFIG_FILE")
            artifact_suffix=$($YQ_CMD ".platforms[$i].artifact_suffix" "$CONFIG_FILE")
            arch_count=$($YQ_CMD ".platforms[$i].architectures | length" "$CONFIG_FILE")
        else
            platform_name=$(yq eval ".platforms[$i].name" "$CONFIG_FILE")
            artifact_suffix=$(yq eval ".platforms[$i].artifact_suffix" "$CONFIG_FILE")
            arch_count=$(yq eval ".platforms[$i].architectures | length" "$CONFIG_FILE")
        fi

        for ((j=0; j<arch_count; j++)); do
            local arch zig_target build_opts config_dockerfile

            if [[ "$YQ_TYPE" == "kislyuk" ]]; then
                arch=$($YQ_CMD ".platforms[$i].architectures[$j]" "$CONFIG_FILE")
                zig_target=$($YQ_CMD ".platforms[$i].zig_target_map.$arch" "$CONFIG_FILE")
                # Build options (join array with spaces) - kislyuk/yq outputs JSON array
                build_opts=$($YQ_CMD ".platforms[$i].build_options | join(\" \")" "$CONFIG_FILE")
                # Dockerfile path (optional - falls back to default if not specified)
                config_dockerfile=$($YQ_CMD ".platforms[$i].dockerfile // \"\"" "$CONFIG_FILE")
            else
                arch=$(yq eval ".platforms[$i].architectures[$j]" "$CONFIG_FILE")
                zig_target=$(yq eval ".platforms[$i].zig_target_map.$arch" "$CONFIG_FILE")
                # Build options (join array with spaces)
                build_opts=$(yq eval ".platforms[$i].build_options | join(\" \")" "$CONFIG_FILE")
                # Dockerfile path (optional - falls back to default if not specified)
                config_dockerfile=$(yq eval ".platforms[$i].dockerfile // \"\"" "$CONFIG_FILE")
            fi

            # Determine platform base (linux/alpine/freebsd)
            local platform_base
            if [[ "$platform_name" == *"alpine"* ]]; then
                platform_base="alpine"
            elif [[ "$platform_name" == *"freebsd"* ]]; then
                platform_base="freebsd"
            else
                platform_base="linux"
            fi

            # Create build ID
            local build_id="${platform_name}-${arch}"

            # Build spec: platform:arch:zig_target:build_opts:suffix:dockerfile
            BUILD_MATRIX["$build_id"]="${platform_base}:${arch}:${zig_target}:${build_opts}:${artifact_suffix}:${config_dockerfile}"

            log_debug "  Loaded: $build_id (dockerfile: ${config_dockerfile:-default})"
        done
    done

    log_success "Loaded ${#BUILD_MATRIX[@]} platform configurations from YAML"
    return 0
}

# Validate environment
validate_environment() {
    log_step "Validating environment..."

    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        return 1
    fi

    if ! docker info > /dev/null 2>&1; then
        log_error "Docker daemon is not running"
        log_error "Start Docker: systemctl start docker (Linux) or open Docker Desktop (macOS)"
        return 1
    fi

    # Create directories
    mkdir -p "$ARTIFACTS_DIR"
    mkdir -p "$LOGS_DIR"

    log_success "Environment validation completed"
    return 0
}

# Build a single platform
build_platform() {
    local build_id="$1"
    local build_spec="${BUILD_MATRIX[$build_id]}"

    IFS=':' read -r platform arch zig_target build_opts suffix config_dockerfile <<< "$build_spec"

    log_step "Building: $build_id"
    log_debug "  Platform: $platform, Arch: $arch"
    log_debug "  Zig Target: $zig_target"
    log_debug "  Build Options: $build_opts"
    log_debug "  Zig Version: ${ZIG_RELEASE_VERSION:-unknown}"
    log_debug "  Suffix: $suffix"
    log_debug "  Dockerfile: ${config_dockerfile:-default}"

    # Determine Docker platform
    local docker_platform="linux/$arch"

    # Determine Dockerfile (use YAML config if specified, otherwise fallback to default)
    local dockerfile=""
    if [[ -n "$config_dockerfile" ]]; then
        # YAML specified a custom Dockerfile - check release/ subdirectory first
        if [[ -f "$DOCKERFILES_DIR/release/$config_dockerfile" ]]; then
            dockerfile="$DOCKERFILES_DIR/release/$config_dockerfile"
            log_debug "  Using YAML Dockerfile from release/: $config_dockerfile"
        elif [[ -f "$DOCKERFILES_DIR/$config_dockerfile" ]]; then
            dockerfile="$DOCKERFILES_DIR/$config_dockerfile"
            log_debug "  Using YAML Dockerfile: $config_dockerfile"
        else
            log_error "Dockerfile specified in YAML not found: $config_dockerfile"
            log_error "  Searched: $DOCKERFILES_DIR/release/$config_dockerfile"
            log_error "  Searched: $DOCKERFILES_DIR/$config_dockerfile"
            return 1
        fi
    else
        # Fallback to default Dockerfiles based on platform
        log_debug "  No dockerfile in YAML, using default for platform: $platform"
        case "$platform" in
            linux)
                dockerfile="$DOCKERFILES_DIR/Dockerfile.linux"
                ;;
            alpine)
                dockerfile="$DOCKERFILES_DIR/Dockerfile.alpine"
                ;;
            freebsd)
                dockerfile="$DOCKERFILES_DIR/Dockerfile.freebsd"
                ;;
            *)
                log_error "Unknown platform: $platform"
                return 1
                ;;
        esac
    fi

    if [[ ! -f "$dockerfile" ]]; then
        log_error "Dockerfile not found: $dockerfile"
        return 1
    fi

    # Prepare artifact directory
    local artifact_dir="$ARTIFACTS_DIR/${platform}-${arch}"
    mkdir -p "$artifact_dir"

    # Prepare log file
    local log_file="$LOGS_DIR/build-${build_id}.log"

    # Build command
    log_info "  Building with Docker (platform: $docker_platform)..."

    # Generate unique BUILD_ID to prevent Zig cache corruption across builds
    # Format: timestamp-pid-random to ensure uniqueness even for parallel builds
    local docker_build_id="${build_id}-$(date +%s)-$$-$RANDOM"
    log_debug "  Using BUILD_ID: $docker_build_id"

    # Determine optional base image overrides (needed for architectures like x86)
    local build_args=(
        "--platform" "$docker_platform"
        "--build-arg" "ZIG_TARGET=$zig_target"
        "--build-arg" "ZIG_VERSION=$ZIG_RELEASE_VERSION"
        "--build-arg" "DEFAULT_ZIG_VERSION=$DEFAULT_ZIG_VERSION"
        "--build-arg" "BUILD_OPTIONS=$build_opts"
        "--build-arg" "BUILD_ID=$docker_build_id"
    )

    local dockerfile_name
    dockerfile_name=$(basename "$dockerfile")
    if [[ "$dockerfile_name" == *"alpine"* || "$dockerfile_name" == *"linux-musl"* ]]; then
        local base_image="alpine:3.18"
        local runtime_base_image="alpine:3.18"
        if [[ "$arch" == "x86" || "$arch" == "386" ]]; then
            base_image="alpine:3.12"
            runtime_base_image="alpine:3.12"
        fi
        build_args+=("--build-arg" "BASE_IMAGE=$base_image")
        build_args+=("--build-arg" "RUNTIME_BASE_IMAGE=$runtime_base_image")
        log_debug "  Using base images: builder=$base_image runtime=$runtime_base_image"
    fi

    build_args+=(
        "-f" "$dockerfile"
        "-t" "zigcat-builder-${build_id}:latest"
        "$PROJECT_ROOT"
    )

    # Note: --security-opt is deprecated and removed. BuildKit cache mounts work without it.

    log_debug "  Docker build command: docker buildx build --load ${build_args[*]}"

    # Execute build (using BuildKit for cache mounts)
    if ! timeout "$BUILD_TIMEOUT" docker buildx build --load "${build_args[@]}" > "$log_file" 2>&1; then
        log_error "  Build failed (see $log_file for details)"
        FAILED_BUILDS+=("$build_id")
        return 1
    fi

    # Extract binary from container
    log_info "  Extracting binary..."

    local container_id
    container_id=$(docker create "zigcat-builder-${build_id}:latest")

    # Determine binary name in container
    local binary_name="zigcat"
    if [[ "$suffix" == *"wolfssl"* ]]; then
        binary_name="zigcat-wolfssl"
    fi

    local candidate_paths=(
        "/app/zig-out/bin/$binary_name"
        "/build/zig-out/bin/$binary_name"
        "/usr/local/bin/$binary_name"
        "/bin/$binary_name"
    )

    local copied=false
    for candidate in "${candidate_paths[@]}"; do
        rm -f "$artifact_dir/zigcat"
        if docker cp "$container_id:$candidate" "$artifact_dir/zigcat" > /dev/null 2>> "$log_file"; then
            log_debug "  Extracted binary from $candidate"
            copied=true
            break
        else
            log_debug "  Binary not at $candidate"
        fi
    done

    if [[ "$copied" != true ]]; then
        log_error "  Failed to extract binary (searched: ${candidate_paths[*]})"
        docker rm "$container_id" > /dev/null 2>&1
        FAILED_BUILDS+=("$build_id")
        return 1
    fi

    docker rm "$container_id" > /dev/null 2>&1

    # Get binary size
    local binary_size
    binary_size=$(du -h "$artifact_dir/zigcat" | cut -f1)

    # Save build metadata for packaging script
    cat > "$artifact_dir/.build-meta" <<EOF
PLATFORM=$platform
ARCH=$arch
ZIG_TARGET=$zig_target
BUILD_OPTIONS="$build_opts"
ZIG_VERSION=$ZIG_RELEASE_VERSION
SUFFIX=$suffix
BUILD_ID=$build_id
EOF

    log_success "  Build successful: $build_id ($binary_size)"
    SUCCESSFUL_BUILDS+=("$build_id:$platform:$arch:$suffix")

    return 0
}

# Build all platforms
build_all_platforms() {
    if [[ "$SKIP_BUILD" == "true" ]]; then
        log_info "Skipping build phase as requested (using existing artifacts)"
        return 0
    fi

    log_step "Building all platforms..."

    local total_builds=${#BUILD_MATRIX[@]}
    local current_build=0

    for build_id in "${!BUILD_MATRIX[@]}"; do
        ((current_build++))

        echo ""
        log_info "[$current_build/$total_builds] Processing: $build_id"

        if build_platform "$build_id"; then
            log_success "  ✅ $build_id"
        else
            log_error "  ❌ $build_id"

            if [[ "$CONTINUE_ON_ERROR" == "false" ]]; then
                log_error "Stopping due to build failure (--stop-on-error)"
                return 1
            fi

            log_warn "  Continuing to next build..."
        fi
    done

    log_success "Build phase completed"
    return 0
}

# Generate build report
generate_build_report() {
    log_step "Generating build report..."

    local report_file="$ARTIFACTS_DIR/BUILD_REPORT.md"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    {
        echo "# ZigCat Build Report - $VERSION"
        echo ""
        echo "**Build Date:** $timestamp"
        echo "**Zig Compiler:** $ZIG_RELEASE_VERSION"
        echo "**Continue on Error:** $CONTINUE_ON_ERROR"
        echo "**Build Timeout:** ${BUILD_TIMEOUT}s"
        echo ""
        echo "## Summary"
        echo ""
        echo "- **Total Builds:** ${#BUILD_MATRIX[@]}"
        echo "- **Successful:** ${#SUCCESSFUL_BUILDS[@]}"
        echo "- **Failed:** ${#FAILED_BUILDS[@]}"
        echo "- **Skipped:** ${#SKIPPED_BUILDS[@]}"
        echo ""

        if [[ ${#SUCCESSFUL_BUILDS[@]} -gt 0 ]]; then
            echo "## Successful Builds"
            echo ""
            echo "| Build ID | Platform | Arch | Suffix | Binary Size |"
            echo "|----------|----------|------|--------|-------------|"

            for build_info in "${SUCCESSFUL_BUILDS[@]}"; do
                IFS=':' read -r build_id platform arch suffix <<< "$build_info"
                local artifact_dir="$ARTIFACTS_DIR/${platform}-${arch}"
                local binary_size
                binary_size=$(du -h "$artifact_dir/zigcat" 2>/dev/null | cut -f1 || echo "N/A")
                echo "| $build_id | $platform | $arch | $suffix | $binary_size |"
            done
            echo ""
        fi

        if [[ ${#FAILED_BUILDS[@]} -gt 0 ]]; then
            echo "## Failed Builds"
            echo ""
            for build_id in "${FAILED_BUILDS[@]}"; do
                echo "- ❌ **$build_id** (see logs/$LOGS_DIR/build-${build_id}.log)"
            done
            echo ""
        fi

        if [[ ${#SKIPPED_BUILDS[@]} -gt 0 ]]; then
            echo "## Skipped Builds"
            echo ""
            for build_id in "${SKIPPED_BUILDS[@]}"; do
                echo "- ⚠️ **$build_id**"
            done
            echo ""
        fi

        echo "## Build Artifacts"
        echo ""
        echo "Artifacts are located in: \`$ARTIFACTS_DIR\`"
        echo ""

        for build_info in "${SUCCESSFUL_BUILDS[@]}"; do
            IFS=':' read -r build_id platform arch suffix <<< "$build_info"
            local artifact_dir="$ARTIFACTS_DIR/${platform}-${arch}"
            echo "- \`${platform}-${arch}/zigcat\`"
        done

        echo ""
        echo "## Next Steps"
        echo ""
        echo "1. Package artifacts:"
        echo "   \`\`\`bash"
        echo "   ./docker-tests/scripts/package-release.sh --version $VERSION --compression 9 --create-deb --create-rpm"
        echo "   \`\`\`"
        echo ""
        echo "2. Generate checksums:"
        echo "   \`\`\`bash"
        echo "   ./docker-tests/scripts/generate-checksums.sh --release-dir docker-tests/artifacts/releases/$VERSION"
        echo "   \`\`\`"
        echo ""
        echo "---"
        echo "*Generated by ZigCat Enhanced Release Build System v2*"

    } > "$report_file"

    log_success "Build report generated: $report_file"
}

# Print summary
print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ZigCat Build Summary - $VERSION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Zig Compiler:      $ZIG_RELEASE_VERSION"
    echo "  Total Platforms:    ${#BUILD_MATRIX[@]}"
    echo "  Successful:         ${#SUCCESSFUL_BUILDS[@]}"
    echo "  Failed:             ${#FAILED_BUILDS[@]}"
    echo "  Skipped:            ${#SKIPPED_BUILDS[@]}"
    echo ""

    if [[ ${#SUCCESSFUL_BUILDS[@]} -gt 0 ]]; then
        echo "  ✅ Successful builds:"
        for build_info in "${SUCCESSFUL_BUILDS[@]}"; do
            IFS=':' read -r build_id platform arch suffix <<< "$build_info"
            local artifact_dir="$ARTIFACTS_DIR/${platform}-${arch}"
            local binary_size
            binary_size=$(du -h "$artifact_dir/zigcat" 2>/dev/null | cut -f1 || echo "N/A")
            printf "     %-30s %8s\n" "$build_id" "$binary_size"
        done
    fi

    echo ""

    if [[ ${#FAILED_BUILDS[@]} -gt 0 ]]; then
        echo "  ❌ Failed builds:"
        for build_id in "${FAILED_BUILDS[@]}"; do
            echo "     - $build_id"
        done
        echo ""
    fi

    echo "  Artifacts: $ARTIFACTS_DIR"
    echo "  Logs:      $LOGS_DIR"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Main function
main() {
    local start_time
    start_time=$(date +%s)

    # Parse arguments
    parse_args "$@"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ZigCat Enhanced Release Build Orchestrator v2"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Detect version if not specified
    detect_version || exit 1

    # Determine Zig compiler version (latest stable unless overridden)
    detect_zig_version

    log_info "Version: $VERSION"
    log_info "Continue on Error: $CONTINUE_ON_ERROR"
    log_info "Zig Compiler: ${ZIG_RELEASE_VERSION:-$DEFAULT_ZIG_VERSION}"
    if [[ -n "$CONFIG_FILE" ]]; then
        log_info "Config File: $CONFIG_FILE"
    fi
    echo ""

    # Load YAML config if specified
    load_yaml_config || exit 1

    # Validate environment
    validate_environment || exit 1

    # Build all platforms
    if build_all_platforms; then
        log_success "All builds completed"
    else
        if [[ "$CONTINUE_ON_ERROR" == "false" ]]; then
            log_error "Build failed"
            exit 1
        fi
    fi

    # Generate build report
    if [[ "$SKIP_BUILD" == "false" ]]; then
        generate_build_report
    fi

    # Print summary
    print_summary

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo "Total build time: ${duration}s"
    echo ""

    # Exit with appropriate code
    if [[ "$SKIP_BUILD" == "false" ]] && [[ ${#SUCCESSFUL_BUILDS[@]} -eq 0 ]]; then
        log_error "No successful builds"
        exit 1
    fi

    if [[ ${#FAILED_BUILDS[@]} -gt 0 ]]; then
        log_warn "Some builds failed, but continuing..."
        exit 0  # Exit 0 if at least one build succeeded
    fi

    log_success "All builds successful!"
    exit 0
}

# Run main
main "$@"
