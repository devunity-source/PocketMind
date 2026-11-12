#!/usr/bin/env bash
# Parses every Swift file of the app, its tests and the LocalAI package with the Swift
# compiler front end. This catches syntax errors on machines that cannot build for iOS
# (Linux, WSL). It does NOT type-check: only a macOS build proves the app compiles.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
count=0
while IFS= read -r file; do
  count=$((count + 1))
  if ! output=$(swiftc -frontend -parse "$file" 2>&1); then
    status=1
    echo "$output"
  elif [ -n "$output" ]; then
    echo "$output"
  fi
done < <(find App AppTests Packages/LocalAI/Sources -name '*.swift' | sort)

echo "Parsed $count files, status $status"
exit $status
