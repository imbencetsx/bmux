#!/bin/sh
# Reproducible bootstrap: verifies toolchain, fetches SPM deps (incl. libghostty).
set -eu
cd "$(dirname "$0")/.."

echo "== Toolchain =="
xcodebuild -version
swift --version
zig version || echo "(zig optional for Phase 1 SPM binary; required to rebuild libghostty from source)"
xcrun -sdk macosx --show-sdk-version

echo "== Resolve dependencies =="
swift package resolve

echo "== Build =="
swift build

echo "OK. Run with: swift run bmux"
