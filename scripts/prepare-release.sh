#!/usr/bin/env bash
#
# Prepare Release Script for Zigcat
#
# This script prepares a new release by:
# 1. Validating the version in build.zig
# 2. Running the full test suite
# 3. Creating a git tag
# 4. Providing instructions to trigger the release workflow
#
# Usage:
#   ./scripts/prepare-release.sh <version>
#   ./scripts/prepare-release.sh v0.1.0

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check if version argument is provided
if [[ $# -ne 1 ]]; then
    log_error "Usage: $0 <version>"
    log_info "Example: $0 v0.1.0"
    exit 1
fi

VERSION="$1"

# Ensure version starts with 'v'
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "Version must be in format: vX.Y.Z (e.g., v0.1.0)"
    exit 1
fi

# Extract version without 'v' prefix
VERSION_NUMBER="${VERSION#v}"

log_info "Preparing release: $VERSION"
echo ""

# Step 1: Check if we're in the project root
cd "$PROJECT_ROOT"
if [[ ! -f "build.zig" ]]; then
    log_error "build.zig not found. Are you in the project root?"
    exit 1
fi

# Step 2: Check git status
log_info "Checking git status..."
if [[ -n $(git status --porcelain) ]]; then
    log_error "Working directory is not clean. Commit or stash changes first."
    git status --short
    exit 1
fi
log_success "Working directory is clean"

# Step 3: Verify version in build.zig
log_info "Verifying version in build.zig..."
BUILD_VERSION=$(grep 'options.addOption.*"version"' build.zig | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')

if [[ "$BUILD_VERSION" != "$VERSION_NUMBER" ]]; then
    log_error "Version mismatch!"
    log_error "  build.zig: $BUILD_VERSION"
    log_error "  Requested: $VERSION_NUMBER"
    echo ""
    log_info "Please update the version in build.zig (line ~231):"
    echo "  options.addOption([]const u8, \"version\", \"$VERSION_NUMBER\");"
    exit 1
fi
log_success "Version verified: $VERSION_NUMBER"

# Step 4: Check if tag already exists
log_info "Checking if tag already exists..."
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    log_error "Tag $VERSION already exists!"
    log_info "To delete: git tag -d $VERSION"
    log_info "To delete remotely: git push origin :refs/tags/$VERSION"
    exit 1
fi
log_success "Tag $VERSION does not exist"

# Step 5: Run full test suite
log_info "Running full test suite..."
echo ""

TEST_SUITES=(
    "test"
    "test-timeout"
    "test-udp"
    "test-zero-io"
    "test-quit-eof"
    "test-platform"
    "test-portscan-features"
    "test-validation"
    "test-ssl"
)

FAILED_TESTS=()

for suite in "${TEST_SUITES[@]}"; do
    log_info "Running: zig build $suite"
    if ! timeout 300 zig build "$suite" >/dev/null 2>&1; then
        log_error "Test suite failed: $suite"
        FAILED_TESTS+=("$suite")
    else
        log_success "Passed: $suite"
    fi
done

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo ""
    log_error "Some tests failed:"
    for failed in "${FAILED_TESTS[@]}"; do
        echo "  - $failed"
    done
    echo ""
    log_info "Run manually to see details: zig build <test-suite>"
    exit 1
fi

log_success "All tests passed!"
echo ""

# Step 6: Build release binary (verify it compiles)
log_info "Building release binary (verification)..."
if ! zig build -Dstrip=true >/dev/null 2>&1; then
    log_error "Release build failed!"
    exit 1
fi
log_success "Release build successful"
echo ""

# Step 7: Generate changelog preview
log_info "Generating changelog preview..."
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [[ -n "$PREV_TAG" ]]; then
    echo ""
    echo "Changes since $PREV_TAG:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    git log --pretty=format:"  - %s (%h)" "$PREV_TAG"..HEAD
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    log_info "No previous tags found - this will be the initial release"
fi
echo ""

# Step 8: Confirm release
log_warn "Ready to create release $VERSION"
echo ""
echo "This will:"
echo "  1. Create git tag: $VERSION"
echo "  2. Push tag to origin"
echo "  3. Trigger GitHub Actions release workflow"
echo ""
read -p "Continue? (y/N): " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Release cancelled"
    exit 0
fi

# Step 9: Create and push tag
log_info "Creating git tag: $VERSION"
git tag -a "$VERSION" -m "Release $VERSION"
log_success "Tag created"

log_info "Pushing tag to origin..."
git push origin "$VERSION"
log_success "Tag pushed"

echo ""
log_success "Release $VERSION initiated!"
echo ""
echo "Next steps:"
echo "  1. GitHub Actions will automatically build all platform binaries"
echo "  2. Monitor progress at: https://github.com/$(git remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')/actions"
echo "  3. Release will be created at: https://github.com/$(git remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')/releases"
echo ""
log_info "If you need to trigger manually:"
echo "  gh workflow run release.yml -f tag=$VERSION"
echo ""
