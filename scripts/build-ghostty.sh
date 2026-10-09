#!/usr/bin/env bash
# Builds GhosttyKit.xcframework (libghostty) from vendor/ghostty.
# Requires: Zig 0.16.x (.tools/zig or on PATH), Xcode with the Metal Toolchain
#   (xcodebuild -downloadComponent MetalToolchain).
set -euo pipefail
cd "$(dirname "$0")/.."

GHOSTTY_REPO=https://github.com/ghostty-org/ghostty
GHOSTTY_COMMIT=$(cat ghostty.commit)

if [ ! -d vendor/ghostty/.git ]; then
  git clone "$GHOSTTY_REPO" vendor/ghostty
fi
git -C vendor/ghostty fetch --depth 1 origin "$GHOSTTY_COMMIT" 2>/dev/null || true
git -C vendor/ghostty checkout -q "$GHOSTTY_COMMIT"

ZIG=${ZIG:-$(pwd)/.tools/zig/zig}
[ -x "$ZIG" ] || ZIG=$(command -v zig)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

cd vendor/ghostty
"$ZIG" build -Doptimize=ReleaseFast \
  -Demit-xcframework=true -Dxcframework-target=native \
  -Demit-macos-app=false -Demit-exe=false -Demit-docs=false
echo "Built vendor/ghostty/macos/GhosttyKit.xcframework"
