#!/bin/bash
# Broker Mode Test - Client 1 (Sender)
set -e

SERVER_IP=172.28.1.10
SERVER_PORT=9001
RESULT_FILE=/results/broker-2client-client1.txt

echo "Client 1: Connecting to broker at $SERVER_IP:$SERVER_PORT..."
sleep 1  # Let client2 connect first

# Send test message
echo "Hello from client1" | zigcat $SERVER_IP $SERVER_PORT > $RESULT_FILE 2>&1 &
CLIENT_PID=$!

# Wait briefly for transmission
sleep 2

# Kill client
kill $CLIENT_PID 2>/dev/null || true

echo "Client 1: Message sent, exiting"
exit 0
