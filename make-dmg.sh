#!/bin/bash
# Builds a release .app and wraps it in a branded, compressed DMG in ./build.
#
#   ./make-dmg.sh                       → build/NotchOrbit-<version>.dmg (ad-hoc signed)
#   SIGN_IDENTITY="Developer ID Application: …" ./make-dmg.sh
#                                       → signed app + signed DMG, ready for notarytool
#
# The DMG window shows Assets/dmg-background.tiff (1x and 2x in one HiDPI TIFF, so
# it is sharp on Retina displays) with the app on the left and an Applications
# shortcut on the right (laid out through Finder), plus a volume icon. The image is
# LZMA-compressed (ULMO), which is noticeably smaller than zlib for the same content.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh release

APP="build/NotchOrbit.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
VOLNAME="NotchOrbit"
DMG="build/NotchOrbit-$VERSION.dmg"
RW_DMG="build/NotchOrbit-rw.dmg"
STAGING="build/dmg-staging"
MOUNT="/Volumes/$VOLNAME"

# Make sure a previous run isn't still mounted.
if [ -d "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet || true; fi

rm -rf "$STAGING" "$DMG" "$RW_DMG"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp Assets/dmg-background.tiff "$STAGING/.background/background.tiff"
cp Assets/AppIcon.icns "$STAGING/.VolumeIcon.icns"
cat > "$STAGING/Read Me.txt" <<EOF
NotchOrbit $VERSION
===================

Install
  1. Drag NotchOrbit onto the Applications folder in this window.
  2. Open Applications and double-click NotchOrbit. It runs in the menu bar
     (half-filled circle icon); there is no Dock icon.

First launch on macOS 15 (Sequoia) or later
  macOS may say the app "could not be verified" because this build is not
  notarized with Apple. Click Done, then open System Settings > Privacy &
  Security, scroll down and click "Open Anyway" next to NotchOrbit. Confirm
  once more and it starts normally from then on.

First launch on macOS 13 / 14
  Right-click (or Control-click) NotchOrbit in Applications, choose Open,
  then click Open in the dialog.

Alternative (Terminal)
  xattr -dr com.apple.quarantine /Applications/NotchOrbit.app

Permissions
  The Camera tab asks for camera and microphone access when first opened.
  The screenshot and screen-recording buttons need Screen Recording access;
  allow it in System Settings > Privacy & Security > Screen Recording and
  relaunch NotchOrbit.
  Weather mode with "Current location" asks for Location access; you can
  instead pick a city in Settings > Weather and skip the prompt.

Requirements
  macOS 13 or later, Apple silicon or Intel.

Verify the download
  The SHA-256 of this disk image is in the .sha256 file shipped with it:
  shasum -a 256 NotchOrbit-$VERSION.dmg
EOF

# Writable image first so Finder can store the window layout in its .DS_Store.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDRW -fs HFS+ "$RW_DMG" >/dev/null
hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -mountpoint "$MOUNT" >/dev/null
sleep 1

# Volume icon flag (SetFile ships with the Xcode command line tools).
if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$MOUNT" || true; fi

# Window layout. Needs Automation permission for Finder the first time; without it
# the DMG still works, just with Finder's default view. (Do not add Finder's
# `update` command here: it deletes .VolumeIcon.icns and clears the icon flag.)
LAYOUT_OK=1
osascript <<EOF >/dev/null 2>&1 || LAYOUT_OK=0
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 200, 1060, 600}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "NotchOrbit.app" of container window to {180, 185}
        set position of item "Applications" of container window to {480, 185}
        set position of item "Read Me.txt" of container window to {590, 100}
        close
        open
        delay 1
        close
    end tell
end tell
EOF
if [ "$LAYOUT_OK" = "1" ]; then
    echo "Finder layout applied"
else
    echo "warning: could not script Finder (allow Automation for your terminal in System Settings › Privacy & Security); using default layout" >&2
fi

sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
hdiutil convert "$RW_DMG" -format ULMO -ov -o "$DMG" >/dev/null
rm -rf "$RW_DMG" "$STAGING"
hdiutil verify "$DMG" >/dev/null

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    echo "Signed DMG. To notarize:"
    echo "  xcrun notarytool submit \"$DMG\" --keychain-profile <profile> --wait && xcrun stapler staple \"$DMG\""
fi

(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
echo "SHA-256: $(cut -d' ' -f1 "$DMG.sha256")  → $DMG.sha256"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    echo "Note: ad-hoc signed. Recipients must approve the first launch (see Read Me inside the DMG)."
fi
