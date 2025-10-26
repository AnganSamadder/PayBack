#!/bin/bash

# Local CI Test Script - Replicates GitHub Actions Environment
# This script runs the same steps as the GitHub Actions CI workflow

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
REQUIRED_IOS_VERSION="26.0"

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Local CI Test - Replicating GitHub Actions Environment${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Step 1: Create GoogleService-Info.plist
echo -e "${YELLOW}[1/9] Creating GoogleService-Info.plist for testing...${NC}"
cat > "${PROJECT_ROOT}/iOS/GoogleService-Info.plist" <<'EOF'
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
echo -e "${GREEN}✓ GoogleService-Info.plist created${NC}"
echo ""

# Step 2: Show Xcode version
echo -e "${YELLOW}[2/9] Checking Xcode version...${NC}"
xcodebuild -version | head -1
echo ""

# Step 3: Check iOS runtime
echo -e "${YELLOW}[3/9] Checking iOS runtime...${NC}"
if xcrun simctl runtime list 2>/dev/null | grep -q "iOS ${REQUIRED_IOS_VERSION}"; then
  echo -e "${GREEN}✓ iOS runtime ${REQUIRED_IOS_VERSION} available${NC}"
else
  echo -e "${YELLOW}⚠ iOS runtime ${REQUIRED_IOS_VERSION} not found, using available runtime${NC}"
fi
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
xcodebuild -resolvePackageDependencies -project PayBack.xcodeproj -scheme PayBackTests > /dev/null 2>&1 || true
echo -e "${GREEN}✓ Resolved${NC}"
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
  if "Pro Max" in name:
    return 100
  if "Pro" in name:
    return 90
  if "Plus" in name:
    return 80
  if "Air" in name:
    return 70
  if name.startswith("iPhone ") and name.split()[1].isdigit():
    return 60
  if "SE" in name:
    return 10
  return 50

def pick_preferred(candidates):
  def sorter(entry):
    version_tuple, name, udid, version_str = entry
    return (version_tuple, get_device_priority(name), name)
  
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

version_tuple, name, udid, version_str = pick_preferred(candidates)
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

# Step 10: Clean previous test results
echo -e "${YELLOW}[10/10] Running tests (sanitizer: ${SANITIZER})...${NC}"
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

echo "Running tests..."
echo ""

TEST_CMD="xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBackTests \
  -destination 'platform=iOS Simulator,id=${SIMULATOR_UDID}' \
  $SANITIZER_FLAGS \
  -resultBundlePath TestResults.xcresult"

if command -v xcpretty &> /dev/null; then
  if eval "$TEST_CMD" 2>&1 | tee test_output.log | xcpretty; then
    TEST_SUCCESS=true
  else
    TEST_SUCCESS=false
  fi
else
  if eval "$TEST_CMD" 2>&1 | tee test_output.log; then
    TEST_SUCCESS=true
  else
    TEST_SUCCESS=false
  fi
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

if [ "$TEST_SUCCESS" = true ]; then
  echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
else
  echo -e "${RED}✗ SOME TESTS FAILED${NC}"
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

# Generate coverage if enabled
if [ "$SANITIZER" = "none" ] && [ -d "TestResults.xcresult" ]; then
  echo "Generating coverage..."
  
  if xcrun xccov view --report --json TestResults.xcresult > coverage.json 2>&1; then
    COVERAGE=$(python3 -c "import json; data=json.load(open('coverage.json')); print(f\"{data['lineCoverage']*100:.2f}\")" 2>/dev/null || echo "0.00")
    echo "Coverage: ${COVERAGE}%"
    
    THRESHOLD="70.0"
    if python3 -c "exit(0 if float('${COVERAGE}') >= float('${THRESHOLD}') else 1)" 2>/dev/null; then
      echo -e "${GREEN}✓ Above threshold ${THRESHOLD}%${NC}"
    else
      echo -e "${YELLOW}⚠ Below threshold ${THRESHOLD}%${NC}"
    fi
  fi
  
  echo ""
fi

if [ "$TEST_SUCCESS" = true ]; then
  exit 0
else
  exit 1
fi
