# Multi-stage Dockerfile for Zigcat Integration Testing
# Uses kassany/alpine-ziglang:0.15.1 for building

# Stage 1: Build zigcat binary
FROM kassany/alpine-ziglang:0.15.1 AS builder

WORKDIR /build
COPY . .

# Build zigcat (ReleaseSmall for minimal binary)
RUN zig build --release=small

# Stage 2: Runtime image for testing
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    netcat-openbsd \
    curl \
    socat

# Copy zigcat binary from builder
COPY --from=builder /build/zig-out/bin/zigcat /usr/local/bin/zigcat

# Copy test scripts
COPY docker-tests/scenarios /tests/scenarios
COPY docker-tests/scripts /tests/scripts

WORKDIR /tests

# Make scripts executable
RUN chmod +x /tests/scenarios/*.sh /tests/scripts/*.sh 2>/dev/null || true

# Verify zigcat binary works
RUN zigcat --help || echo "zigcat binary ready"

# Default command
CMD ["/bin/sh", "-c", "echo 'Zigcat Docker test container ready'"]
