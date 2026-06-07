#!/usr/bin/env bash
#
# uninstall.sh — remove the audio driver and restart coreaudiod.
# Usage: Scripts/uninstall.sh
#
set -euo pipefail
DRIVER_DST="/Library/Audio/Plug-Ins/HAL/MuteMasterDriver.driver"

echo "▸ Removing $DRIVER_DST (sudo)…"
sudo rm -rf "$DRIVER_DST"
echo "▸ Restarting coreaudiod (sudo)…"
sudo killall coreaudiod || true
echo "✓ Uninstalled. (The privileged helper, if registered, can be removed from"
echo "  System Settings ▸ General ▸ Login Items, or via: sudo sfltool resetbtm)"
