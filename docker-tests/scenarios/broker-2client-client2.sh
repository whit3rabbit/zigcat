#!/bin/bash
# Broker Mode Test - Client 2 (Receiver)
set -e

SERVER_IP=172.28.1.10
SERVER_PORT=9001
RESULT_FILE=/results/broker-2client-client2.txt

echo "Client 2: Connecting to broker at $SERVER_IP:$SERVER_PORT..."

# Connect and receive data (timeout after 5 seconds)
timeout 5 zigcat $SERVER_IP $SERVER_PORT > $RESULT_FILE 2>&1 || true

# Verify we received the message
if grep -q "Hello from client1" $RESULT_FILE; then
    echo "✅ PASS: Client 2 received message from client 1"
    echo "PASS" > /results/broker-2client-result.txt
    exit 0
else
    echo "❌ FAIL: Client 2 did not receive expected message"
    echo "FAIL" > /results/broker-2client-result.txt
    exit 1
fi
