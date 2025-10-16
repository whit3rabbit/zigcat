# Makefile for zigcat

ZIG = zig
BUILD_FILE = build.zig

# x86_64 Targets (64-bit)
TARGET_LINUX_X64 = x86_64-linux-gnu
TARGET_MACOS_X64 = x86_64-macos-none
TARGET_WINDOWS_X64 = x86_64-windows-gnu
TARGET_FREEBSD_X64 = x86_64-freebsd-gnu

# x86 Targets (32-bit)
TARGET_LINUX_X86 = x86-linux-gnu
TARGET_WINDOWS_X86 = x86-windows-gnu

# ARM Targets
TARGET_LINUX_ARM64 = aarch64-linux-gnu
TARGET_MACOS_ARM64 = aarch64-macos-none
TARGET_LINUX_ARM = arm-linux-gnueabihf

# Other BSD Targets
TARGET_OPENBSD_X64 = x86_64-openbsd-none
TARGET_NETBSD_X64 = x86_64-netbsd-none

# Build directory
BUILD_DIR = zig-out/bin
BIN_NAME = zigcat

.PHONY: all build build-small build-static build-no-tls build-with-tls clean cross-compile \
	linux-x64 linux-x86 linux-arm64 linux-arm \
	linux-x64-static linux-x86-static linux-arm64-static linux-arm-static \
	macos-x64 macos-arm64 \
	windows-x64 windows-x86 \
	freebsd-x64 openbsd-x64 netbsd-x64 \
	bsd all-bsd all-x86 all-x86-static help check-size man deb rpm \
	release-all release-linux release-alpine release-bsd release-macos \
	release-checksums release-package release-validate release-clean

all: build

# Help target
help:
	@echo "Zigcat Build Targets:"
	@echo ""
	@echo "Native builds:"
	@echo "  make build                  - Build for current platform (with TLS)"
	@echo "  make build-small            - Build with symbols stripped (with TLS)"
	@echo "  make build-static           - Build static binary (Linux only, NO TLS)"
	@echo "  make build-no-tls           - Build without TLS support"
	@echo "  make build-with-tls         - Build with OpenSSL TLS support (explicit)"
	@echo ""
	@echo "Cross-compilation (Linux 64-bit):"
	@echo "  make linux-x64              - x86_64-linux (dynamic)"
	@echo "  make linux-arm64            - aarch64-linux (dynamic)"
	@echo "  make linux-x64-static       - x86_64-linux-musl (static, NO TLS)"
	@echo "  make linux-arm64-static     - aarch64-linux-musl (static, NO TLS)"
	@echo ""
	@echo "Cross-compilation (Linux 32-bit):"
	@echo "  make linux-x86              - x86-linux (dynamic, 32-bit)"
	@echo "  make linux-arm              - arm-linux (dynamic, 32-bit)"
	@echo "  make linux-x86-static       - x86-linux-musl (static, 32-bit, NO TLS)"
	@echo "  make linux-arm-static       - arm-linux-musl (static, 32-bit, NO TLS)"
	@echo ""
	@echo "Cross-compilation (other platforms):"
	@echo "  make macos-x64 macos-arm64  - macOS targets"
	@echo "  make windows-x64 windows-x86 - Windows targets"
	@echo "  make freebsd-x64            - FreeBSD target"
	@echo "  make bsd                    - All BSD targets"
	@echo "  make all-x86-static         - All 32-bit and 64-bit static builds"
	@echo ""
	@echo "Utilities:"
	@echo "  make cross-compile          - Build linux-x64, macos-x64, windows-x64"
	@echo "  make check-size             - Show size of all built binaries"
	@echo "  make deb                    - Build Debian package (dpkg-buildpackage)"
	@echo "  make rpm                    - Build RPM package (rpmbuild)"
	@echo "  make clean                  - Remove build artifacts"
	@echo ""
	@echo "Release builds (via Docker):"
	@echo "  make release-all            - Build all release artifacts (Linux, Alpine, BSD)"
	@echo "  make release-linux          - Build all Linux variants (glibc, musl, musl+wolfSSL)"
	@echo "  make release-alpine         - Build Alpine static+wolfSSL (~835KB smallest)"
	@echo "  make release-bsd            - Build FreeBSD variants"
	@echo "  make release-macos          - Build macOS variants (requires native macOS)"
	@echo "  make release-package        - Package artifacts into tarballs"
	@echo "  make release-checksums      - Generate SHA256SUMS"
	@echo "  make release-validate       - Validate all release binaries"
	@echo "  make release-clean          - Clean release artifacts"

build:
	$(ZIG) build

build-small:
	$(ZIG) build -Dstrip=true

build-static:
	@echo "Building static binary (Linux/musl, NO TLS)..."
	@echo "Note: Static builds have TLS disabled for true portability"
	$(ZIG) build -Dtarget=x86_64-linux-musl -Dstrip=true -Dstatic=true -Dtls=false
	@echo "Binary: $(BUILD_DIR)/$(BIN_NAME)"
	@ls -lh $(BUILD_DIR)/$(BIN_NAME)
	@file $(BUILD_DIR)/$(BIN_NAME) | grep -i static || echo "Note: Static linking requires Linux target"
	@echo "Verifying binary has no dynamic dependencies..."
	@ldd $(BUILD_DIR)/$(BIN_NAME) 2>&1 | grep -q "not a dynamic executable" && echo "✓ Verified: True static binary (no dependencies)" || echo "⚠ Warning: Binary may have dynamic dependencies"

# TLS-specific builds
build-no-tls:
	@echo "Building without TLS support..."
	$(ZIG) build -Dtls=false -Dstrip=true
	@echo "Binary: $(BUILD_DIR)/$(BIN_NAME)"
	@ls -lh $(BUILD_DIR)/$(BIN_NAME)

build-with-tls:
	@echo "Building with OpenSSL TLS support..."
	$(ZIG) build -Dtls=true -Dstrip=true
	@echo "Binary: $(BUILD_DIR)/$(BIN_NAME)"
	@ls -lh $(BUILD_DIR)/$(BIN_NAME)
	@echo "Note: Requires OpenSSL installed (brew install openssl on macOS)"

# Cross-compilation targets (x64 default)
cross-compile: linux-x64 macos-x64 windows-x64

# Linux targets
linux-x64:
	$(ZIG) build -Dtarget=$(TARGET_LINUX_X64) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-linux-x64

linux-x86:
	$(ZIG) build -Dtarget=$(TARGET_LINUX_X86) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-linux-x86

linux-arm64:
	$(ZIG) build -Dtarget=$(TARGET_LINUX_ARM64) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-linux-arm64

linux-arm:
	$(ZIG) build -Dtarget=$(TARGET_LINUX_ARM) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-linux-arm

# Static Linux targets (musl - NO TLS for true portability)
linux-x64-static:
	@echo "Building x86_64-linux-musl (static, NO TLS)..."
	$(ZIG) build -Dtarget=x86_64-linux-musl -Dstrip=true -Dstatic=true -Dtls=false
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-linux-x64-static
	@file $(BUILD_DIR)/$(BIN_NAME)-linux-x64-static
	@ls -lh $(BUILD_DIR)/$(BIN_NAME)-linux-x64-static
	@echo "Verifying static linkage..."
	@ldd $(BUILD_DIR)/$(BIN_NAME)-linux-x64-static 2>&1 | grep -q "not a dynamic executable" && echo "✓ True static binary" || echo "⚠ Has dynamic dependencies"

linux-arm64-static:
	@echo "Building aarch64-linux-musl (static, NO TLS)..."
	$(ZIG) build -Dtarget=aarch64-linux-musl -Dstrip=true -Dstatic=true -Dtls=false
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-linux-arm64-static
	@file $(BUILD_DIR)/$(BIN_NAME)-linux-arm64-static
	@ls -lh $(BUILD_DIR)/$(BIN_NAME)-linux-arm64-static
	@echo "Note: Verification requires ARM64 system"

# Static 32-bit Linux targets (musl - NO TLS)
linux-x86-static:
	@echo "Building x86-linux-musl (static, 32-bit, NO TLS)..."
	$(ZIG) build -Dtarget=x86-linux-musl -Dstrip=true -Dstatic=true -Dtls=false
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-linux-x86-static
	@file $(BUILD_DIR)/$(BIN_NAME)-linux-x86-static
	@ls -lh $(BUILD_DIR)/$(BIN_NAME)-linux-x86-static

linux-arm-static:
	@echo "Building arm-linux-musleabihf (static, 32-bit ARM, NO TLS)..."
	$(ZIG) build -Dtarget=arm-linux-musleabihf -Dstrip=true -Dstatic=true -Dtls=false
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-linux-arm-static
	@file $(BUILD_DIR)/$(BIN_NAME)-linux-arm-static
	@ls -lh $(BUILD_DIR)/$(BIN_NAME)-linux-arm-static

# macOS targets
macos-x64:
	$(ZIG) build -Dtarget=$(TARGET_MACOS_X64) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-macos-x64

macos-arm64:
	$(ZIG) build -Dtarget=$(TARGET_MACOS_ARM64) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-macos-arm64

# Windows targets
windows-x64:
	$(ZIG) build -Dtarget=$(TARGET_WINDOWS_X64) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-windows-x64.exe

windows-x86:
	$(ZIG) build -Dtarget=$(TARGET_WINDOWS_X86) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-windows-x86.exe

# BSD targets
freebsd-x64:
	$(ZIG) build -Dtarget=$(TARGET_FREEBSD_X64) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-freebsd-x64

openbsd-x64:
	$(ZIG) build -Dtarget=$(TARGET_OPENBSD_X64) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-openbsd-x64

netbsd-x64:
	$(ZIG) build -Dtarget=$(TARGET_NETBSD_X64) -Dstrip=true
	mv $(BUILD_DIR)/$(BIN_NAME) $(BUILD_DIR)/$(BIN_NAME)-netbsd-x64

# Convenience targets
bsd: freebsd-x64 openbsd-x64 netbsd-x64

all-bsd: bsd

all-x86: linux-x86 windows-x86

# Build all static x86 variants (32-bit and 64-bit)
all-x86-static: linux-x86-static linux-x64-static

# Check size of all built binaries
check-size:
	@echo "Binary sizes:"
	@find $(BUILD_DIR) -name "$(BIN_NAME)*" -type f -exec ls -lh {} \; | awk '{print $$9 ": " $$5}'

deb:
	@echo "Building Debian package..."
	./scripts/build-deb.sh

rpm:
	@echo "Building RPM package..."
	./scripts/build-rpm.sh

man:
	man ./zigcat.1

clean:
	rm -rf zig-out
	rm -rf zig-cache

# ==============================================================================
# Release Build Targets (via docker-tests system)
# ==============================================================================

# Build all release artifacts (Linux glibc, musl, Alpine wolfSSL, FreeBSD)
release-all:
	@echo "Building all release artifacts..."
	./docker-tests/scripts/build-release.sh \
		--config docker-tests/configs/releases/release-all.yml \
		--parallel \
		--verbose

# Build all Linux variants (glibc dynamic+TLS, musl static)
release-linux:
	@echo "Building Linux release variants..."
	./docker-tests/scripts/build-release.sh \
		--config docker-tests/configs/releases/release-linux.yml \
		--parallel \
		--verbose

# Build Alpine static+wolfSSL (smallest build ~835KB)
release-alpine:
	@echo "Building Alpine wolfSSL release (smallest with TLS)..."
	./docker-tests/scripts/build-release.sh \
		--config docker-tests/configs/releases/release-alpine.yml \
		--verbose

# Build FreeBSD variants
release-bsd:
	@echo "Building BSD release variants..."
	./docker-tests/scripts/build-release.sh \
		--config docker-tests/configs/releases/release-bsd.yml \
		--verbose

# Build macOS variants (REQUIRES NATIVE MACOS)
release-macos:
	@echo "Building macOS release variants (native build required)..."
	@if [ "$$(uname)" != "Darwin" ]; then \
		echo "ERROR: macOS builds must be run on native macOS system"; \
		exit 1; \
	fi
	./docker-tests/scripts/build-release.sh \
		--config docker-tests/configs/releases/release-macos.yml \
		--native \
		--verbose

# Package existing artifacts into tarballs
release-package:
	@echo "Packaging release artifacts..."
	./docker-tests/scripts/package-artifacts.sh \
		--artifacts-dir docker-tests/artifacts \
		--verbose

# Generate SHA256 checksums
release-checksums:
	@echo "Generating SHA256 checksums..."
	@if [ -z "$$(ls -A docker-tests/artifacts/releases/*/zigcat-*.tar.gz 2>/dev/null)" ]; then \
		echo "ERROR: No release tarballs found. Run 'make release-all' first."; \
		exit 1; \
	fi
	./docker-tests/scripts/generate-checksums.sh \
		--release-dir "$$(ls -d docker-tests/artifacts/releases/v* | head -1)" \
		--verbose

# Validate release binaries
release-validate:
	@echo "Validating release binaries..."
	./docker-tests/scripts/validate-releases.sh \
		--artifacts-dir docker-tests/artifacts \
		--verbose

# Clean release artifacts
release-clean:
	@echo "Cleaning release artifacts..."
	rm -rf docker-tests/artifacts/releases/*
	@echo "Release artifacts cleaned"
