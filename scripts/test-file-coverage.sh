#!/bin/bash

################################################################################
# File-Specific Coverage Analysis Script
#
# This script analyzes test coverage for a specific source file with extremely
# detailed output showing exactly which lines need tests and why.
#
# USAGE:
#   Basic usage:
#     ./scripts/test-file-coverage.sh apps/ios/PayBack/Sources/Services/AppStore.swift
#
#   Verbose mode (shows covered lines, execution counts, build output):
#     ./scripts/test-file-coverage.sh apps/ios/PayBack/Sources/Services/AppStore.swift -v
#
#   Run only specific test file (faster iteration):
#     ./scripts/test-file-coverage.sh apps/ios/PayBack/Sources/Services/AppStore.swift --test-file AppStoreTests
#
#   Run all tests matching a pattern (use wildcards):
#     ./scripts/test-file-coverage.sh apps/ios/PayBack/Sources/Services/AppStore.swift --test-file "AppStore*"
#
#   Generate HTML report with syntax highlighting:
#     ./scripts/test-file-coverage.sh apps/ios/PayBack/Sources/Services/AppStore.swift --html
#
#   Combine options:
#     ./scripts/test-file-coverage.sh apps/ios/PayBack/Sources/Services/AppStore.swift -v --test-file AppStoreTests --html
#
# REQUIREMENTS:
#   - Xcode command line tools installed
#   - Project must build successfully
#   - Tests must exist for the target file
#
# OUTPUT:
#   The script generates a detailed report with the following sections:
#   - HEADER: File being analyzed, timestamp, test run status
#   - SUMMARY: Overall coverage %, line counts, function counts
#   - UNCOVERED LINES: Exact line numbers with code snippets
#   - PARTIALLY COVERED LINES: Lines with missing branch coverage
#   - FUNCTION BREAKDOWN: Each function with coverage % and line ranges
#   - UNCOVERED CODE BLOCKS: Grouped consecutive uncovered lines
#   - ERROR HANDLING GAPS: Uncovered catch blocks, throws, guards
#   - EDGE CASE GAPS: Uncovered nil checks, boundary conditions
#   - RECOMMENDATIONS: Suggested test scenarios with method names
#
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Parse command line arguments
SOURCE_FILE=""
VERBOSE=false
TEST_FILE_FILTER=""
GENERATE_HTML=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --test-file)
            TEST_FILE_FILTER="$2"
            shift 2
            ;;
        --html)
            GENERATE_HTML=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <source-file-path> [-v|--verbose] [--test-file <test-file-name>] [--html]"
            echo ""
            echo "Options:"
            echo "  -v, --verbose          Show detailed output including covered lines"
            echo "  --test-file <name>     Run only specific test file (e.g., AppStoreTests)"
            echo "  --html                 Generate HTML coverage report"
            echo "  -h, --help             Show this help message"
            echo ""
            echo "Example:"
            echo "  $0 apps/ios/PayBack/Sources/Services/AppStore.swift -v --test-file AppStoreTests"
            exit 0
            ;;
        *)
            if [[ -z "$SOURCE_FILE" ]]; then
                SOURCE_FILE="$1"
            else
                echo -e "${RED}Error: Unknown argument '$1'${NC}"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate source file argument
if [[ -z "$SOURCE_FILE" ]]; then
    echo -e "${RED}Error: Source file path is required${NC}"
    echo "Usage: $0 <source-file-path> [-v|--verbose] [--test-file <test-file-name>] [--html]"
    echo ""
    echo "Example:"
    echo "  $0 apps/ios/PayBack/Sources/Services/AppStore.swift"
    echo ""
    echo "Suggested paths:"
    echo "  apps/ios/PayBack/Sources/Services/AppStore.swift"
    echo "  apps/ios/PayBack/Sources/Services/Auth/AccountServiceProvider.swift"
    echo "  apps/ios/PayBack/Sources/Services/GroupCloudService.swift"
    exit 1
fi

# Check if source file exists
if [[ ! -f "$SOURCE_FILE" ]]; then
    echo -e "${RED}Error: File not found: $SOURCE_FILE${NC}"
    echo ""
    echo "Please check the file path. Common locations:"
    echo "  PayBack/Services/"
    echo "  PayBack/Services/Auth/"
    echo "  PayBack/Features/"
    echo "  PayBack/DesignSystem/"
    exit 1
fi

# Extract file name without path and extension
FILE_NAME=$(basename "$SOURCE_FILE" .swift)
FILE_PATH="$SOURCE_FILE"

echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  File-Specific Coverage Analysis${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Target File:${NC} $SOURCE_FILE"
echo -e "${BOLD}Analysis Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
if [[ -n "$TEST_FILE_FILTER" ]]; then
    echo -e "${BOLD}Test Filter:${NC} $TEST_FILE_FILTER"
fi
echo ""

# Build and test with coverage
echo -e "${BOLD}${BLUE}▶ Running tests with coverage...${NC}"
echo ""

XCRESULT_PATH="build/test-results.xcresult"
rm -rf "$XCRESULT_PATH"

# Find the latest available iOS simulator (matching CI behavior)
SIMULATOR_INFO=$(python3 <<'PY'
import json
import subprocess
import sys

def parse_runtime(runtime: str):
  if ".iOS-" not in runtime:
    return (), ""
  version_raw = runtime.split(".iOS-")[-1].replace("-", ".")
  parts = []
  for token in version_raw.split('.'):
    token = ''.join(ch for ch in token if ch.isdigit()) or '0'
    parts.append(int(token))
  return tuple(parts), version_raw

def get_device_priority(name: str):
  # Extract iPhone number for prioritization
  if "Pro Max" in name:
    base_priority = 1000
  elif "Pro" in name:
    base_priority = 900
  elif "Plus" in name:
    base_priority = 800
  elif "Air" in name:
    base_priority = 700
  elif "SE" in name:
    base_priority = 100
  else:
    base_priority = 500
  
  # Extract model number (e.g., "16" from "iPhone 16 Pro Max")
  parts = name.split()
  model_number = 0
  for part in parts:
    if part.isdigit():
      model_number = int(part)
      break
  
  return base_priority + model_number

def pick_latest(candidates):
  # Sort by iOS version (descending), then device priority (descending)
  def sorter(entry):
    version_tuple, name, udid, version_str = entry
    device_priority = get_device_priority(name)
    # Return tuple: (iOS version tuple for sorting, device priority, name)
    return (version_tuple, device_priority, name)
  
  sorted_candidates = sorted(candidates, key=sorter, reverse=True)
  return sorted_candidates[0]

try:
  result = subprocess.check_output([
    "xcrun", "simctl", "list", "devices", "available", "--json"
  ])
except subprocess.CalledProcessError as exc:
  print(f"ERROR: Failed to list simulators: {exc}", file=sys.stderr)
  sys.exit(1)

data = json.loads(result)
candidates = []
for runtime, devices in data.get("devices", {}).items():
  version_tuple, version_str = parse_runtime(runtime)
  if not version_tuple:
    continue
  for device in devices:
    if not device.get("isAvailable"):
      continue
    name = device.get("name", "")
    if "iPhone" not in name:
      continue
    udid = device.get("udid")
    if not udid:
      continue
    candidates.append((version_tuple, name, udid, version_str))

if not candidates:
  print("ERROR: No available iPhone simulator found", file=sys.stderr)
  sys.exit(1)

# Pick the latest iOS version with highest priority device
version_tuple, name, udid, version_str = pick_latest(candidates)
print(f"{name}:::{version_str}")
PY
)

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to select simulator${NC}"
    exit 1
fi

LATEST_SIM_NAME=$(echo "$SIMULATOR_INFO" | awk -F':::' '{print $1}')
SIMULATOR_OS=$(echo "$SIMULATOR_INFO" | awk -F':::' '{print $2}')

echo -e "${BOLD}Using simulator:${NC} $LATEST_SIM_NAME (iOS $SIMULATOR_OS)"
echo ""

# Check if Firebase emulator is needed and start it
EMULATOR_STARTED=false
EMULATOR_PID=""
EMULATOR_LOG_FILE="/tmp/firebase-emulator-$$.log"

# Function to cleanup Firebase emulator
cleanup_emulator() {
    if [[ "$EMULATOR_STARTED" == true ]]; then
        echo ""
        echo -e "${BOLD}${BLUE}▶ Stopping Firebase emulator...${NC}"
        
        # Kill the main process
        if [[ -n "$EMULATOR_PID" ]]; then
            kill $EMULATOR_PID 2>/dev/null || true
            # Wait a moment for graceful shutdown
            sleep 2
        fi
        
        # Force kill any remaining Firebase processes
        pkill -f "firebase.*emulators" 2>/dev/null || true
        pkill -f "java.*firestore" 2>/dev/null || true
        
        # Clean up log file
        rm -f "$EMULATOR_LOG_FILE" 2>/dev/null || true
        
        echo -e "${GREEN}✓ Firebase emulator stopped${NC}"
    fi
}

# Set trap to cleanup on exit
trap cleanup_emulator EXIT INT TERM

# Check if the test file or source file requires Firebase emulator
# (tests that use Firestore, Auth, or other Firebase services)
NEEDS_FIREBASE=false

if [[ "$SOURCE_FILE" == *"CloudService"* ]] || \
   [[ "$SOURCE_FILE" == *"AccountService"* ]] || \
   [[ "$SOURCE_FILE" == *"Auth"* ]] || \
   [[ "$SOURCE_FILE" == *"InviteLink"* ]] || \
   [[ "$TEST_FILE_FILTER" == *"Firestore"* ]] || \
   [[ "$TEST_FILE_FILTER" == *"Cloud"* ]] || \
   [[ "$TEST_FILE_FILTER" == *"Account"* ]] || \
   [[ "$TEST_FILE_FILTER" == *"Auth"* ]] || \
   [[ "$TEST_FILE_FILTER" == *"Coverage"* ]] || \
   [[ "$TEST_FILE_FILTER" == *"Integration"* ]]; then
    NEEDS_FIREBASE=true
fi

if [[ "$NEEDS_FIREBASE" == true ]]; then
    echo -e "${BOLD}${BLUE}▶ Checking Firebase emulator...${NC}"
    
    # Check if emulator is already running
    if lsof -Pi :8080 -sTCP:LISTEN -t >/dev/null 2>&1 && lsof -Pi :9099 -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Firebase emulator already running${NC}"
        echo "  - Auth emulator: http://localhost:9099"
        echo "  - Firestore emulator: http://localhost:8080"
    else
        echo -e "${YELLOW}Starting Firebase emulator...${NC}"
        
        # Check if Firebase CLI is installed
        if ! command -v firebase &> /dev/null; then
            echo -e "${RED}✗ Firebase CLI not found${NC}"
            echo ""
            echo "Install it with:"
            echo "  curl -sL https://firebase.tools | bash"
            echo ""
            exit 1
        fi
        
        # Start emulator in background with logging
        firebase emulators:start --only auth,firestore --project demo-test > "$EMULATOR_LOG_FILE" 2>&1 &
        EMULATOR_PID=$!
        EMULATOR_STARTED=true
        
        # Wait for emulator to be ready (check ports and HTTP endpoints)
        echo -n "Waiting for emulator to start"
        EMULATOR_READY=false
        
        for i in {1..60}; do
            # Check if process is still running
            if ! kill -0 $EMULATOR_PID 2>/dev/null; then
                echo ""
                echo -e "${RED}✗ Firebase emulator process died${NC}"
                echo ""
                echo "Last 20 lines of emulator log:"
                tail -20 "$EMULATOR_LOG_FILE" 2>/dev/null || echo "No log available"
                exit 1
            fi
            
            # Check if ports are listening
            if lsof -Pi :8080 -sTCP:LISTEN -t >/dev/null 2>&1 && \
               lsof -Pi :9099 -sTCP:LISTEN -t >/dev/null 2>&1; then
                # Verify HTTP endpoints are responding
                if curl -s http://localhost:9099/ >/dev/null 2>&1 && \
                   curl -s http://localhost:8080/ >/dev/null 2>&1; then
                    EMULATOR_READY=true
                    break
                fi
            fi
            
            echo -n "."
            sleep 1
        done
        
        echo ""
        
        if [[ "$EMULATOR_READY" == true ]]; then
            echo -e "${GREEN}✓ Firebase emulator started successfully${NC}"
            echo "  - Auth emulator: http://localhost:9099"
            echo "  - Firestore emulator: http://localhost:8080"
            echo "  - Emulator UI: http://localhost:4000"
        else
            echo -e "${RED}✗ Firebase emulator failed to start within 60 seconds${NC}"
            echo ""
            echo "Last 20 lines of emulator log:"
            tail -20 "$EMULATOR_LOG_FILE" 2>/dev/null || echo "No log available"
            echo ""
            echo "Try starting manually:"
            echo "  firebase emulators:start --only auth,firestore --project demo-test"
            exit 1
        fi
    fi
    echo ""
fi

# Build test command - disable parallel testing to avoid simulator crashes
TEST_CMD="xcodebuild test \
    -scheme PayBackTests \
    -destination 'platform=iOS Simulator,name=$LATEST_SIM_NAME' \
    -enableCodeCoverage YES \
    -resultBundlePath $XCRESULT_PATH \
    -parallel-testing-enabled NO"

# Add test filter if specified
if [[ -n "$TEST_FILE_FILTER" ]]; then
    # Support wildcards by finding matching test classes
    if [[ "$TEST_FILE_FILTER" == *"*"* ]]; then
        # Find all matching test classes
        PATTERN=$(echo "$TEST_FILE_FILTER" | sed 's/\*/.*/')
        MATCHING_TESTS=$(find apps/ios/PayBack/Tests -name "*.swift" -type f -exec basename {} .swift \; | grep -E "^${PATTERN}$" | sort || true)
        
        if [[ -n "$MATCHING_TESTS" ]]; then
            TEST_COUNT=$(echo "$MATCHING_TESTS" | wc -l | xargs)
            echo -e "${BOLD}Found $TEST_COUNT matching test classes:${NC}"
            echo "$MATCHING_TESTS" | sed 's/^/  - /'
            echo ""
            
            while IFS= read -r test_class; do
                TEST_CMD="$TEST_CMD -only-testing:PayBackTests/$test_class"
            done <<< "$MATCHING_TESTS"
        else
            echo -e "${YELLOW}Warning: No test classes found matching pattern '$TEST_FILE_FILTER'${NC}"
            echo "Running all tests instead..."
        fi
    else
        TEST_CMD="$TEST_CMD -only-testing:PayBackTests/$TEST_FILE_FILTER"
    fi
fi

# Run tests and capture output
TEST_OUTPUT_FILE=$(mktemp)
TEST_FAILED=false

if [[ "$VERBOSE" == true ]]; then
    echo -e "${YELLOW}Running: $TEST_CMD${NC}"
    echo ""
    if ! eval "$TEST_CMD" 2>&1 | tee "$TEST_OUTPUT_FILE"; then
        TEST_FAILED=true
    fi
else
    if ! eval "$TEST_CMD" > "$TEST_OUTPUT_FILE" 2>&1; then
        TEST_FAILED=true
    fi
fi

# Extract test failures for summary
FAILED_TESTS=$(grep -E "error:.*failed|Test Case.*failed|Fatal error" "$TEST_OUTPUT_FILE" | head -20 || true)
TEST_SUMMARY=$(grep -E "Executed.*tests.*with.*failure" "$TEST_OUTPUT_FILE" | tail -1 || true)

if [[ "$TEST_FAILED" == true ]]; then
    echo -e "${RED}✗ Tests failed${NC}"
    echo ""
else
    echo -e "${GREEN}✓ Tests completed${NC}"
    echo ""
fi

# Check if xcresult exists
if [[ ! -d "$XCRESULT_PATH" ]]; then
    echo -e "${RED}Error: Test results not found at $XCRESULT_PATH${NC}"
    exit 1
fi

# Extract coverage data
echo -e "${BOLD}${BLUE}▶ Extracting coverage data...${NC}"
echo ""

# Get coverage report - try multiple times with different approaches
COVERAGE_JSON=""
ATTEMPT=1
MAX_ATTEMPTS=3

while [[ -z "$COVERAGE_JSON" ]] && [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
    if [[ $ATTEMPT -gt 1 ]]; then
        echo -e "${YELLOW}Retry attempt $ATTEMPT of $MAX_ATTEMPTS...${NC}"
        sleep 2
    fi
    
    COVERAGE_JSON=$(xcrun xccov view --report --json "$XCRESULT_PATH" 2>&1)
    
    # Check if output is valid JSON
    if echo "$COVERAGE_JSON" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
        break
    else
        COVERAGE_JSON=""
        ((ATTEMPT++))
    fi
done

if [[ -z "$COVERAGE_JSON" ]]; then
    echo -e "${RED}Error: Failed to extract coverage data after $MAX_ATTEMPTS attempts${NC}"
    echo ""
    echo "Trying alternative method..."
    
    # Try using xccov without JSON flag
    COVERAGE_TEXT=$(xcrun xccov view --report "$XCRESULT_PATH" 2>&1)
    
    if [[ -n "$COVERAGE_TEXT" ]]; then
        echo -e "${YELLOW}Using text-based coverage report${NC}"
        
        # Extract coverage percentage for the target file
        FILE_COVERAGE_LINE=$(echo "$COVERAGE_TEXT" | grep "$FILE_NAME.swift" | head -1)
        
        if [[ -n "$FILE_COVERAGE_LINE" ]]; then
            # Parse the coverage percentage from the line
            COVERAGE_PCT=$(echo "$FILE_COVERAGE_LINE" | grep -oE '[0-9]+\.[0-9]+%' | head -1 | tr -d '%')
            
            if [[ -n "$COVERAGE_PCT" ]]; then
                echo ""
                echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${BOLD}${CYAN}  COVERAGE SUMMARY${NC}"
                echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "${BOLD}File:${NC} $SOURCE_FILE"
                echo -e "${BOLD}Coverage:${NC} ${COVERAGE_PCT}%"
                echo ""
                
                # Show the full line for context
                echo -e "${BOLD}Details:${NC}"
                echo "$FILE_COVERAGE_LINE"
                echo ""
                
                # Show test status
                if [[ "$TEST_FAILED" == true ]]; then
                    echo -e "${RED}✗ Tests failed - coverage may be incomplete${NC}"
                else
                    echo -e "${GREEN}✓ Tests passed${NC}"
                fi
                echo ""
                
                echo -e "${YELLOW}Note: Detailed line-by-line coverage not available${NC}"
                echo -e "${YELLOW}Run 'xcrun xccov view --file $FILE_PATH $XCRESULT_PATH' for details${NC}"
                echo ""
                
                exit 0
            fi
        fi
    fi
    
    echo -e "${RED}Could not extract coverage data${NC}"
    echo ""
    echo "This may indicate:"
    echo "  - Coverage was not enabled during test run"
    echo "  - xcresult bundle is corrupted"
    echo "  - xccov tool is not available"
    echo "  - File was not executed during tests"
    echo ""
    echo "Try running manually:"
    echo "  xcrun xccov view --report $XCRESULT_PATH"
    exit 1
fi

# Parse coverage for target file
FILE_COVERAGE=$(echo "$COVERAGE_JSON" | python3 -c "
import sys, json

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print('JSON_PARSE_ERROR', file=sys.stderr)
    sys.exit(1)

def find_file(targets, target_path):
    for target in targets:
        if 'files' in target:
            for file in target['files']:
                if target_path in file.get('path', ''):
                    return file
        if 'targets' in target:
            result = find_file(target['targets'], target_path)
            if result:
                return result
    return None

target_path = '$FILE_PATH'
file_data = find_file(data.get('targets', []), target_path)

if file_data:
    print(json.dumps(file_data, indent=2))
else:
    print('FILE_NOT_FOUND')
" 2>&1)

if [[ "$FILE_COVERAGE" == *"FILE_NOT_FOUND"* ]] || [[ "$FILE_COVERAGE" == *"JSON_PARSE_ERROR"* ]] || [[ -z "$FILE_COVERAGE" ]]; then
    echo -e "${RED}Error: Coverage data not found for $SOURCE_FILE${NC}"
    echo ""
    echo "Possible reasons:"
    echo "  - File path may be incorrect"
    echo "  - File may not be in the main target"
    echo "  - File may not have been executed during tests"
    echo ""
    echo "Attempting fallback method..."
    
    # Try direct xccov view for the file
    DIRECT_COVERAGE=$(xcrun xccov view --file "$FILE_PATH" "$XCRESULT_PATH" 2>&1)
    
    if [[ -n "$DIRECT_COVERAGE" ]]; then
        # Extract coverage percentage from the output
        COVERAGE_LINE=$(echo "$DIRECT_COVERAGE" | head -1)
        COVERAGE_PCT=$(echo "$COVERAGE_LINE" | grep -oE '[0-9]+\.[0-9]+%' | head -1 | tr -d '%')
        
        if [[ -n "$COVERAGE_PCT" ]]; then
            # Count lines
            TOTAL_LINES=$(echo "$DIRECT_COVERAGE" | grep -E "^\s+[0-9]+:" | wc -l | xargs)
            COVERED_LINES=$(echo "$DIRECT_COVERAGE" | grep -E "^\s+[0-9]+:\s+[1-9]" | wc -l | xargs)
            UNCOVERED_LINES=$(echo "$DIRECT_COVERAGE" | grep -E "^\s+[0-9]+:\s+0\*?" | wc -l | xargs)
            
            echo -e "${GREEN}✓ Coverage data extracted using fallback method${NC}"
            echo ""
            
            echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}${CYAN}  COVERAGE SUMMARY${NC}"
            echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "${BOLD}File:${NC} $SOURCE_FILE"
            echo -e "${BOLD}Coverage:${NC} ${COVERAGE_PCT}%"
            echo ""
            echo -e "${BOLD}Line Statistics:${NC}"
            echo -e "  Total Executable Lines: $TOTAL_LINES"
            echo -e "  Covered Lines:          $COVERED_LINES"
            echo -e "  Uncovered Lines:        ${RED}$UNCOVERED_LINES${NC}"
            echo ""
            
            if [[ "$VERBOSE" == true ]]; then
                echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${BOLD}${CYAN}  DETAILED LINE COVERAGE${NC}"
                echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo "$DIRECT_COVERAGE"
                echo ""
            fi
            
            echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}${CYAN}  FINAL SUMMARY${NC}"
            echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "${BOLD}File:${NC} $FILE_NAME"
            echo -e "${BOLD}Coverage:${NC} ${COVERAGE_PCT}%"
            echo -e "${BOLD}Uncovered Lines:${NC} ${RED}$UNCOVERED_LINES${NC}"
            echo ""
            
            if (( $(echo "$COVERAGE_PCT >= 95" | bc -l) )); then
                echo -e "${GREEN}✓ EXCELLENT COVERAGE (≥95%)${NC}"
            elif (( $(echo "$COVERAGE_PCT >= 90" | bc -l) )); then
                echo -e "${YELLOW}◐ GOOD COVERAGE (90-95%)${NC}"
            elif (( $(echo "$COVERAGE_PCT >= 80" | bc -l) )); then
                echo -e "${YELLOW}◐ ACCEPTABLE COVERAGE (80-90%)${NC}"
            else
                echo -e "${RED}✗ NEEDS IMPROVEMENT (<80%)${NC}"
            fi
            echo ""
            
            exit 0
        fi
    fi
    
    echo "This may indicate:"
    echo "  - File is not included in the target"
    echo "  - File path is incorrect"
    echo "  - No code in the file was executed during tests"
    echo ""
    echo "Try running manually:"
    echo "  xcrun xccov view --file $FILE_PATH $XCRESULT_PATH"
    exit 1
fi

echo -e "${GREEN}✓ Coverage data extracted${NC}"
echo ""

# Verify FILE_COVERAGE contains valid JSON before parsing
if ! echo "$FILE_COVERAGE" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
    echo -e "${RED}Error: FILE_COVERAGE does not contain valid JSON${NC}"
    echo ""
    echo "FILE_COVERAGE content (first 500 chars):"
    echo "$FILE_COVERAGE" | head -c 500
    echo ""
    echo ""
    echo "Attempting fallback method..."
    
    # Try direct xccov view for the file
    DIRECT_COVERAGE=$(xcrun xccov view --file "$FILE_PATH" "$XCRESULT_PATH" 2>&1)
    
    if [[ -n "$DIRECT_COVERAGE" ]]; then
        COVERAGE_LINE=$(echo "$DIRECT_COVERAGE" | head -1)
        COVERAGE_PCT=$(echo "$COVERAGE_LINE" | grep -oE '[0-9]+\.[0-9]+%' | head -1 | tr -d '%')
        
        if [[ -n "$COVERAGE_PCT" ]]; then
            TOTAL_LINES=$(echo "$DIRECT_COVERAGE" | grep -E "^\s+[0-9]+:" | wc -l | xargs)
            COVERED_LINES=$(echo "$DIRECT_COVERAGE" | grep -E "^\s+[0-9]+:\s+[1-9]" | wc -l | xargs)
            UNCOVERED_LINES=$(echo "$DIRECT_COVERAGE" | grep -E "^\s+[0-9]+:\s+0\*?" | wc -l | xargs)
            
            echo -e "${GREEN}✓ Using fallback method${NC}"
            echo ""
            echo -e "${BOLD}File:${NC} $SOURCE_FILE"
            echo -e "${BOLD}Coverage:${NC} ${COVERAGE_PCT}%"
            echo -e "${BOLD}Covered Lines:${NC} $COVERED_LINES"
            echo -e "${BOLD}Uncovered Lines:${NC} ${RED}$UNCOVERED_LINES${NC}"
            echo ""
            exit 0
        fi
    fi
    
    echo -e "${RED}Fallback method also failed${NC}"
    exit 1
fi

# Parse coverage statistics and line-by-line data
# Note: Using json.loads() instead of json.load(sys.stdin) because heredoc conflicts with pipe
COVERAGE_STATS=$(python3 -c "
import sys, json

file_coverage = '''$FILE_COVERAGE'''

try:
    file_data = json.loads(file_coverage)
except json.JSONDecodeError as e:
    print(f'ERROR: Failed to parse JSON: {e}', file=sys.stderr)
    sys.exit(1)

# Extract basic stats
coverage_pct = file_data.get('lineCoverage', 0) * 100
covered_lines = file_data.get('coveredLines', 0)
executable_lines = file_data.get('executableLines', 0)
uncovered_lines = executable_lines - covered_lines

# Extract functions
functions = file_data.get('functions', [])
function_count = len(functions)

# Print summary stats
print(f'COVERAGE_PCT={coverage_pct:.2f}')
print(f'COVERED_LINES={covered_lines}')
print(f'EXECUTABLE_LINES={executable_lines}')
print(f'UNCOVERED_LINES={uncovered_lines}')
print(f'FUNCTION_COUNT={function_count}')

# Extract line-by-line coverage
print('LINE_COVERAGE_START')
for func in functions:
    func_name = func.get('name', 'unknown')
    func_coverage = func.get('lineCoverage', 0) * 100
    func_exec_lines = func.get('executableLines', 0)
    func_covered = func.get('coveredLines', 0)
    line_number = func.get('lineNumber', 0)
    
    print(f'FUNCTION|{func_name}|{func_coverage:.1f}|{line_number}|{func_exec_lines}|{func_covered}')

print('LINE_COVERAGE_END')
")

# Parse the stats
COVERAGE_PCT=$(echo "$COVERAGE_STATS" | grep "COVERAGE_PCT=" | cut -d'=' -f2)
COVERED_LINES=$(echo "$COVERAGE_STATS" | grep "COVERED_LINES=" | cut -d'=' -f2)
EXECUTABLE_LINES=$(echo "$COVERAGE_STATS" | grep "EXECUTABLE_LINES=" | cut -d'=' -f2)
UNCOVERED_LINES=$(echo "$COVERAGE_STATS" | grep "UNCOVERED_LINES=" | cut -d'=' -f2)
FUNCTION_COUNT=$(echo "$COVERAGE_STATS" | grep "FUNCTION_COUNT=" | cut -d'=' -f2)

# Display summary section
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  SUMMARY${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}File:${NC} $SOURCE_FILE"
echo -e "${BOLD}Overall Coverage:${NC} ${COVERAGE_PCT}%"
echo ""
echo -e "${BOLD}Line Statistics:${NC}"
echo -e "  Total Executable Lines: $EXECUTABLE_LINES"
echo -e "  Covered Lines:          $COVERED_LINES"
echo -e "  Uncovered Lines:        ${RED}$UNCOVERED_LINES${NC}"
echo ""
echo -e "${BOLD}Function Statistics:${NC}"
echo -e "  Total Functions:        $FUNCTION_COUNT"
echo ""

# ═══════════════════════════════════════════════════════════════
# TOP UNCOVERED FUNCTIONS - Show immediately after summary
# ═══════════════════════════════════════════════════════════════

if [[ "$UNCOVERED_LINES" -gt 0 ]]; then
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}  TOP 10 FUNCTIONS NEEDING COVERAGE${NC}"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Extract function data from COVERAGE_STATS
    FUNCTION_DATA=$(echo "$COVERAGE_STATS" | sed -n '/LINE_COVERAGE_START/,/LINE_COVERAGE_END/p' | grep "^FUNCTION|")
    
    if [[ -n "$FUNCTION_DATA" ]]; then
        # Extract and sort functions by uncovered lines
        UNCOVERED_FUNCTIONS=$(echo "$FUNCTION_DATA" | while IFS='|' read -r _ func_name func_cov line_num exec_lines cov_lines; do
            if [[ -n "$func_name" ]] && [[ "$exec_lines" -gt 0 ]]; then
                uncov=$((exec_lines - cov_lines))
                if [[ "$uncov" -gt 0 ]]; then
                    printf "%03d|%s|%.1f%%|%d\n" "$uncov" "$func_name" "$func_cov" "$line_num"
                fi
            fi
        done | sort -rn | head -10)
        
        if [[ -n "$UNCOVERED_FUNCTIONS" ]]; then
            echo -e "${BOLD}Function Name                                    Line    Coverage  Uncovered${NC}"
            echo "─────────────────────────────────────────────────────────────────────────────"
            
            echo "$UNCOVERED_FUNCTIONS" | while IFS='|' read -r uncov_count func_name func_cov line_num; do
                # Truncate long function names
                short_name=$(echo "$func_name" | cut -c 1-45)
                if [[ ${#func_name} -gt 45 ]]; then
                    short_name="${short_name}..."
                fi
                
                printf "%-48s %-7s %-9s ${RED}%s lines${NC}\n" "$short_name" "$line_num" "$func_cov" "$uncov_count"
            done
            echo ""
            
            echo -e "${YELLOW}💡 Focus on functions with most uncovered lines for maximum impact${NC}"
            echo ""
        fi
    else
        echo -e "${YELLOW}⚠ Function details not available${NC}"
        echo ""
    fi
fi

# Get detailed line coverage from xccov
echo -e "${BOLD}${BLUE}▶ Analyzing line-by-line coverage...${NC}"
echo ""

# Try to find the full path in the coverage data
FULL_FILE_PATH=$(echo "$COVERAGE_JSON" | python3 -c "
import sys, json
data = json.loads('''$COVERAGE_JSON''')

def find_file_path(targets, target_path):
    for target in targets:
        if 'files' in target:
            for file in target['files']:
                if target_path in file.get('path', ''):
                    return file.get('path', '')
        if 'targets' in target:
            result = find_file_path(target['targets'], target_path)
            if result:
                return result
    return ''

print(find_file_path(data.get('targets', []), '$FILE_PATH'))
" 2>/dev/null)

if [[ -z "$FULL_FILE_PATH" ]]; then
    FULL_FILE_PATH="$FILE_PATH"
fi

DETAILED_COVERAGE=$(xcrun xccov view --file "$FULL_FILE_PATH" "$XCRESULT_PATH" 2>&1)

# Check if detailed coverage extraction failed
if [[ "$DETAILED_COVERAGE" == *"Error"* ]] || [[ "$DETAILED_COVERAGE" == *"unrecognized"* ]]; then
    echo -e "${YELLOW}⚠ Could not extract detailed line coverage${NC}"
    echo -e "${YELLOW}  Reason: File path format issue${NC}"
    echo ""
    
    # Skip detailed analysis and show summary only
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  FINAL SUMMARY${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}File:${NC} $FILE_NAME"
    echo -e "${BOLD}Coverage:${NC} ${COVERAGE_PCT}%"
    echo -e "${BOLD}Lines Covered:${NC} $COVERED_LINES / $EXECUTABLE_LINES"
    echo -e "${BOLD}Lines Needing Tests:${NC} ${RED}$UNCOVERED_LINES${NC}"
    echo ""
    
    if (( $(echo "$COVERAGE_PCT >= 95" | bc -l) )); then
        echo -e "${GREEN}✓ EXCELLENT COVERAGE (≥95%)${NC}"
    elif (( $(echo "$COVERAGE_PCT >= 90" | bc -l) )); then
        echo -e "${YELLOW}◐ GOOD COVERAGE (90-95%)${NC}"
    elif (( $(echo "$COVERAGE_PCT >= 80" | bc -l) )); then
        echo -e "${YELLOW}◐ ACCEPTABLE COVERAGE (80-90%)${NC}"
    else
        echo -e "${RED}✗ NEEDS IMPROVEMENT (<80%)${NC}"
    fi
    echo ""
    
    echo -e "${BOLD}Recommendation:${NC}"
    echo "  Run: xcrun xccov view --file \"$FULL_FILE_PATH\" \"$XCRESULT_PATH\""
    echo "  to see detailed line-by-line coverage"
    echo ""
    
    exit 0
fi

# Read source file
SOURCE_CONTENT=$(cat "$SOURCE_FILE")

# Extract uncovered lines
UNCOVERED_LINE_NUMBERS=$(echo "$DETAILED_COVERAGE" | grep -E "^\s+[0-9]+:\s+0\*?" | awk '{print $1}' | tr -d ':' || true)

# Display uncovered lines section
if [[ -n "$UNCOVERED_LINE_NUMBERS" ]]; then
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  UNCOVERED LINES${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}The following lines are NOT covered by tests:${NC}"
    echo ""
    
    LINE_NUM=1
    while IFS= read -r line; do
        if echo "$UNCOVERED_LINE_NUMBERS" | grep -q "^${LINE_NUM}$"; then
            echo -e "${RED}Line $LINE_NUM:${NC} $line"
        fi
        ((LINE_NUM++))
    done <<< "$SOURCE_CONTENT"
    echo ""
else
    echo -e "${GREEN}✓ All executable lines are covered!${NC}"
    echo ""
fi

# Display function breakdown
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  FUNCTION BREAKDOWN${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

FUNCTION_DATA=$(echo "$COVERAGE_STATS" | sed -n '/LINE_COVERAGE_START/,/LINE_COVERAGE_END/p' | grep "^FUNCTION|")

if [[ -n "$FUNCTION_DATA" ]]; then
    echo -e "${BOLD}Coverage by function:${NC}"
    echo ""
    
    while IFS='|' read -r _ func_name func_cov line_num exec_lines cov_lines; do
        if [[ -n "$func_name" ]]; then
            uncov=$((exec_lines - cov_lines))
            if (( $(echo "$func_cov < 100" | bc -l) )); then
                echo -e "${YELLOW}$func_name${NC} (Line $line_num)"
                echo -e "  Coverage: ${func_cov}% ($cov_lines/$exec_lines lines covered, ${RED}$uncov uncovered${NC})"
            else
                echo -e "${GREEN}$func_name${NC} (Line $line_num)"
                echo -e "  Coverage: ${func_cov}% (${GREEN}fully covered${NC})"
            fi
            echo ""
        fi
    done <<< "$FUNCTION_DATA"
else
    echo -e "${YELLOW}No function data available${NC}"
    echo ""
fi

# Analyze error handling gaps
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  ERROR HANDLING GAPS${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

ERROR_HANDLING_GAPS=$(
    LINE_NUM=1
    while IFS= read -r line; do
        if echo "$UNCOVERED_LINE_NUMBERS" | grep -q "^${LINE_NUM}$"; then
            if echo "$line" | grep -qE "(catch|throw|guard|fatalError|precondition)"; then
                echo "Line $LINE_NUM: $line"
            fi
        fi
        ((LINE_NUM++))
    done <<< "$SOURCE_CONTENT"
)

if [[ -n "$ERROR_HANDLING_GAPS" ]]; then
    echo -e "${YELLOW}Uncovered error handling code:${NC}"
    echo ""
    echo "$ERROR_HANDLING_GAPS" | while read -r gap_line; do
        echo -e "${RED}  $gap_line${NC}"
    done
    echo ""
else
    echo -e "${GREEN}✓ All error handling paths are covered${NC}"
    echo ""
fi

# Analyze edge case gaps
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  EDGE CASE GAPS${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

EDGE_CASE_GAPS=$(
    LINE_NUM=1
    while IFS= read -r line; do
        if echo "$UNCOVERED_LINE_NUMBERS" | grep -q "^${LINE_NUM}$"; then
            if echo "$line" | grep -qE "(\?|!|isEmpty|count|nil|\.first|\.last|== 0|!= 0)"; then
                echo "Line $LINE_NUM: $line"
            fi
        fi
        ((LINE_NUM++))
    done <<< "$SOURCE_CONTENT"
)

if [[ -n "$EDGE_CASE_GAPS" ]]; then
    echo -e "${YELLOW}Uncovered edge cases (nil checks, boundary conditions):${NC}"
    echo ""
    echo "$EDGE_CASE_GAPS" | while read -r gap_line; do
        echo -e "${RED}  $gap_line${NC}"
    done
    echo ""
else
    echo -e "${GREEN}✓ All edge cases are covered${NC}"
    echo ""
fi

# Recommendations
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  RECOMMENDATIONS${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [[ "$UNCOVERED_LINES" -gt 0 ]]; then
    echo -e "${BOLD}Suggested test scenarios to improve coverage:${NC}"
    echo ""
    
    # Analyze uncovered functions
    while IFS='|' read -r _ func_name func_cov line_num exec_lines cov_lines; do
        if [[ -n "$func_name" ]] && (( $(echo "$func_cov < 90" | bc -l) )); then
            # Generate test method name
            test_method=$(echo "$func_name" | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/__*/_/g')
            echo -e "${YELLOW}  • Add test: test_${test_method}_successScenario()${NC}"
            echo -e "    Target: $func_name (currently ${func_cov}% covered)"
            echo ""
        fi
    done <<< "$FUNCTION_DATA"
    
    if [[ -n "$ERROR_HANDLING_GAPS" ]]; then
        echo -e "${YELLOW}  • Add error handling tests for uncovered catch/throw/guard statements${NC}"
        echo ""
    fi
    
    if [[ -n "$EDGE_CASE_GAPS" ]]; then
        echo -e "${YELLOW}  • Add edge case tests for nil checks and boundary conditions${NC}"
        echo ""
    fi
else
    echo -e "${GREEN}✓ Excellent coverage! No additional tests recommended.${NC}"
    echo ""
fi

# Final summary
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  ANALYSIS COMPLETE${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Coverage:${NC} ${COVERAGE_PCT}%"
echo -e "${BOLD}Status:${NC} $UNCOVERED_LINES lines need tests"
echo ""

if (( $(echo "$COVERAGE_PCT >= 95" | bc -l) )); then
    echo -e "${GREEN}✓ Target coverage achieved (≥95%)${NC}"
elif (( $(echo "$COVERAGE_PCT >= 90" | bc -l) )); then
    echo -e "${YELLOW}⚠ Close to target (90-95%)${NC}"
else
    echo -e "${RED}✗ Below target coverage (<90%)${NC}"
fi
echo ""

# ═══════════════════════════════════════════════════════════════
# TOP UNCOVERED FUNCTIONS - Always show this
# ═══════════════════════════════════════════════════════════════

if [[ "$UNCOVERED_LINES" -gt 0 ]]; then
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}  TOP 10 FUNCTIONS NEEDING COVERAGE${NC}"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Extract and sort functions by uncovered lines
    UNCOVERED_FUNCTIONS=$(echo "$FUNCTION_DATA" | while IFS='|' read -r _ func_name func_cov line_num exec_lines cov_lines; do
        if [[ -n "$func_name" ]] && [[ "$exec_lines" -gt 0 ]]; then
            uncov=$((exec_lines - cov_lines))
            if [[ "$uncov" -gt 0 ]]; then
                printf "%03d|%s|%.1f%%|%d\n" "$uncov" "$func_name" "$func_cov" "$line_num"
            fi
        fi
    done | sort -rn | head -10)
    
    if [[ -n "$UNCOVERED_FUNCTIONS" ]]; then
        echo -e "${BOLD}Function Name                                    Line    Coverage  Uncovered${NC}"
        echo "─────────────────────────────────────────────────────────────────────────────"
        
        echo "$UNCOVERED_FUNCTIONS" | while IFS='|' read -r uncov_count func_name func_cov line_num; do
            # Truncate long function names
            short_name=$(echo "$func_name" | cut -c 1-45)
            if [[ ${#func_name} -gt 45 ]]; then
                short_name="${short_name}..."
            fi
            
            printf "%-48s %-7s %-9s ${RED}%s lines${NC}\n" "$short_name" "$line_num" "$func_cov" "$uncov_count"
        done
        echo ""
        
        echo -e "${YELLOW}💡 Tip: Focus on functions with most uncovered lines for maximum impact${NC}"
        echo ""
    else
        echo -e "${GREEN}✓ All functions have good coverage!${NC}"
        echo ""
    fi
fi

# ═══════════════════════════════════════════════════════════════
# FINAL SUMMARY - Easy to read at a glance
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                        FINAL SUMMARY${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Test Results
if [[ "$TEST_FAILED" == true ]]; then
    echo -e "${RED}✗ TEST STATUS: FAILED${NC}"
    echo ""
    if [[ -n "$TEST_SUMMARY" ]]; then
        echo -e "${BOLD}Test Summary:${NC}"
        echo "$TEST_SUMMARY"
        echo ""
    fi
    
    if [[ -n "$FAILED_TESTS" ]]; then
        echo -e "${BOLD}Failed Tests:${NC}"
        echo "$FAILED_TESTS" | sed 's/^/  /'
        echo ""
    fi
else
    echo -e "${GREEN}✓ TEST STATUS: PASSED${NC}"
    if [[ -n "$TEST_SUMMARY" ]]; then
        echo "  $TEST_SUMMARY"
    fi
    echo ""
fi

# Coverage Results
echo -e "${BOLD}COVERAGE RESULTS:${NC}"
echo -e "  File: ${CYAN}$FILE_NAME${NC}"
echo -e "  Coverage: ${BOLD}${COVERAGE_PCT}%${NC}"
echo -e "  Lines Covered: $COVERED_LINES / $TOTAL_LINES"
echo -e "  Lines Needing Tests: ${RED}$UNCOVERED_LINES${NC}"
echo ""

# Coverage Status
if (( $(echo "$COVERAGE_PCT >= 95" | bc -l) )); then
    echo -e "${GREEN}✓ COVERAGE STATUS: EXCELLENT (≥95%)${NC}"
elif (( $(echo "$COVERAGE_PCT >= 90" | bc -l) )); then
    echo -e "${YELLOW}◐ COVERAGE STATUS: GOOD (90-95%)${NC}"
elif (( $(echo "$COVERAGE_PCT >= 80" | bc -l) )); then
    echo -e "${YELLOW}◐ COVERAGE STATUS: ACCEPTABLE (80-90%)${NC}"
else
    echo -e "${RED}✗ COVERAGE STATUS: NEEDS WORK (<80%)${NC}"
fi
echo ""

# Quick Action Items
if [[ "$TEST_FAILED" == true ]] || (( $(echo "$COVERAGE_PCT < 90" | bc -l) )); then
    echo -e "${BOLD}QUICK ACTION ITEMS:${NC}"
    
    if [[ "$TEST_FAILED" == true ]]; then
        echo -e "  ${RED}1.${NC} Fix failing tests (see errors above)"
    fi
    
    if (( $(echo "$COVERAGE_PCT < 90" | bc -l) )); then
        echo -e "  ${YELLOW}2.${NC} Add tests for $UNCOVERED_LINES uncovered lines"
        echo -e "     Run with -v flag to see detailed line numbers"
    fi
    echo ""
fi

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Cleanup
rm -f "$TEST_OUTPUT_FILE" 2>/dev/null || true

# Note: Firebase emulator cleanup is handled by the trap set earlier

# Exit with appropriate code
if [[ "$TEST_FAILED" == true ]]; then
    exit 1
fi

exit 0
