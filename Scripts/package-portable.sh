#!/usr/bin/env bash
#
# package-portable.sh — bundle the app + driver into a zip you can install on another Mac YOU CONTROL,
# without notarization. For personal/dev use only — to hand the app to other people, use the notarized
# path instead (see the shipping notes / SHIPPING.md).
#
# Produces: build/MuteMaster-portable.zip
#   ├─ MuteMasterApp.app
#   ├─ MuteMasterDriver.driver
#   ├─ install.sh        (run on the target Mac: de-quarantines + installs the driver + app)
#   └─ INSTALL.txt       (human instructions)
#
# Usage: Scripts/package-portable.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

PRODUCTS="$ROOT/build/Build/Products/Debug"
STAGE="$ROOT/build/MuteMaster-portable"
ZIP="$ROOT/build/MuteMaster-portable.zip"

# 1. Build app + driver + helper.
"$ROOT/Scripts/build.sh"

# 2. Ad-hoc sign the driver (build.sh signs the app; the driver bundle needs its own ad-hoc signature
#    so coreaudiod will load it — same step sign_and_install.sh does).
echo "▸ Ad-hoc signing the driver…"
codesign --force --deep --sign - "$PRODUCTS/MuteMasterDriver.driver"

# 3. Stage the payload.
echo "▸ Staging payload…"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$PRODUCTS/MuteMasterApp.app" "$STAGE/"
cp -R "$PRODUCTS/MuteMasterDriver.driver" "$STAGE/"

# 4. Write the on-target installer (quoted heredoc — nothing here is expanded at package time).
cat > "$STAGE/install.sh" <<'INSTALL'
#!/usr/bin/env bash
#
# install.sh — install MuteMaster on this Mac (a machine you control). Removes the quarantine flag,
# installs the audio driver into /Library/Audio/Plug-Ins/HAL, restarts coreaudiod, and copies the app
# to /Applications. Requires your admin password (sudo).
#
# Run it from Terminal:  bash install.sh
#
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
APP="$DIR/MuteMasterApp.app"
DRIVER="$DIR/MuteMasterDriver.driver"

echo "▸ Removing quarantine flag…"
xattr -dr com.apple.quarantine "$APP" "$DRIVER" 2>/dev/null || true

echo "▸ Installing the audio driver to $HAL_DIR (sudo)…"
sudo mkdir -p "$HAL_DIR"
sudo rm -rf "$HAL_DIR/MuteMasterDriver.driver"
sudo cp -R "$DRIVER" "$HAL_DIR/"
sudo chown -R root:wheel "$HAL_DIR/MuteMasterDriver.driver"

echo "▸ Restarting coreaudiod (sudo)…"
sudo killall coreaudiod || true
sleep 3

echo "▸ Installing the app to /Applications…"
rm -rf "/Applications/MuteMasterApp.app"
cp -R "$APP" "/Applications/"

echo "▸ Verifying the virtual devices…"
if system_profiler SPAudioDataType | grep -qE "Mutable Microphone|Mutable Speaker"; then
  echo "✓ Devices installed:"
  system_profiler SPAudioDataType | grep -E "Mutable Microphone|Mutable Speaker"
  echo "✓ Launch MuteMaster from /Applications (first launch: right-click ▸ Open if Gatekeeper warns)."
else
  echo "✗ Devices not visible. coreaudiod may have refused the ad-hoc driver on this macOS version —"
  echo "  in that case you need the notarized build. Diagnose with:"
  echo "    log show --predicate 'subsystem == \"com.apple.coreaudio\"' --last 2m --info --debug | grep -i mutemaster"
  exit 1
fi
INSTALL
chmod +x "$STAGE/install.sh"

# 5. Write human-readable instructions.
cat > "$STAGE/INSTALL.txt" <<'TXT'
MuteMaster — portable install (for a Mac you control)

1. Copy this whole folder to the target Mac (AirDrop / USB / etc.).
2. Open Terminal, cd into this folder, and run:

       bash install.sh

   It will ask for your admin password (to install the audio driver and restart Core Audio).
3. Launch "MuteMaster" from /Applications. On first launch, if macOS warns the developer can't be
   verified, right-click the app ▸ Open ▸ Open. Grant microphone access when prompted.
4. In your call app, set Microphone = "Mutable Microphone" and Speaker = "Mutable Speaker".

To uninstall:
       sudo rm -rf /Library/Audio/Plug-Ins/HAL/MuteMasterDriver.driver
       sudo killall coreaudiod
       rm -rf /Applications/MuteMasterApp.app

Note: this is an ad-hoc-signed, un-notarized build intended for personal use on machines you own.
TXT

# 6. Zip with ditto (preserves bundle structure and code signatures).
echo "▸ Zipping…"
rm -f "$ZIP"
( cd "$ROOT/build" && ditto -c -k --sequesterRsrc --keepParent "MuteMaster-portable" "MuteMaster-portable.zip" )

echo "✓ Portable package: $ZIP"
echo "  Copy it to the target Mac, unzip, and run: bash MuteMaster-portable/install.sh"
