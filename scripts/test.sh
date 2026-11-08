#!/usr/bin/env bash
# Runs the unit tests. Works with full Xcode or only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swiftpm-flags.sh
# `${arr[@]+"${arr[@]}"}`: macOS's bash 3.2 treats an empty array as unbound under `set -u`.
swift test "${SWIFTPM_FLAGS[@]}" ${SWIFTPM_TEST_FLAGS[@]+"${SWIFTPM_TEST_FLAGS[@]}"} "$@"
