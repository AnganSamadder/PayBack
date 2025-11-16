#!/bin/bash
# Comprehensive test script that runs tests with Firebase emulator
# This script:
# 1. Starts Firebase emulators
# 2. Runs all tests (unit + integration)
# 3. Stops emulators
# 4. Generates coverage report

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "🧪 PayBack Test Suite with Firebase Integration"
echo "=============================================="
echo ""

# Configuration
RUN_EMULATOR_TESTS=${RUN_EMULATOR_TESTS:-true}
EMULATOR_TIMEOUT=30
TEST_TIMEOUT=600

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if emulators are running
check_emulators() {
    if curl -s http://localhost:9099 > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to start emulators
start_emulators() {
    echo "🔥 Starting Firebase Local Emulator Suite..."
    
    if check_emulators; then
        echo "✅ Emulators already running"
        return 0
    fi
    
    # Start emulators in background
    firebase emulators:start --only auth,firestore > emulator.log 2>&1 &
    EMULATOR_PID=$!
    echo "$EMULATOR_PID" > emulator.pid
    
    echo "⏳ Waiting for emulators to be ready..."
    ELAPSED=0
    while [ $ELAPSED -lt $EMULATOR_TIMEOUT ]; do
        if check_emulators; then
            echo "✅ Firebase emulators are ready!"
            echo ""
            return 0
        fi
        
        if ! ps -p "$EMULATOR_PID" > /dev/null 2>&1; then
            echo -e "${RED}❌ Emulator process died. Check logs:${NC}"
            tail -50 emulator.log
            return 1
        fi
        
        sleep 1
        ELAPSED=$((ELAPSED + 1))
    done
    
    echo -e "${RED}❌ Timeout waiting for emulators${NC}"
    tail -50 emulator.log
    return 1
}

# Function to stop emulators
stop_emulators() {
    if [ -f emulator.pid ]; then
        EMULATOR_PID=$(cat emulator.pid)
        if ps -p "$EMULATOR_PID" > /dev/null 2>&1; then
            echo "🛑 Stopping Firebase emulators..."
            kill "$EMULATOR_PID" 2>/dev/null || true
            rm emulator.pid
        fi
    fi
}

# Trap to ensure cleanup on exit
trap 'stop_emulators' EXIT INT TERM

# Change to project directory
cd "$PROJECT_DIR"

# Step 1: Start emulators if needed
if [ "$RUN_EMULATOR_TESTS" = "true" ]; then
    if ! start_emulators; then
        echo -e "${RED}❌ Failed to start emulators${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠️  Skipping emulator tests (RUN_EMULATOR_TESTS=false)${NC}"
fi

# Step 2: Run tests
echo "🧪 Running test suite..."
echo ""

TEST_RESULT=0

if command -v gtimeout > /dev/null; then
    TIMEOUT_CMD="gtimeout $TEST_TIMEOUT"
else
    TIMEOUT_CMD="timeout $TEST_TIMEOUT"
fi

# Run tests with xcpretty if available
if command -v xcpretty > /dev/null; then
    $TIMEOUT_CMD xcodebuild test \
        -scheme PayBack \
        -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max,OS=18.3' \
        -enableCodeCoverage YES \
        -resultBundlePath ./TestResults.xcresult 2>&1 | xcpretty --color || TEST_RESULT=$?
else
    $TIMEOUT_CMD xcodebuild test \
        -scheme PayBack \
        -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max,OS=18.3' \
        -enableCodeCoverage YES \
        -resultBundlePath ./TestResults.xcresult || TEST_RESULT=$?
fi

echo ""

# Step 3: Generate coverage report
if [ $TEST_RESULT -eq 0 ]; then
    echo "📊 Generating coverage report..."
    echo ""
    
    # Extract coverage data
    if [ -d "TestResults.xcresult" ]; then
        xcrun xccov view --report --json TestResults.xcresult > coverage.json
        
        # Generate human-readable report with Python script
        if [ -f "scripts/generate_coverage_report.py" ]; then
            python3 scripts/generate_coverage_report.py
        else
            echo -e "${YELLOW}⚠️  Coverage report script not found${NC}"
        fi
        
        # Display summary
        if [ -f "coverage-report.txt" ]; then
            echo ""
            echo "Coverage Summary:"
            echo "================="
            tail -10 coverage-report.txt
        fi
    else
        echo -e "${YELLOW}⚠️  No test results found for coverage${NC}"
    fi
fi

# Step 4: Report results
echo ""
echo "=============================================="
if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
    echo ""
    echo "Next steps:"
    echo "  • Review coverage report: cat coverage-report.txt"
    echo "  • View detailed results: open TestResults.xcresult"
    if [ "$RUN_EMULATOR_TESTS" = "true" ]; then
        echo "  • View emulator logs: tail -f emulator.log"
    fi
    exit 0
else
    echo -e "${RED}❌ Tests failed${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  • Check test output above for failures"
    echo "  • View detailed results: open TestResults.xcresult"
    if [ "$RUN_EMULATOR_TESTS" = "true" ]; then
        echo "  • Check emulator logs: tail -50 emulator.log"
    fi
    exit 1
fi
