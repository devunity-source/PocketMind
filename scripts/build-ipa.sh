#!/usr/bin/env bash
# macOS only. Builds an UNSIGNED PocketMind.ipa for a physical iPhone. The result must be
# signed before it can be installed (Sideloadly / AltStore with your Apple ID, or
# re-signing with your own certificate) — see docs/BUILD.md.
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/bootstrap.sh

# Device builds must include llama.cpp.
unset POCKETMIND_SIMULATOR_BUILD

xcodebuild build \
  -project PocketMind.xcodeproj \
  -scheme PocketMind \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath build/device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

APP="build/device/Build/Products/Release-iphoneos/PocketMind.app"
[ -d "$APP" ] || { echo "Build product not found at $APP" >&2; exit 1; }

rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
(cd build/ipa && zip -qry ../PocketMind-unsigned.ipa Payload)
echo "Created build/PocketMind-unsigned.ipa"
