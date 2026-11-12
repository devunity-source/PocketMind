#!/usr/bin/env bash
# macOS only. Runs every test: the core package with SwiftPM, then the app tests on an
# iPhone simulator.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== PocketMindCore (SwiftPM)"
bash scripts/test-core.sh

echo "== App tests (iOS simulator)"
bash scripts/bootstrap.sh

# First available iPhone simulator, e.g. "iPhone 17".
DEVICE="${POCKETMIND_SIMULATOR:-$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]+' | sed 's/ *$//')}"
echo "Using simulator: $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
# Lets the recorder lifecycle tests run instead of skipping.
xcrun simctl privacy booted grant microphone app.pocketmind.PocketMind || true

xcodebuild test \
  -project PocketMind.xcodeproj \
  -scheme PocketMind \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO
