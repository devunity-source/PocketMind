#!/usr/bin/env bash
# macOS only. Installs XcodeGen if needed and generates PocketMind.xcodeproj.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname)" != "Darwin" ]; then
  echo "The iOS app can only be built on macOS with Xcode. On Windows/Linux use GitHub Actions (docs/BUILD.md)." >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Installing XcodeGen with Homebrew…"
  brew install xcodegen
fi

xcodegen generate
echo "Generated PocketMind.xcodeproj. Open it with:  open PocketMind.xcodeproj"
