#!/bin/bash
# Run a single test scenario
set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <test-name>"
    echo
    echo "Available tests:"
    echo "  broker-2client       - Broker Mode 2 Clients Data Relay"
    echo "  broker-5client       - Broker Mode 5 Clients Concurrent Relay"
    echo "  chat-nickname        - Chat Mode Nickname Assignment"
    echo "  chat-format          - Chat Mode Message Formatting"
    echo "  disconnect           - Client Disconnection Cleanup"
    echo "  maxclients-broker    - Maximum Client Limit (Broker)"
    echo "  maxclients-chat      - Maximum Client Limit (Chat)"
    exit 1
fi

TEST_NAME=$1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/docker-tests/results"

mkdir -p "$RESULTS_DIR"
cd "$PROJECT_ROOT"

echo "Building Docker image..."
docker-compose -f docker-tests/docker-compose.yml build --quiet

echo "Running test: $TEST_NAME"
docker-compose -f docker-tests/docker-compose.yml up \
    --abort-on-container-exit \
    ${TEST_NAME}-server ${TEST_NAME}-client1 ${TEST_NAME}-client2

docker-compose -f docker-tests/docker-compose.yml down --remove-orphans --volumes

# Show results
RESULT_FILE="$RESULTS_DIR/${TEST_NAME}-result.txt"
if [ -f "$RESULT_FILE" ]; then
    echo
    echo "Test result:"
    cat "$RESULT_FILE"
fi
