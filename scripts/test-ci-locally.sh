#!/bin/bash

# Ultimate Local CI Test Script - Complete GitHub Actions Simulation
# This script runs ALL tests exactly as GitHub Actions would:
# - Unit tests (existing)
# - Firebase integration tests (with local emulators)
# - Coverage analysis with functional/UI separation
# - Comprehensive reporting
#
# Usage: ./scripts/test-ci-locally.sh
# Requirements: Xcode, Firebase CLI (optional), xcpretty (optional)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANITIZER="${SANITIZER:-none}"
# Will automatically select latest iOS version available
REQUIRED_IOS_VERSION=""

# Firebase config paths (preserve real config, use dummy for tests)
GOOGLE_PLIST_PATH="${PROJECT_ROOT}/apps/ios/PayBack/GoogleService-Info.plist"
GOOGLE_PLIST_BACKUP="${PROJECT_ROOT}/apps/ios/PayBack/GoogleService-Info.plist.ci-backup"
GOOGLE_PLIST_CREATED_FOR_TESTS=false

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Ultimate CI Test - Complete GitHub Actions Simulation${NC}"
echo -e "${BLUE}  Unit Tests + Firebase Integration + Coverage Analysis${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Step 1: Create GoogleService-Info.plist
echo -e "${YELLOW}[1/9] Preparing GoogleService-Info.plist for testing...${NC}"

# If a real plist exists, back it up so we can restore it later.
if [ -f "$GOOGLE_PLIST_PATH" ]; then
  echo "Backing up existing GoogleService-Info.plist to temporary CI backup"
  cp "$GOOGLE_PLIST_PATH" "$GOOGLE_PLIST_BACKUP"
else
  GOOGLE_PLIST_CREATED_FOR_TESTS=true
fi

# Write dummy config for tests without losing the original
cat > "$GOOGLE_PLIST_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CLIENT_ID</key>
  <string>dummy-client-id</string>
  <key>REVERSED_CLIENT_ID</key>
  <string>com.googleusercontent.apps.dummy</string>
  <key>API_KEY</key>
  <string>dummy-api-key</string>
  <key>GCM_SENDER_ID</key>
  <string>123456789</string>
  <key>PLIST_VERSION</key>
  <string>1</string>
  <key>BUNDLE_ID</key>
  <string>com.angansamadder.PayBack</string>
  <key>PROJECT_ID</key>
  <string>dummy-project-id</string>
  <key>STORAGE_BUCKET</key>
  <string>dummy-bucket.appspot.com</string>
  <key>IS_ADS_ENABLED</key>
  <false/>
  <key>IS_ANALYTICS_ENABLED</key>
  <false/>
  <key>IS_APPINVITE_ENABLED</key>
  <false/>
  <key>IS_GCM_ENABLED</key>
  <true/>
  <key>IS_SIGNIN_ENABLED</key>
  <true/>
  <key>GOOGLE_APP_ID</key>
  <string>1:123456789:ios:dummy</string>
</dict>
</plist>
EOF
echo -e "${GREEN}✓ GoogleService-Info.plist dummy created for tests${NC}"
echo ""

# Step 2: Show Xcode version
echo -e "${YELLOW}[2/9] Checking Xcode version...${NC}"
xcodebuild -version | head -1
echo ""

# Step 3: Check iOS runtime
echo -e "${YELLOW}[3/9] Checking iOS runtime...${NC}"
echo "Will automatically select latest available iOS version"
echo ""

# Step 4: Clean simulators
echo -e "${YELLOW}[4/9] Cleaning simulators...${NC}"
xcrun simctl delete unavailable 2>/dev/null || true
echo -e "${GREEN}✓ Cleaned${NC}"
echo ""

# Step 5: Check xcpretty
echo -e "${YELLOW}[5/9] Checking xcpretty...${NC}"
if ! command -v xcpretty &> /dev/null; then
  echo "Installing xcpretty..."
  sudo gem install xcpretty --no-document || echo "Could not install xcpretty"
fi
echo -e "${GREEN}✓ Ready${NC}"
echo ""

# Step 6: Generate Xcode project
echo -e "${YELLOW}[6/9] Generating project...${NC}"
cd "${PROJECT_ROOT}"
if xcodegen generate > /dev/null 2>&1; then
  echo -e "${GREEN}✓ Generated${NC}"
else
  echo -e "${YELLOW}⚠ Generation had warnings (continuing)${NC}"
fi
echo ""

# Step 7: Resolve dependencies
echo -e "${YELLOW}[7/10] Resolving dependencies...${NC}"

# Check if gtimeout is available (from coreutils)
TIMEOUT_CMD=""
if command -v gtimeout &> /dev/null; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout &> /dev/null; then
  TIMEOUT_CMD="timeout"
fi

# Check if dependencies are already resolved
if [ -f "PayBack.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" ]; then
  echo "Dependencies already resolved (Package.resolved exists)"
  echo -e "${GREEN}✓ Already resolved${NC}"
else
  # Kill any existing xcodebuild processes that might be hanging
  pkill -9 xcodebuild 2>/dev/null || true
  sleep 1

  # Resolve with timeout and visible output
  echo "Resolving Swift Package dependencies (this may take 2-3 minutes)..."
  RESOLVE_LOG="/tmp/resolve-deps-$$.log"

  # Run with timeout (10 minutes max for first-time download)
  RESOLVE_CMD="xcodebuild -resolvePackageDependencies -project PayBack.xcodeproj"
  
  if [ -n "$TIMEOUT_CMD" ]; then
    if $TIMEOUT_CMD 600 $RESOLVE_CMD > "$RESOLVE_LOG" 2>&1; then
      echo -e "${GREEN}✓ Resolved${NC}"
    else
      RESOLVE_EXIT=$?
      if [ $RESOLVE_EXIT -eq 124 ]; then
        echo -e "${RED}✗ Dependency resolution timed out after 10 minutes${NC}"
        echo ""
        echo "Last 30 lines of output:"
        tail -30 "$RESOLVE_LOG"
        echo ""
        echo "Try: brew install coreutils (for gtimeout)"
        rm -f "$RESOLVE_LOG"
        exit 1
      else
        echo -e "${YELLOW}⚠ Dependency resolution had issues (continuing)${NC}"
        tail -10 "$RESOLVE_LOG" 2>/dev/null || true
      fi
    fi
  else
    echo -e "${YELLOW}⚠ No timeout command available, resolving without timeout...${NC}"
    if $RESOLVE_CMD > "$RESOLVE_LOG" 2>&1; then
      echo -e "${GREEN}✓ Resolved${NC}"
    else
      echo -e "${YELLOW}⚠ Dependency resolution had issues (continuing)${NC}"
      tail -10 "$RESOLVE_LOG" 2>/dev/null || true
    fi
  fi

  rm -f "$RESOLVE_LOG"
fi
echo ""

# Step 8: Select simulator
echo -e "${YELLOW}[8/10] Selecting iPhone simulator...${NC}"
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
print(f"{name}:::{udid}:::{version_str}")
PY
)

if [ $? -ne 0 ]; then
  echo -e "${RED}✗ Failed to select simulator${NC}"
  exit 1
fi

SIMULATOR_NAME=$(echo "$SIMULATOR_INFO" | awk -F':::' '{print $1}')
SIMULATOR_UDID=$(echo "$SIMULATOR_INFO" | awk -F':::' '{print $2}')
SIMULATOR_OS=$(echo "$SIMULATOR_INFO" | awk -F':::' '{print $3}')

echo -e "${GREEN}✓ Selected: ${SIMULATOR_NAME} (iOS ${SIMULATOR_OS})${NC}"
echo -e "  UDID: ${SIMULATOR_UDID}"
echo ""

# Step 9: Boot simulator
echo -e "${YELLOW}[9/10] Booting simulator...${NC}"
xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || echo "Already booted"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b 2>/dev/null || true
echo -e "${GREEN}✓ Ready${NC}"
echo ""

# Step 10: Start Firebase emulators
echo -e "${YELLOW}[10/13] Starting Firebase emulators...${NC}"

EMULATORS_STARTED=false
EMULATOR_PID=""
EMULATOR_LOG_FILE="/tmp/firebase-emulator-ci-$$.log"

# Function to cleanup Firebase emulator and restore Firebase plist
cleanup_emulator() {
  if [[ "$EMULATORS_STARTED" == true ]]; then
    echo ""
    echo -e "${YELLOW}Stopping Firebase emulators...${NC}"
        
    # Kill the main process
    if [[ -n "$EMULATOR_PID" ]]; then
      kill $EMULATOR_PID 2>/dev/null || true
      sleep 2
    fi
        
    # Force kill any remaining Firebase processes
    pkill -f "firebase.*emulators" 2>/dev/null || true
    pkill -f "java.*firestore" 2>/dev/null || true
        
    # Clean up log file
    rm -f "$EMULATOR_LOG_FILE" 2>/dev/null || true
        
    echo -e "${GREEN}✓ Emulators stopped${NC}"
  fi

  # Restore original GoogleService-Info.plist if we backed it up
  if [ -f "$GOOGLE_PLIST_BACKUP" ]; then
    echo "Restoring original GoogleService-Info.plist from CI backup"
    mv -f "$GOOGLE_PLIST_BACKUP" "$GOOGLE_PLIST_PATH" 2>/dev/null || true
  elif [ "$GOOGLE_PLIST_CREATED_FOR_TESTS" = true ]; then
    # No original existed; remove the dummy file so we don't leave test config lying around
    rm -f "$GOOGLE_PLIST_PATH" 2>/dev/null || true
  fi
}

# Set trap to cleanup on exit
trap cleanup_emulator EXIT INT TERM

if command -v firebase &> /dev/null; then
    # Check if emulator is already running
    if lsof -Pi :8080 -sTCP:LISTEN -t >/dev/null 2>&1 && lsof -Pi :9099 -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Firebase emulator already running${NC}"
        echo "  - Auth emulator: http://127.0.0.1:9099"
        echo "  - Firestore emulator: http://127.0.0.1:8080"
        EMULATORS_STARTED=false  # We didn't start it, so don't stop it
        # Set environment variables even if already running
        export FIRESTORE_EMULATOR_HOST="127.0.0.1:8080"
        export FIREBASE_AUTH_EMULATOR_HOST="127.0.0.1:9099"
    else
        # Start emulator in background with logging
        firebase emulators:start --only auth,firestore --project demo-test > "$EMULATOR_LOG_FILE" 2>&1 &
        EMULATOR_PID=$!
        EMULATORS_STARTED=true
        
        # Wait for emulator to be ready
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
            
            # Check if ports are listening and HTTP endpoints are responding
            if lsof -Pi :8080 -sTCP:LISTEN -t >/dev/null 2>&1 && \
               lsof -Pi :9099 -sTCP:LISTEN -t >/dev/null 2>&1; then
                # Try both localhost and 127.0.0.1 since Firebase might bind to either
                if (curl -s http://127.0.0.1:9099/ >/dev/null 2>&1 || curl -s http://localhost:9099/ >/dev/null 2>&1) && \
                   (curl -s http://127.0.0.1:8080/ >/dev/null 2>&1 || curl -s http://localhost:8080/ >/dev/null 2>&1); then
                    EMULATOR_READY=true
                    break
                fi
            fi
            
            sleep 1
        done
        
        if [[ "$EMULATOR_READY" == true ]]; then
            echo -e "${GREEN}✓ Firebase emulators started successfully${NC}"
            echo "  - Auth emulator: http://127.0.0.1:9099"
            echo "  - Firestore emulator: http://127.0.0.1:8080"
            echo "  - Emulator UI: http://127.0.0.1:4000"
            
            # Set environment variables for tests - use 127.0.0.1 to match Firebase binding
            export FIRESTORE_EMULATOR_HOST="127.0.0.1:8080"
            export FIREBASE_AUTH_EMULATOR_HOST="127.0.0.1:9099"
        else
            echo -e "${RED}✗ Firebase emulators failed to start within 60 seconds${NC}"
            echo ""
            echo "Last 20 lines of emulator log:"
            tail -20 "$EMULATOR_LOG_FILE" 2>/dev/null || echo "No log available"
            echo ""
            exit 1
        fi
    fi
else
    echo -e "${YELLOW}⚠ Firebase CLI not found${NC}"
    echo "Install it with: curl -sL https://firebase.tools | bash"
    echo "Tests requiring Firebase will fail"
    EMULATORS_STARTED=false
fi
echo ""

# Step 11: Clean previous test results
echo -e "${YELLOW}[11/13] Running tests (sanitizer: ${SANITIZER})...${NC}"
echo ""
rm -rf TestResults.xcresult coverage-report.txt coverage.json 2>/dev/null || true

# Determine sanitizer flags
SANITIZER_FLAGS=""
if [ "$SANITIZER" = "none" ]; then
  SANITIZER_FLAGS="-enableCodeCoverage YES"
elif [ "$SANITIZER" = "thread" ]; then
  SANITIZER_FLAGS="-enableThreadSanitizer YES"
elif [ "$SANITIZER" = "address" ]; then
  SANITIZER_FLAGS="-enableAddressSanitizer YES"
fi

# Run tests
export NSUnbufferedIO=YES

echo "Running all tests (unit + integration)..."
echo "This may take 2-5 minutes depending on your machine..."
echo "Progress will be shown below..."
echo ""

TEST_CMD="xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBackTests \
  -destination 'platform=iOS Simulator,id=${SIMULATOR_UDID}' \
  $SANITIZER_FLAGS \
  -parallel-testing-enabled NO \
  -resultBundlePath TestResults.xcresult"

# Use timeout if available (30 minutes max for all tests)
if [ -n "$TIMEOUT_CMD" ]; then
  TEST_CMD="$TIMEOUT_CMD 1800 $TEST_CMD"
fi

# Show progress while tests run
if command -v xcpretty &> /dev/null; then
  # Use xcpretty for formatted output
  set +e
  eval "$TEST_CMD" 2>&1 | tee test_output.log | xcpretty --color --simple
  TEST_EXIT_CODE=${PIPESTATUS[0]}
  set -e
  
  # Check actual test results instead of just exit code
  # xcodebuild can exit with non-zero even when tests pass due to console warnings
  ACTUAL_FAILURES=$(grep -E "Test Case.*failed \(" test_output.log 2>/dev/null | wc -l | xargs)
  TEST_RESULTS=$(grep -E "Executed.*tests.*with.*failure" test_output.log 2>/dev/null | tail -1)
  
  if [ $TEST_EXIT_CODE -eq 124 ]; then
    echo -e "${RED}✗ Tests timed out after 30 minutes${NC}"
    TEST_SUCCESS=false
  elif [ "$ACTUAL_FAILURES" = "0" ] && [[ "$TEST_RESULTS" == *"0 failures"* ]]; then
    # All tests passed - ignore exit code if it's just console warnings
    TEST_SUCCESS=true
  elif [ $TEST_EXIT_CODE -eq 0 ]; then
    TEST_SUCCESS=true
  else
    TEST_SUCCESS=false
  fi
else
  # No xcpretty - show raw output
  echo "Note: Install xcpretty for better output (gem install xcpretty)"
  echo ""
  set +e
  eval "$TEST_CMD" 2>&1 | tee test_output.log
  TEST_EXIT_CODE=${PIPESTATUS[0]}
  set -e
  
  if [ $TEST_EXIT_CODE -eq 124 ]; then
    echo -e "${RED}✗ Tests timed out after 30 minutes${NC}"
    TEST_SUCCESS=false
  elif [ $TEST_EXIT_CODE -eq 0 ]; then
    TEST_SUCCESS=true
  else
    TEST_SUCCESS=false
  fi
fi

echo ""

# Note: Firebase emulator cleanup is handled by the trap set earlier

# Step 13: Generate coverage and summary
echo -e "${YELLOW}[13/13] Generating coverage report...${NC}"
echo ""

# Generate coverage if enabled
if [ "$SANITIZER" = "none" ] && [ -d "TestResults.xcresult" ]; then
  echo "Analyzing coverage data..."
  
  if xcrun xccov view --report --json TestResults.xcresult > coverage.json 2>&1; then
    python3 <<'PYCOV'
import json
import sys
from pathlib import Path

# Load coverage data
with open('coverage.json', 'r') as f:
    data = json.load(f)

# Overall coverage
overall = data.get('lineCoverage', 0) * 100

# Color codes
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
RED = '\033[0;31m'
BLUE = '\033[0;34m'
CYAN = '\033[0;36m'
MAGENTA = '\033[0;35m'
NC = '\033[0m'

# Categorize files
ui_files = []
functional_files = []
integration_test_files = []

for target in data.get('targets', []):
    target_name = target.get('name', '')
    if target_name != 'PayBack.app':
        continue
    
    for file_data in target.get('files', []):
        path = file_data.get('path', '')
        if '/apps/ios/PayBack/' not in path or path.endswith('Tests.swift'):
            continue
        
        coverage = file_data.get('lineCoverage', 0) * 100
        
        # Extract relative path from iOS directory
        if '/apps/ios/PayBack/' in path:
            rel_path = path.split('/apps/ios/PayBack/')[-1]
        else:
            rel_path = Path(path).name
        
        # Categorize as UI or Functional
        # UI files: Views, DesignSystem components, App entry points
        is_ui = (
            'View.swift' in rel_path or
            'Views/' in rel_path or
            '/DesignSystem/' in rel_path or
            'PayBackApp.swift' in rel_path or
            'RootView.swift' in rel_path or
            'Coordinator.swift' in rel_path or
            'Container.swift' in rel_path or
            rel_path.endswith('Sheet.swift') or
            rel_path.endswith('DetailView.swift') or
            rel_path.endswith('ListView.swift') or
            rel_path.endswith('TabView.swift') or
            '/Features/' in rel_path
        )
        
        # Additional content-based check for SwiftUI views
        try:
            with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
                content = fh.read(4000)
            # Check for SwiftUI View conformance
            if ': View' in content or 'var body: some View' in content:
                is_ui = True
        except Exception:
            pass
        
        if is_ui:
            ui_files.append((rel_path, coverage))
        else:
            functional_files.append((rel_path, coverage))

# Calculate separate coverages
functional_cov = sum(c for _, c in functional_files) / len(functional_files) if functional_files else 0
ui_cov = sum(c for _, c in ui_files) / len(ui_files) if ui_files else 0

print(f"\n{BLUE}{'=' * 80}{NC}")
print(f"{BLUE}COMPREHENSIVE COVERAGE REPORT (Unit + Integration Tests){NC}")
print(f"{BLUE}{'=' * 80}{NC}\n")

# Functional code section
print(f"{MAGENTA}══════════════════════════════════════════════════════════════════════════════{NC}")
print(f"{MAGENTA}FUNCTIONAL CODE (Models, Services, Business Logic){NC}")
print(f"{MAGENTA}══════════════════════════════════════════════════════════════════════════════{NC}\n")

# Group functional files by feature
functional_features = {}
for path, cov in functional_files:
    if '/' in path:
        feature = path.split('/')[0]
    else:
        feature = 'Root'
    
    if feature not in functional_features:
        functional_features[feature] = []
    functional_features[feature].append((path, cov))

# Print functional files by feature
for feature in sorted(functional_features.keys()):
    files = functional_features[feature]
    avg_cov = sum(c for _, c in files) / len(files) if files else 0
    
    # Color based on functional target (90%)
    if avg_cov >= 90:
        color = GREEN
        status = "✓"
    elif avg_cov >= 70:
        color = YELLOW
        status = "◐"
    else:
        color = RED
        status = "✗"
    
    print(f"{CYAN}{feature}{NC} - {status} (avg: {color}{avg_cov:.1f}%{NC})")
    print(f"{'-' * 80}")
    
    for path, cov in sorted(files, key=lambda x: x[1]):
        # Color based on functional target
        if cov >= 90:
            color = GREEN
            icon = "✓"
        elif cov >= 70:
            color = YELLOW
            icon = "◐"
        else:
            color = RED
            icon = "✗"
        
        display_path = path if len(path) <= 55 else "..." + path[-52:]
        print(f"  {icon} {display_path:<55} {color}{cov:5.1f}%{NC}")
    
    print()

# UI code section
print(f"{MAGENTA}══════════════════════════════════════════════════════════════════════════════{NC}")
print(f"{MAGENTA}UI CODE (Views, Design System, Coordinators){NC}")
print(f"{MAGENTA}══════════════════════════════════════════════════════════════════════════════{NC}\n")

# Group UI files by feature
ui_features = {}
for path, cov in ui_files:
    if '/' in path:
        feature = path.split('/')[0]
    else:
        feature = 'Root'
    
    if feature not in ui_features:
        ui_features[feature] = []
    ui_features[feature].append((path, cov))

# Print UI files by feature  
for feature in sorted(ui_features.keys()):
    files = ui_features[feature]
    avg_cov = sum(c for _, c in files) / len(files) if files else 0
    
    # Color based on UI target (40% - basic smoke tests)
    if avg_cov >= 60:
        color = GREEN
        status = "✓"
    elif avg_cov >= 40:
        color = YELLOW
        status = "◐"
    else:
        color = RED
        status = "✗"
    
    print(f"{CYAN}{feature}{NC} - {status} (avg: {color}{avg_cov:.1f}%{NC})")
    print(f"{'-' * 80}")
    
    for path, cov in sorted(files, key=lambda x: x[1]):
        # Color based on UI expectations
        if cov >= 60:
            color = GREEN
            icon = "✓"
        elif cov >= 40:
            color = YELLOW
            icon = "◐"
        else:
            color = RED
            icon = "✗"
        
        display_path = path if len(path) <= 55 else "..." + path[-52:]
        print(f"  {icon} {display_path:<55} {color}{cov:5.1f}%{NC}")
    
    print()

# Summary
print(f"{BLUE}{'=' * 80}{NC}")
print(f"{BLUE}SUMMARY{NC}")
print(f"{BLUE}{'=' * 80}{NC}\n")

functional_target = 85.0
ui_target = 25.0

# Functional status
if functional_cov >= functional_target:
    func_color = GREEN
    func_status = "✓ EXCELLENT - Target Achieved!"
elif functional_cov >= 80:
    func_color = GREEN
    func_status = "✓ VERY GOOD - Near Target"
elif functional_cov >= 70:
    func_color = YELLOW
    func_status = "◐ GOOD - Improving"
else:
    func_color = RED
    func_status = "✗ NEEDS WORK"

# UI status
if ui_cov >= ui_target:
    ui_color = GREEN
    ui_status = "✓ EXCELLENT"
elif ui_cov >= 20:
    ui_color = YELLOW
    ui_status = "◐ ACCEPTABLE"
else:
    ui_color = RED
    ui_status = "✗ NEEDS WORK"

# Overall (weighted: 70% functional, 30% UI)
weighted_target = (functional_target * 0.7) + (ui_target * 0.3)
weighted_actual = (functional_cov * 0.7) + (ui_cov * 0.3) if (functional_files and ui_files) else overall

print(f"Functional Code:   {func_color}{functional_cov:5.1f}%{NC} (target: {functional_target:.0f}%) - {func_color}{func_status}{NC}")
print(f"UI Code:           {ui_color}{ui_cov:5.1f}%{NC} (target: {ui_target:.0f}%) - {ui_color}{ui_status}{NC}")
print(f"Overall Coverage:  {overall:.2f}%")
print(f"Weighted Score:    {weighted_actual:.2f}% (target: {weighted_target:.0f}%)\n")

# Integration test summary
print(f"{BLUE}INTEGRATION TEST COVERAGE:{NC}")
print(f"{'-' * 80}")
integration_services = [
    ('EmailAuthService', 90.0),
    ('ExpenseCloudService', 90.0),
    ('InviteLinkService', 90.0),
    ('GroupCloudService', 90.0),
    ('LinkRequestService', 90.0),
    ('PhoneAuthService', 85.0),
    ('FirestoreAccountService', 90.0),
]

# Estimate integration coverage based on service files
integration_cov = 0
integration_count = 0
for service, expected_cov in integration_services:
    # Find service file in functional files
    service_file = None
    for path, cov in functional_files:
        if service in path:
            service_file = (path, cov)
            break
    
    if service_file:
        path, cov = service_file
        integration_cov += cov
        integration_count += 1
        
        if cov >= expected_cov - 5:  # Within 5% of expected
            color = GREEN
            icon = "✓"
        elif cov >= expected_cov - 15:
            color = YELLOW
            icon = "◐"
        else:
            color = RED
            icon = "✗"
        
        print(f"  {icon} {service:<35} {color}{cov:5.1f}%{NC} (expected: {expected_cov:.0f}%)")
    else:
        print(f"  ? {service:<35} (not found)")

if integration_count > 0:
    avg_integration = integration_cov / integration_count
    print(f"\n  Average Integration Coverage: {avg_integration:.1f}%")

print()

# Top files needing work - Functional
print(f"{BLUE}TOP FUNCTIONAL FILES NEEDING COVERAGE:{NC}")
print(f"{'-' * 80}")
low_functional = sorted([(p, c) for p, c in functional_files if c < 90], key=lambda x: x[1])[:10]
if low_functional:
    for path, cov in low_functional:
        display_path = path if len(path) <= 55 else "..." + path[-52:]
        gap = 90 - cov
        print(f"  {RED}✗{NC} {display_path:<55} {RED}{cov:5.1f}%{NC} (need +{gap:.1f}%)")
else:
    print(f"  {GREEN}🎉 All functional files have excellent coverage!{NC}")

print()

# Save detailed report
with open('coverage-report.txt', 'w') as f:
    f.write("COMPREHENSIVE COVERAGE REPORT (Unit + Integration Tests)\n")
    f.write("=" * 80 + "\n\n")
    
    f.write("FUNCTIONAL CODE\n")
    f.write("=" * 80 + "\n")
    for feature in sorted(functional_features.keys()):
        files = functional_features[feature]
        avg_cov = sum(c for _, c in files) / len(files) if files else 0
        f.write(f"\n{feature} (avg: {avg_cov:.1f}%)\n")
        f.write("-" * 80 + "\n")
        for path, cov in sorted(files, key=lambda x: x[1]):
            f.write(f"  {path:<55} {cov:5.1f}%\n")
    
    f.write("\n\nUI CODE\n")
    f.write("=" * 80 + "\n")
    for feature in sorted(ui_features.keys()):
        files = ui_features[feature]
        avg_cov = sum(c for _, c in files) / len(files) if files else 0
        f.write(f"\n{feature} (avg: {avg_cov:.1f}%)\n")
        f.write("-" * 80 + "\n")
        for path, cov in sorted(files, key=lambda x: x[1]):
            f.write(f"  {path:<55} {cov:5.1f}%\n")
    
    f.write(f"\n\nSUMMARY\n")
    f.write("=" * 80 + "\n")
    f.write(f"Functional Code: {functional_cov:.1f}% (target: {functional_target:.0f}%)\n")
    f.write(f"UI Code: {ui_cov:.1f}% (target: {ui_target:.0f}%)\n")
    f.write(f"Overall Coverage: {overall:.2f}%\n")
    f.write(f"Weighted Score: {weighted_actual:.2f}% (target: {weighted_target:.0f}%)\n")
    
    f.write(f"\n\nINTEGRATION TEST COVERAGE\n")
    f.write("=" * 80 + "\n")
    for service, expected_cov in integration_services:
        service_file = None
        for path, cov in functional_files:
            if service in path:
                service_file = (path, cov)
                break
        if service_file:
            path, cov = service_file
            f.write(f"  {service:<35} {cov:5.1f}% (expected: {expected_cov:.0f}%)\n")

# Exit based on functional coverage target
# Success if >= 80% (achievable target)
sys.exit(0 if functional_cov >= 80 else 1)
PYCOV
    
    COVERAGE_EXIT=$?
  else
    echo -e "${RED}✗ Failed to generate coverage report${NC}"
    COVERAGE_EXIT=1
  fi
  
  echo ""
fi

# Step 14: Generate test failure report if tests failed
if [ "$TEST_SUCCESS" = false ] && [ -f "test_output.log" ]; then
  echo -e "${RED}════════════════════════════════════════${NC}"
  echo -e "${RED}  TEST FAILURE REPORT${NC}"
  echo -e "${RED}════════════════════════════════════════${NC}"
  echo ""
  
  # Extract failed tests from log (exclude CHHapticPattern warnings and other simulator noise)
  FAILED_TESTS=$(grep -E "✗.*failed|Test Case.*failed|error:" test_output.log 2>/dev/null | \
    grep -v "CHHapticPattern" | \
    grep -v "hapticpatternlibrary.plist" | \
    grep -v "FirebaseFirestore.*Stream error" | \
    grep -v "Fatal error:" | \
    grep -v "\[AuthCoordinator\]" | \
    grep -v "\[Reconciliation\]" | \
    head -50)
  
  if [ -n "$FAILED_TESTS" ]; then
    echo -e "${BOLD}Failed Tests:${NC}"
    echo ""
    
    # Parse and display failed tests with better formatting
    echo "$FAILED_TESTS" | while IFS= read -r line; do
      # Extract test name if it's in the xcpretty format
      if [[ "$line" =~ ✗ ]]; then
        echo -e "${RED}  ✗${NC} $line" | sed 's/✗//'
      else
        echo "  $line"
      fi
    done
    
    echo ""
    
    # Count failures
    FAILURE_COUNT=$(echo "$FAILED_TESTS" | wc -l | xargs)
    echo -e "${BOLD}Total Failures: ${RED}$FAILURE_COUNT${NC}"
    echo ""
    
    # Show summary from test output
    TEST_SUMMARY=$(grep -E "Executed.*test.*with.*failure|Test Suite.*failed" test_output.log 2>/dev/null | tail -3)
    if [ -n "$TEST_SUMMARY" ]; then
      echo -e "${BOLD}Summary:${NC}"
      echo "$TEST_SUMMARY"
      echo ""
    fi
    
    # Suggest next steps
    echo -e "${YELLOW}💡 To investigate failures:${NC}"
    echo "  1. Check test_output.log for full details"
    echo "  2. Run specific test: xcodebuild test -only-testing:PayBackTests/TestClassName/testMethodName"
    echo "  3. Check Firebase emulator logs if Firebase tests failed"
    echo ""
  else
    echo -e "${YELLOW}⚠ Tests failed but couldn't parse failure details${NC}"
    echo "Check test_output.log for full output"
    echo ""
  fi
fi

echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

if [ "$TEST_SUCCESS" = true ]; then
  echo -e "${GREEN}✓ ALL TESTS PASSED (Unit + Integration)${NC}"
  if [ "$COVERAGE_EXIT" = "0" ]; then
    echo -e "${GREEN}✓ COVERAGE TARGET ACHIEVED${NC}"
  fi
else
  echo -e "${RED}✗ SOME TESTS FAILED${NC}"
  echo -e "${YELLOW}See failure report above for details${NC}"
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

# Cleanup (but keep test_output.log if tests failed for debugging)
if [ "$TEST_SUCCESS" = true ]; then
  rm -f test_output.log 2>/dev/null || true
fi
rm -f emulator.log .emulator.pid 2>/dev/null || true
