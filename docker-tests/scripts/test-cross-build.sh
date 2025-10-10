#!/bin/bash
# Test cross-platform build capabilities with sample builds

set -e

BUILDER_NAME="zigcat-multiarch"
TEST_DIR="$(dirname "$0")/.."
DOCKERFILE_DIR="$TEST_DIR/dockerfiles"

echo "Testing cross-platform build capabilities..."

# Ensure we're using the correct builder
docker buildx use "$BUILDER_NAME" 2>/dev/null || {
    echo "Builder $BUILDER_NAME not found. Running setup first..."
    "$TEST_DIR/scripts/setup-buildx.sh"
}

# Test platforms to build for
PLATFORMS=(
    "linux/amd64"
    "linux/arm64"
)

# Test each platform with each Dockerfile
DOCKERFILES=(
    "Dockerfile.linux"
    "Dockerfile.alpine"
)

for dockerfile in "${DOCKERFILES[@]}"; do
    echo "Testing $dockerfile..."
    
    for platform in "${PLATFORMS[@]}"; do
        echo "  Building for platform: $platform"
        
        # Build only the builder stage to test compilation
        docker buildx build \
            --platform "$platform" \
            --target builder \
            --file "$DOCKERFILE_DIR/$dockerfile" \
            --progress plain \
            --no-cache \
            . || {
            echo "    ❌ Failed to build $dockerfile for $platform"
            continue
        }
        
        echo "    ✅ Successfully built $dockerfile for $platform"
    done
done

# Test FreeBSD build (amd64 only since it's cross-compiled)
echo "Testing Dockerfile.freebsd for linux/amd64 (cross-compiling to FreeBSD)..."
docker buildx build \
    --platform "linux/amd64" \
    --target builder \
    --file "$DOCKERFILE_DIR/Dockerfile.freebsd" \
    --progress plain \
    --no-cache \
    . && echo "    ✅ Successfully cross-compiled for FreeBSD" || echo "    ❌ Failed to cross-compile for FreeBSD"

echo "Cross-platform build test complete!"