# Docker Tests - Quick Start Guide

## Overview

**Single Docker Compose file**: `docker-tests/docker-compose.yml`
**Single Dockerfile**: `docker-tests/Dockerfile`
**All 7 test scenarios** configured and ready to run

## Quick Test

```bash
# Run all tests (takes ~2-3 minutes)
docker-compose -f docker-tests/docker-compose.yml up --build --abort-on-container-exit

# Run specific test scenario
docker-compose -f docker-tests/docker-compose.yml up --build broker-2client-server broker-2client-client1 broker-2client-client2 --abort-on-container-exit

# Check results
cat docker-tests/results/*.txt
```

## Test Scenarios

All scenarios use the same `docker-tests/Dockerfile`:

1. **Broker Mode - 2 Clients**: Data relay between 2 clients
2. **Broker Mode - 5 Clients**: Concurrent relay with 5 clients
3. **Chat Mode - Nicknames**: Chat with nickname assignment
4. **Chat Mode - Formatting**: Message formatting in chat
5. **Client Disconnection**: Connection cleanup verification
6. **Max Clients - Broker**: Client limit enforcement (broker mode)
7. **Max Clients - Chat**: Client limit enforcement (chat mode)

## File Structure

```
docker-tests/
├── Dockerfile                  # Single working Dockerfile (kassany/alpine-ziglang:0.15.1)
├── docker-compose.yml          # All 7 test scenarios
├── scenarios/                  # Test scenario scripts (10 files)
│   ├── broker-2client-client1.sh
│   ├── broker-2client-client2.sh
│   ├── broker-5client-client.sh
│   ├── chat-nickname-client1.sh
│   ├── chat-nickname-client2.sh
│   ├── chat-format-client1.sh
│   ├── chat-format-client2.sh
│   ├── disconnect-test.sh
│   ├── maxclients-broker-test.sh
│   └── maxclients-chat-test.sh
├── results/                    # Test output (created on first run)
└── scripts/                    # Helper scripts
```

## Dockerfile Details

**Base Image**: `kassany/alpine-ziglang:0.15.1`
- Zig compiler 0.15.1
- Alpine Linux with build tools
- ~100MB compressed

**Build Process**:
```dockerfile
# Stage 1: Build zigcat with Zig
FROM kassany/alpine-ziglang:0.15.1 AS builder
WORKDIR /build
COPY . .
RUN zig build --release=small

# Stage 2: Runtime image
FROM alpine:latest
RUN apk add bash netcat-openbsd curl socat
COPY --from=builder /build/zig-out/bin/zigcat /usr/local/bin/zigcat
COPY docker-tests/scenarios /tests/scenarios
WORKDIR /tests
```

**Final Image Size**: ~30MB (Alpine + zigcat binary + test scripts)

## Running Individual Tests

### Broker Test (2 Clients)

```bash
docker-compose -f docker-tests/docker-compose.yml up \
  broker-2client-server \
  broker-2client-client1 \
  broker-2client-client2 \
  --abort-on-container-exit
```

**Expected Output**:
```
broker-2client-client1  | Client 1: Message sent, exiting
broker-2client-client2  | ✅ PASS: Client 2 received message from client 1
```

**Result File**: `docker-tests/results/broker-2client-result.txt` → `PASS`

### Chat Test (Nicknames)

```bash
docker-compose -f docker-tests/docker-compose.yml up \
  chat-nickname-server \
  chat-nickname-client1 \
  chat-nickname-client2 \
  --abort-on-container-exit
```

### All Tests at Once

```bash
# Run everything (not recommended - takes time)
docker-compose -f docker-tests/docker-compose.yml up --build --abort-on-container-exit

# Better: Run test groups
docker-compose -f docker-tests/docker-compose.yml up broker-* --abort-on-container-exit
docker-compose -f docker-tests/docker-compose.yml up chat-* --abort-on-container-exit
docker-compose -f docker-tests/docker-compose.yml up maxclients-* --abort-on-container-exit
```

## Troubleshooting

### Build Fails

**Problem**: Docker cache issues
**Solution**:
```bash
docker-compose -f docker-tests/docker-compose.yml build --no-cache
```

### Tests Hang

**Problem**: Server not starting
**Solution**: Check logs for specific service
```bash
docker-compose -f docker-tests/docker-compose.yml logs broker-2client-server
```

### Permission Errors

**Problem**: Results directory permissions
**Solution**:
```bash
mkdir -p docker-tests/results
chmod 777 docker-tests/results
```

## Expected Warnings

These messages are **normal** and not errors:

```
Error in client data handling: error.ClientSocketError
```

This occurs when clients disconnect after completing their task. The broker detects the disconnection and logs it.

## Clean Up

```bash
# Stop all containers
docker-compose -f docker-tests/docker-compose.yml down

# Remove all images and volumes
docker-compose -f docker-tests/docker-compose.yml down --rmi all --volumes

# Clean results
rm -rf docker-tests/results/*
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Docker Integration Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Run Docker tests
        run: docker-compose -f docker-tests/docker-compose.yml up --build --abort-on-container-exit

      - name: Check test results
        run: |
          for result in docker-tests/results/*result.txt; do
            if ! grep -q "PASS" "$result"; then
              echo "Test failed: $result"
              exit 1
            fi
          done
```

## Next Steps

1. Run tests locally to verify setup
2. Add to CI/CD pipeline
3. Extend with additional scenarios
4. Add performance benchmarks

## References

- Main Documentation: `docker-tests/README.md`
- Build Solutions: `docker-tests/DOCKER_BUILD_SOLUTION.md`
- Test Results: `docker-tests/TEST_RESULTS.md`
- Zig Docker Image: https://hub.docker.com/r/kassany/alpine-ziglang
