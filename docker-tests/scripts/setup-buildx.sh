#!/bin/bash
# Setup Docker Buildx for multi-architecture support

set -e

BUILDER_NAME="zigcat-multiarch"

echo "Setting up Docker Buildx for multi-architecture builds..."

# Check if Docker Buildx is available
if ! docker buildx version >/dev/null 2>&1; then
    echo "Error: Docker Buildx is not available. Please update Docker to a version that supports Buildx."
    exit 1
fi

# Remove existing builder if it exists
if docker buildx ls | grep -q "$BUILDER_NAME"; then
    echo "Removing existing builder: $BUILDER_NAME"
    docker buildx rm "$BUILDER_NAME" || true
fi

# Create new builder with docker-container driver
echo "Creating new builder: $BUILDER_NAME"
docker buildx create \
    --name "$BUILDER_NAME" \
    --driver docker-container \
    --platform linux/amd64,linux/arm64 \
    --bootstrap

# Use the new builder
echo "Switching to builder: $BUILDER_NAME"
docker buildx use "$BUILDER_NAME"

# Inspect the builder to verify setup
echo "Builder configuration:"
docker buildx inspect "$BUILDER_NAME"

# Test builder capabilities
echo "Testing builder capabilities..."
docker buildx ls

echo "Docker Buildx setup complete!"
echo "Available platforms:"
docker buildx inspect --bootstrap | grep "Platforms:"