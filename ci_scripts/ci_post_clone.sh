#!/bin/sh

# Xcode Cloud Post-Clone Script
# This script runs after Xcode Cloud clones your repository
# It creates a dummy GoogleService-Info.plist for building without real credentials

set -e

echo "Creating dummy GoogleService-Info.plist for Xcode Cloud build..."

# Navigate to repository root (ci_scripts is inside the repo)
cd "$(dirname "$0")/.."

cat > "apps/ios/PayBack/GoogleService-Info.plist" <<'EOF'
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

echo "✓ GoogleService-Info.plist created successfully"
