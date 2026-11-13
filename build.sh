#!/bin/bash
# Builds NotchOrbit and assembles a double-clickable .app bundle in ./build
#
#   ./build.sh [debug|release]      build (release by default)
#   ./build.sh clean                remove ./build and SwiftPM's .build (≈1 GB after a few builds)
#
# Release builds are optimised for size (-Osize), fully stripped, and universal
# (Apple silicon + Intel). ARCHS="arm64" ./build.sh makes a single-architecture
# build at roughly half the binary size.
#
# Signing: ad-hoc by default (fine for your own Mac). For distribution set
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh release
# which signs with the hardened runtime + NotchOrbit.entitlements, ready to notarize.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"

# SwiftUI's property wrappers are macros in recent SDKs, and their compiler plugin ships
# with Xcode, not with the Command Line Tools. If the Command Line Tools are selected,
# use an installed Xcode for this build without changing the system setting.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
    for candidate in /Applications/Xcode*.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
APP="build/NotchOrbit.app"
IDENTITY="${SIGN_IDENTITY:-}"
ARCHS="${ARCHS:-arm64 x86_64}"

if [ "$CONFIG" = "clean" ]; then
    rm -rf build .build
    echo "Removed build/ and .build/"
    exit 0
fi

if [ "$CONFIG" = "release" ]; then
    ARCH_FLAGS=()
    for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
    swift build -c release "${ARCH_FLAGS[@]}" -Xswiftc -Osize 2> >(grep -v "x86_64 architecture is deprecated" >&2)
    BINARY=".build/out/Products/Release/NotchOrbit"
    [ -f "$BINARY" ] || BINARY=".build/apple/Products/Release/NotchOrbit"
    [ -f "$BINARY" ] || BINARY=".build/release/NotchOrbit"
else
    swift build -c "$CONFIG"
    BINARY=".build/$CONFIG/NotchOrbit"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/NotchOrbit"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Assets/AppIcon.icns ] && cp Assets/AppIcon.icns "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ "$CONFIG" = "release" ]; then
    # Keep the debug symbols as a dSYM for crash logs, then strip everything from
    # the shipped binary (nothing loads symbols from it at runtime).
    dsymutil "$APP/Contents/MacOS/NotchOrbit" -o "build/NotchOrbit.dSYM" >/dev/null 2>&1 || true
    strip "$APP/Contents/MacOS/NotchOrbit" 2>/dev/null || strip -x "$APP/Contents/MacOS/NotchOrbit" 2>/dev/null || true
fi

if [ -n "$IDENTITY" ]; then
    codesign --force --deep --options runtime --timestamp \
             --entitlements NotchOrbit.entitlements --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    # Ad-hoc signature so macOS is happy to launch it locally.
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi
codesign --verify --deep --strict "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/NotchOrbit"), $(du -sh "$APP" | cut -f1))"
