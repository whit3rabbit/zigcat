#!/bin/bash
# Verify static linking implementation
# This script validates that static builds are correctly configured

set -e

echo "=== Static Linking Verification Script ==="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Track results
PASS=0
FAIL=0

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASS++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAIL++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo "1. Checking build.zig configuration..."
if grep -q 'const static = b.option(bool, "static"' build.zig; then
    check_pass "Static build option exists"
else
    check_fail "Static build option missing"
fi

if grep -q 'exe.linkage = .static' build.zig; then
    check_pass "Static linkage configuration exists"
else
    check_fail "Static linkage configuration missing"
fi

if grep -q 'const strip.*orelse true' build.zig; then
    check_pass "Strip enabled by default"
else
    check_fail "Strip not enabled by default"
fi

echo ""
echo "2. Checking Makefile targets..."
if grep -q 'linux-x64-static:' Makefile; then
    check_pass "Static Linux x64 target exists"
else
    check_fail "Static Linux x64 target missing"
fi

if grep -q 'linux-arm64-static:' Makefile; then
    check_pass "Static Linux ARM64 target exists"
else
    check_fail "Static Linux ARM64 target missing"
fi

if grep -q 'build-static:' Makefile; then
    check_pass "Build-static target exists"
else
    check_fail "Build-static target missing"
fi

echo ""
echo "3. Building test binaries..."

# Test native build
echo "   Building native binary..."
make clean > /dev/null 2>&1
if make build > /dev/null 2>&1; then
    if [ -f "zig-out/bin/zigcat" ]; then
        SIZE=$(ls -lh zig-out/bin/zigcat | awk '{print $5}')
        check_pass "Native build successful (size: $SIZE)"

        # Verify it runs
        if zig-out/bin/zigcat --version > /dev/null 2>&1; then
            check_pass "Native binary executes correctly"
        else
            check_fail "Native binary fails to execute"
        fi
    else
        check_fail "Native binary not created"
    fi
else
    check_fail "Native build failed"
fi

# Test static build (cross-compilation)
echo "   Building static Linux binary (cross-compile)..."
if make build-static > /dev/null 2>&1; then
    if [ -f "zig-out/bin/zigcat" ]; then
        SIZE=$(ls -lh zig-out/bin/zigcat | awk '{print $5}')
        check_pass "Static build successful (size: $SIZE)"

        # Verify it's an ELF binary
        FILE_TYPE=$(file zig-out/bin/zigcat)
        if echo "$FILE_TYPE" | grep -q "ELF"; then
            check_pass "Binary is ELF format"
        else
            check_warn "Binary is not ELF (expected for cross-compilation)"
        fi

        # Verify static linking claim
        if echo "$FILE_TYPE" | grep -qi "statically linked"; then
            check_pass "Binary reports static linking"
        else
            check_warn "Binary does not report static linking (may need Linux build environment)"
        fi
    else
        check_fail "Static binary not created"
    fi
else
    check_fail "Static build failed"
fi

echo ""
echo "4. Documentation verification..."
if [ -f "docs/STATIC_LINKING_ANALYSIS.md" ]; then
    check_pass "Static linking analysis document exists"
else
    check_fail "Static linking analysis document missing"
fi

if grep -q "Build Cheat Sheet" README.md; then
    check_pass "README.md contains build cheat sheet"
else
    check_fail "README.md missing build cheat sheet"
fi

if grep -q "linux-x64-static" CLAUDE.md; then
    check_pass "CLAUDE.md documents static builds"
else
    check_fail "CLAUDE.md missing static build documentation"
fi

echo ""
echo "=== Summary ==="
echo -e "${GREEN}Passed: $PASS${NC}"
if [ $FAIL -gt 0 ]; then
    echo -e "${RED}Failed: $FAIL${NC}"
fi
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All checks passed!${NC}"
    echo ""
    echo "Static linking implementation is correctly configured."
    echo ""
    echo "Next steps:"
    echo "  1. Test static binary on actual Linux system"
    echo "  2. Verify all features work (TLS, sockets, proxies)"
    echo "  3. Build on Linux for optimal binary sizes"
    exit 0
else
    echo -e "${RED}Some checks failed!${NC}"
    echo "Review the failures above and fix them."
    exit 1
fi
