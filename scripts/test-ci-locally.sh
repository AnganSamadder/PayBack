#!/bin/bash

# Local CI Test Script for PayBack
# This script runs the complete test suite:
# - Unit tests
# - Coverage analysis with functional/UI separation
# - Comprehensive reporting
#
# Usage: ./scripts/test-ci-locally.sh
# Requirements: Xcode, xcpretty (optional)
#
# Environment Variables:
#   SANITIZER: none (default, enables coverage), thread, or address
#   CI_FLAVOR: xcodecloud (enables XcodeCloud parity mode)
#   DERIVED_DATA_PATH: custom DerivedData path (default: ./DerivedDataCI in xcodecloud mode)
#   FAIL_ON_WARNINGS: 1 (fail if any warnings are detected)
#   RUN_WEB_E2E: 1 (default) to run web Playwright smoke tests; set to 0 to skip

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANITIZER="${SANITIZER:-none}"
CI_FLAVOR="${CI_FLAVOR:-github}"
FAIL_ON_WARNINGS="${FAIL_ON_WARNINGS:-1}"
RUN_WEB_E2E="${RUN_WEB_E2E:-1}"

# XcodeCloud parity mode settings
if [ "$CI_FLAVOR" = "xcodecloud" ]; then
	DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_ROOT/DerivedDataCI}"
	XCODECLOUD_MODE=true
else
	DERIVED_DATA_PATH=""
	XCODECLOUD_MODE=false
fi

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
if [ "$XCODECLOUD_MODE" = true ]; then
	echo -e "${BLUE}  PayBack CI Test - XcodeCloud Parity Mode${NC}"
else
	echo -e "${BLUE}  PayBack CI Test - Complete GitHub Actions Simulation${NC}"
fi
echo -e "${BLUE}  Unit Tests + Coverage Analysis${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

cd "$PROJECT_ROOT"

# =============================================================================
# Run JS/TS Monorepo Checks
# =============================================================================
echo -e "${YELLOW}[1/10] Running monorepo JS checks...${NC}"
if ! command -v bun &>/dev/null; then
	echo -e "${RED}✗ Bun is required for monorepo checks. Install with: brew install bun${NC}"
	exit 1
fi

bun install >/dev/null
bun run ci

if [ "$RUN_WEB_E2E" = "1" ]; then
	echo "Running web e2e smoke tests..."
	bunx playwright install chromium >/dev/null
	bun run --filter @payback/web test:e2e
else
	echo "Skipping web e2e smoke tests (RUN_WEB_E2E=$RUN_WEB_E2E)"
fi

echo -e "${GREEN}✓ Monorepo checks passed${NC}"
echo ""

# =============================================================================
# Environment Snapshot (helps debug XcodeCloud vs local differences)
# =============================================================================
echo -e "${YELLOW}[2/10] Environment Snapshot...${NC}"
HOST_ARCH=$(uname -m)
echo "  Host architecture: $HOST_ARCH"
xcodebuild -version | head -2 | sed 's/^/  /'
echo "  CI_FLAVOR: $CI_FLAVOR"
echo "  SANITIZER: $SANITIZER"
echo "  FAIL_ON_WARNINGS: $FAIL_ON_WARNINGS"

# Check if Intel simulator is being attempted
if [ "$HOST_ARCH" = "x86_64" ]; then
	echo ""
	echo -e "${YELLOW}⚠ Intel Mac detected.${NC}"
	echo -e "${YELLOW}  ConvexMobile XCFramework only ships arm64 simulator slices.${NC}"
	echo -e "${YELLOW}  Simulator builds will fail. Use device builds or Apple Silicon.${NC}"
	echo ""
fi

if [ "$XCODECLOUD_MODE" = true ]; then
	echo "  DerivedData path: $DERIVED_DATA_PATH"
fi
echo -e "${GREEN}✓ Environment captured${NC}"
echo ""

# =============================================================================
# Clean simulators
# =============================================================================
echo -e "${YELLOW}[3/10] Cleaning simulators...${NC}"
xcrun simctl delete unavailable 2>/dev/null || true
echo -e "${GREEN}✓ Cleaned${NC}"
echo ""

# =============================================================================
# Check xcpretty
# =============================================================================
echo -e "${YELLOW}[4/10] Checking xcpretty...${NC}"
if ! command -v xcpretty &>/dev/null; then
	echo "xcpretty not found - output will be raw"
	echo "Install it with: gem install xcpretty"
	XCPRETTY_AVAILABLE=false
else
	echo -e "${GREEN}✓ xcpretty available${NC}"
	XCPRETTY_AVAILABLE=true
fi
echo ""

# =============================================================================
# Generate Xcode project
# =============================================================================
echo -e "${YELLOW}[5/10] Generating project...${NC}"
if command -v xcodegen &>/dev/null; then
	if xcodegen generate >/dev/null 2>&1; then
		echo -e "${GREEN}✓ Generated${NC}"
	else
		echo -e "${YELLOW}⚠ Generation had warnings (continuing)${NC}"
	fi
else
	echo -e "${YELLOW}⚠ xcodegen not found - using existing project${NC}"
fi
echo ""

# =============================================================================
# Resolve dependencies
# =============================================================================
echo -e "${YELLOW}[6/10] Resolving dependencies...${NC}"

# Check if gtimeout is available (from coreutils)
TIMEOUT_CMD=""
if command -v gtimeout &>/dev/null; then
	TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
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

	RESOLVE_CMD="xcodebuild -resolvePackageDependencies -project PayBack.xcodeproj"

	if [ -n "$TIMEOUT_CMD" ]; then
		if $TIMEOUT_CMD 600 $RESOLVE_CMD >"$RESOLVE_LOG" 2>&1; then
			echo -e "${GREEN}✓ Resolved${NC}"
		else
			RESOLVE_EXIT=$?
			if [ $RESOLVE_EXIT -eq 124 ]; then
				echo -e "${RED}✗ Dependency resolution timed out after 10 minutes${NC}"
				echo ""
				echo "Last 30 lines of output:"
				tail -30 "$RESOLVE_LOG"
				rm -f "$RESOLVE_LOG"
				exit 1
			else
				echo -e "${YELLOW}⚠ Dependency resolution had issues (continuing)${NC}"
				tail -10 "$RESOLVE_LOG" 2>/dev/null || true
			fi
		fi
	else
		echo -e "${YELLOW}⚠ No timeout command available, resolving without timeout...${NC}"
		if $RESOLVE_CMD >"$RESOLVE_LOG" 2>&1; then
			echo -e "${GREEN}✓ Resolved${NC}"
		else
			echo -e "${YELLOW}⚠ Dependency resolution had issues (continuing)${NC}"
			tail -10 "$RESOLVE_LOG" 2>/dev/null || true
		fi
	fi

	rm -f "$RESOLVE_LOG"
fi
echo ""

# =============================================================================
# Select simulator
# =============================================================================
echo -e "${YELLOW}[7/10] Selecting iPhone simulator...${NC}"
SIMULATOR_INFO=$(
	python3 <<'PY'
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

# =============================================================================
# Boot simulator
# =============================================================================
echo -e "${YELLOW}[8/10] Booting simulator...${NC}"
xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || echo "Already booted"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b 2>/dev/null || true
echo -e "${GREEN}✓ Ready${NC}"
echo ""

# =============================================================================
# Build and Test (XcodeCloud parity or standard)
# =============================================================================
echo -e "${YELLOW}[9/10] Running tests (sanitizer: ${SANITIZER}, mode: ${CI_FLAVOR})...${NC}"
echo ""
rm -rf TestResults.xcresult coverage-report.txt coverage.json test_output.log build_output.log 2>/dev/null || true

# Clean DerivedData in XcodeCloud mode for fresh builds
if [ "$XCODECLOUD_MODE" = true ]; then
	echo "Cleaning DerivedData for XcodeCloud parity..."
	rm -rf "$DERIVED_DATA_PATH" 2>/dev/null || true
	mkdir -p "$DERIVED_DATA_PATH"
fi

# Determine sanitizer flags
SANITIZER_FLAGS=""
if [ "$SANITIZER" = "none" ]; then
	SANITIZER_FLAGS="-enableCodeCoverage YES"
elif [ "$SANITIZER" = "thread" ]; then
	SANITIZER_FLAGS="-enableThreadSanitizer YES"
elif [ "$SANITIZER" = "address" ]; then
	SANITIZER_FLAGS="-enableAddressSanitizer YES"
fi

# Build derived data argument
DERIVED_DATA_ARG=""
if [ -n "$DERIVED_DATA_PATH" ]; then
	DERIVED_DATA_ARG="-derivedDataPath '$DERIVED_DATA_PATH'"
fi

export NSUnbufferedIO=YES

# In XcodeCloud mode, run build-for-testing first (like XcodeCloud does)
if [ "$XCODECLOUD_MODE" = true ]; then
	echo "Running build-for-testing (XcodeCloud parity)..."
	echo ""

	BUILD_CMD="xcodebuild build-for-testing \
    -project PayBack.xcodeproj \
    -scheme PayBack \
    -destination 'platform=iOS Simulator,id=${SIMULATOR_UDID}' \
    $SANITIZER_FLAGS \
    $DERIVED_DATA_ARG \
    -parallel-testing-enabled YES"

	set +e
	if [ "$XCPRETTY_AVAILABLE" = true ]; then
		eval "$BUILD_CMD" 2>&1 | tee build_output.log | xcpretty --color --simple
		BUILD_EXIT_CODE=${PIPESTATUS[0]}
	else
		eval "$BUILD_CMD" 2>&1 | tee build_output.log
		BUILD_EXIT_CODE=${PIPESTATUS[0]}
	fi
	set -e

	if [ $BUILD_EXIT_CODE -ne 0 ]; then
		echo -e "${RED}✗ Build failed${NC}"

		# Check for warnings
		WARNING_COUNT=$(grep -c "warning:" build_output.log 2>/dev/null || echo "0")
		if [ "$WARNING_COUNT" -gt 0 ]; then
			echo ""
			echo -e "${YELLOW}Found $WARNING_COUNT warning(s):${NC}"
			grep "warning:" build_output.log | head -20 | sed 's/^/  /'
		fi

		exit 1
	fi

	echo -e "${GREEN}✓ Build succeeded${NC}"
	echo ""

	# Now run test-without-building
	echo "Running test-without-building..."
	echo ""

	TEST_CMD="xcodebuild test-without-building \
    -project PayBack.xcodeproj \
    -scheme PayBack \
    -destination 'platform=iOS Simulator,id=${SIMULATOR_UDID}' \
    $DERIVED_DATA_ARG \
    -parallel-testing-enabled YES \
    -resultBundlePath TestResults.xcresult"
else
	# Standard mode: single xcodebuild test command (matches CI)
	echo "Running all tests..."
	echo "This may take 2-5 minutes depending on your machine..."
	echo ""

	TEST_CMD="xcodebuild test \
    -project PayBack.xcodeproj \
    -scheme PayBack \
    -destination 'platform=iOS Simulator,id=${SIMULATOR_UDID}' \
    $SANITIZER_FLAGS \
    -parallel-testing-enabled YES \
    -resultBundlePath TestResults.xcresult"
fi

# Use timeout if available (30 minutes max for all tests)
if [ -n "$TIMEOUT_CMD" ]; then
	TEST_CMD="$TIMEOUT_CMD 1800 $TEST_CMD"
fi

# Show progress while tests run
if [ "$XCPRETTY_AVAILABLE" = true ]; then
	set +e
	eval "$TEST_CMD" 2>&1 | tee test_output.log | xcpretty --color --simple
	TEST_EXIT_CODE=${PIPESTATUS[0]}
	set -e

	# Check actual test results instead of just exit code
	ACTUAL_FAILURES=$(grep -E "Test Case.*failed \(" test_output.log 2>/dev/null | wc -l | xargs)
	TEST_RESULTS=$(grep -E "Executed.*tests.*with.*failure" test_output.log 2>/dev/null | tail -1)

	if [ $TEST_EXIT_CODE -eq 124 ]; then
		echo -e "${RED}✗ Tests timed out after 30 minutes${NC}"
		TEST_SUCCESS=false
	elif [ "$ACTUAL_FAILURES" = "0" ] && [[ "$TEST_RESULTS" == *"0 failures"* ]]; then
		TEST_SUCCESS=true
	elif [ $TEST_EXIT_CODE -eq 0 ]; then
		TEST_SUCCESS=true
	else
		TEST_SUCCESS=false
	fi
else
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

# =============================================================================
# Warning Analysis
# =============================================================================
echo -e "${YELLOW}[10/10] Analyzing warnings...${NC}"

# Combine build and test logs for warning analysis
cat build_output.log test_output.log 2>/dev/null >combined_output.log || cp test_output.log combined_output.log 2>/dev/null || true

# Filter out known tool noise that isn't actionable app code.
# Xcode 26+ can emit these even for apps that do not use AppIntents.
grep "warning:" combined_output.log 2>/dev/null |
	grep -v "appintentsmetadataprocessor" \
		>warnings_filtered.log ||
	true

WARNING_COUNT=$(wc -l <warnings_filtered.log 2>/dev/null | tr -d ' ' || echo "0")
if [ "$WARNING_COUNT" -gt 0 ]; then
	echo -e "${YELLOW}Found $WARNING_COUNT warning(s)${NC}"
	echo ""
	echo "Unique warnings (first 15):"
	sort -u warnings_filtered.log 2>/dev/null | head -15 | sed 's/^/  /'
	echo ""

	if [ "$FAIL_ON_WARNINGS" = "1" ]; then
		echo -e "${RED}✗ FAIL_ON_WARNINGS is enabled and warnings were found${NC}"
		WARNINGS_FAILED=true
	else
		echo -e "${YELLOW}⚠ Set FAIL_ON_WARNINGS=1 to fail on warnings${NC}"
		WARNINGS_FAILED=false
	fi
else
	echo -e "${GREEN}✓ No warnings detected${NC}"
	WARNINGS_FAILED=false
fi

rm -f combined_output.log warnings_filtered.log 2>/dev/null || true
echo ""

# =============================================================================
# Generate coverage and summary
# =============================================================================
echo -e "${YELLOW}Generating coverage report...${NC}"
echo ""

# Generate coverage if enabled
if [ "$SANITIZER" = "none" ] && [ -d "TestResults.xcresult" ]; then
	echo "Analyzing coverage data..."

	if xcrun xccov view --report --json TestResults.xcresult >coverage.json 2>&1; then
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
print(f"{BLUE}COMPREHENSIVE COVERAGE REPORT (Unit Tests){NC}")
print(f"{BLUE}{'=' * 80}{NC}\n")

# Functional code section
print(f"{MAGENTA}{'═' * 80}{NC}")
print(f"{MAGENTA}FUNCTIONAL CODE (Models, Services, Business Logic){NC}")
print(f"{MAGENTA}{'═' * 80}{NC}\n")

# Print top 20 lowest coverage functional files for improvement focus
print(f"{CYAN}Files needing attention (lowest coverage):{NC}")
print(f"{'-' * 80}")
sorted_functional = sorted(functional_files, key=lambda x: x[1])[:20]
for path, cov in sorted_functional:
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

# Service coverage section
print(f"{MAGENTA}{'═' * 80}{NC}")
print(f"{MAGENTA}SERVICE COVERAGE{NC}")
print(f"{MAGENTA}{'═' * 80}{NC}\n")

services = [
    'EmailAuthService',
    'PhoneAuthService',
    'AccountService',
    'GroupCloudService',
    'ExpenseCloudService',
    'InviteLinkService',
    'LinkRequestService',
]

for service in services:
    found = False
    for path, cov in functional_files:
        if service in path:
            if cov >= 90:
                color = GREEN
                icon = "✓"
            elif cov >= 70:
                color = YELLOW
                icon = "◐"
            else:
                color = RED
                icon = "✗"
            print(f"  {icon} {service:<45} {color}{cov:5.1f}%{NC}")
            found = True
            break
    if not found:
        print(f"  ? {service:<45} {YELLOW}Not found{NC}")

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
weighted_actual = (functional_cov * 0.7) + (ui_cov * 0.3) if (functional_files and ui_files) else overall

print(f"Functional Code:   {func_color}{functional_cov:5.1f}%{NC} (target: {functional_target:.0f}%) - {func_color}{func_status}{NC}")
print(f"UI Code:           {ui_color}{ui_cov:5.1f}%{NC} (target: {ui_target:.0f}%) - {ui_color}{ui_status}{NC}")
print(f"Overall Coverage:  {overall:.2f}%")
print(f"Weighted Score:    {weighted_actual:.2f}%\n")

# File counts
print(f"Files analyzed: {len(functional_files)} functional, {len(ui_files)} UI")

# Save text report
with open('coverage-report.txt', 'w') as f:
    f.write("PayBack Coverage Report\n")
    f.write("=" * 50 + "\n\n")
    f.write(f"Functional Code Coverage: {functional_cov:.2f}%\n")
    f.write(f"UI Code Coverage: {ui_cov:.2f}%\n")
    f.write(f"Overall Coverage: {overall:.2f}%\n")
    f.write(f"Weighted Score: {weighted_actual:.2f}%\n\n")
    
    f.write("Service Coverage:\n")
    for service in services:
        for path, cov in functional_files:
            if service in path:
                f.write(f"  {service}: {cov:.1f}%\n")
                break
    
    f.write("\nFiles needing attention:\n")
    for path, cov in sorted_functional:
        f.write(f"  {path}: {cov:.1f}%\n")

print(f"{GREEN}✓ Coverage report saved to coverage-report.txt{NC}")
PYCOV
	else
		echo -e "${YELLOW}⚠ Failed to generate coverage report${NC}"
	fi
else
	if [ "$SANITIZER" != "none" ]; then
		echo "Coverage disabled when using sanitizers"
	else
		echo -e "${YELLOW}⚠ No test results found for coverage${NC}"
	fi
fi

echo ""

# =============================================================================
# Final summary
# =============================================================================
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
if [ "$TEST_SUCCESS" = true ] && [ "$WARNINGS_FAILED" != true ]; then
	echo -e "${GREEN}  ✓ ALL TESTS PASSED${NC}"
	if [ "$XCODECLOUD_MODE" = true ]; then
		echo -e "${GREEN}  ✓ XcodeCloud parity mode completed successfully${NC}"
	fi
else
	if [ "$TEST_SUCCESS" != true ]; then
		echo -e "${RED}  ✗ SOME TESTS FAILED${NC}"
	fi
	if [ "$WARNINGS_FAILED" = true ]; then
		echo -e "${RED}  ✗ WARNINGS DETECTED (FAIL_ON_WARNINGS=1)${NC}"
	fi
fi
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Cleanup
rm -f test_output.log build_output.log 2>/dev/null || true

if [ "$TEST_SUCCESS" = true ] && [ "$WARNINGS_FAILED" != true ]; then
	exit 0
else
	exit 1
fi
