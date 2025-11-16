#!/bin/bash
# Script to stop Firebase emulators

EMULATOR_PID_FILE="emulator.pid"

if [ ! -f "$EMULATOR_PID_FILE" ]; then
    echo "⚠️  No emulator PID file found. Emulators may not be running."
    exit 0
fi

EMULATOR_PID=$(cat "$EMULATOR_PID_FILE")

if ps -p "$EMULATOR_PID" > /dev/null 2>&1; then
    echo "🛑 Stopping Firebase emulators (PID: $EMULATOR_PID)..."
    kill "$EMULATOR_PID"
    rm "$EMULATOR_PID_FILE"
    echo "✅ Emulators stopped"
else
    echo "⚠️  Emulator process not running"
    rm "$EMULATOR_PID_FILE"
fi
