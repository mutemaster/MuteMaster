#!/usr/bin/env bash
#
# run_tests.sh — run the test suite.
#   • DSP unit tests run anywhere.
#   • Audio integration tests run for real ONLY if the driver is installed
#     (Scripts/sign_and_install.sh); otherwise they self-skip.
#
# Usage: Scripts/run_tests.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "Note: the audio integration tests emit a brief 1 kHz tone through the VIRTUAL devices only"
echo "      (not your speakers). If other software is monitoring them, lower your volume first."
echo

command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null

xcodebuild -project MuteMaster.xcodeproj -scheme MuteMaster -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' test
