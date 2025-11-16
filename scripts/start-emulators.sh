#!/bin/bash
# Script to start Firebase emulators for testing
# This script is designed to be run before executing tests that require Firebase

set -e

EMULATOR_LOG_FILE="emulator.log"
EMULATOR_PID_FILE="emulator.pid"

echo "🔥 Starting Firebase Local Emulator Suite..."

# Check if emulators are already running
if [ -f "$EMULATOR_PID_FILE" ]; then
    OLD_PID=$(cat "$EMULATOR_PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "⚠️  Emulators already running (PID: $OLD_PID)"
        echo "   To stop them, run: ./scripts/stop-emulators.sh"
        exit 0
    else
        # Clean up stale PID file
        rm "$EMULATOR_PID_FILE"
    fi
fi

# Start emulators in background
firebase emulators:start --only auth,firestore > "$EMULATOR_LOG_FILE" 2>&1 &
EMULATOR_PID=$!

# Save PID for later cleanup
echo "$EMULATOR_PID" > "$EMULATOR_PID_FILE"

echo "📝 Emulator logs: tail -f $EMULATOR_LOG_FILE"
echo "🔑 Emulator PID: $EMULATOR_PID"

# Wait for emulators to be ready (check for "All emulators ready" message)
echo "⏳ Waiting for emulators to be ready..."
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if grep -q "All emulators ready" "$EMULATOR_LOG_FILE" 2>/dev/null; then
        echo "✅ Firebase emulators are ready!"
        echo ""
        echo "Emulator UI: http://localhost:4000"
        echo "Auth Emulator: http://localhost:9099"
        echo "Firestore Emulator: http://localhost:8080"
        echo ""
        echo "To stop emulators: ./scripts/stop-emulators.sh"
        exit 0
    fi
    
    # Check if process died
    if ! ps -p "$EMULATOR_PID" > /dev/null 2>&1; then
        echo "❌ Emulator process died. Check logs:"
        cat "$EMULATOR_LOG_FILE"
        rm "$EMULATOR_PID_FILE"
        exit 1
    fi
    
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    
    # Show progress every 10 seconds
    if [ $((ELAPSED % 10)) -eq 0 ]; then
        echo "   Still waiting... (${ELAPSED}s elapsed)"
    fi
done

echo "⚠️  Timeout waiting for emulators. Check logs:"
tail -20 "$EMULATOR_LOG_FILE"
exit 1
