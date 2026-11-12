#!/usr/bin/env bash
# Runs the PocketMindCore unit tests with SwiftPM. Works on macOS and on Linux
# (including WSL), so the platform-independent logic can be tested without a Mac.
#
#   scripts/test-core.sh                       # all tests
#   scripts/test-core.sh --filter StoreTests   # extra arguments go to `swift test`
#
# On WSL, set POCKETMIND_SCRATCH to a directory on the Linux file system: building
# inside /mnt/c is many times slower.
set -euo pipefail

cd "$(dirname "$0")/../Packages/PocketMindCore"

args=()
if [ -n "${POCKETMIND_SCRATCH:-}" ]; then
  mkdir -p "$POCKETMIND_SCRATCH"
  args+=(--scratch-path "$POCKETMIND_SCRATCH")
fi

swift --version
# The ${x[@]+...} form keeps macOS's bash 3.2 from treating an empty array as unbound.
swift test ${args[@]+"${args[@]}"} "$@"
