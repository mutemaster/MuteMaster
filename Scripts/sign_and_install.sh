#!/usr/bin/env bash
#
# sign_and_install.sh — local-dev install of the audio driver (the M0/M1 gate).
#
# Builds, ad-hoc signs the driver, copies it into /Library/Audio/Plug-Ins/HAL, and restarts
# coreaudiod so the Mutable Microphone / Mutable Speaker devices appear. Requires sudo (writing to /Library).
#
# Usage: Scripts/sign_and_install.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DRIVER_SRC="$ROOT/build/Build/Products/Debug/MuteMasterDriver.driver"
DRIVER_DST="$HAL_DIR/MuteMasterDriver.driver"

"$ROOT/Scripts/build.sh"

echo "▸ Ad-hoc signing the driver…"
codesign --force --deep --sign - "$DRIVER_SRC"
codesign -dvvv "$DRIVER_SRC" 2>&1 | grep -E "Signature|Identifier" || true

echo "▸ Installing to $HAL_DIR (sudo)…"
sudo mkdir -p "$HAL_DIR"
sudo rm -rf "$DRIVER_DST"
sudo cp -R "$DRIVER_SRC" "$DRIVER_DST"
sudo chown -R root:wheel "$DRIVER_DST"

echo "▸ Restarting coreaudiod (sudo)…"
sudo killall coreaudiod || true
sleep 3

echo "▸ Checking for the virtual devices…"
if system_profiler SPAudioDataType | grep -qE "Mutable Microphone|Mutable Speaker"; then
  echo "✓ Success — devices installed:"
  system_profiler SPAudioDataType | grep -E "Mutable Microphone|Mutable Speaker"
else
  echo "✗ Devices not visible yet. Diagnose with:"
  echo "    log show --predicate 'subsystem == \"com.apple.coreaudio\"' --last 2m --info --debug | grep -i mutemaster"
  exit 1
fi
