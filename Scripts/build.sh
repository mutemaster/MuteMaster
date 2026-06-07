#!/usr/bin/env bash
#
# build.sh — (re)generate the Xcode project and build everything (app + driver + helper).
# Usage: Scripts/build.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

echo "▸ Generating Xcode project from project.yml…"
xcodegen generate

echo "▸ Building (Debug)…"
xcodebuild -project MuteMaster.xcodeproj -scheme MuteMaster -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' build

echo "✓ Built: build/Build/Products/Debug/MuteMasterApp.app"
