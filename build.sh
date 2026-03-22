#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  build.sh  –  Compile and bundle LilFinderGuy
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="LilFinderGuy"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# ── Detect native arch ────────────────────────────────────────────────────────
ARCH=$(uname -m)
TARGET="${ARCH}-apple-macosx11.0"

# ── Clean ─────────────────────────────────────────────────────────────────────
echo "→ Cleaning build dir..."
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# ── Check for required video assets ──────────────────────────────────────────
for ASSET in "LilFinder_Sitting_1.png" "LilFinder_Sleeps.mp4" "LilFinder_Wakesup.mp4"; do
    if [ ! -f "Resources/$ASSET" ]; then
        echo ""
        echo "⚠️  ERROR: Resources/$ASSET not found!"
        echo "   Save the file to:  $SCRIPT_DIR/Resources/$ASSET"
        echo "   Then run this script again."
        echo ""
        exit 1
    fi
done

# ── Compile ───────────────────────────────────────────────────────────────────
echo "→ Compiling Swift ($TARGET)..."
swiftc \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    Sources/DockAnimator.swift \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework CoreImage \
    -target "$TARGET" \
    -O

# ── Copy resources ────────────────────────────────────────────────────────────
echo "→ Copying resources..."
cp Resources/Info.plist              "$CONTENTS/Info.plist"
cp Resources/LilFinder_Sitting_1.png "$RESOURCES_DIR/"
cp Resources/LilFinder_Sleeps.mp4    "$RESOURCES_DIR/"
cp Resources/LilFinder_Wakesup.mp4   "$RESOURCES_DIR/"

# ── Ad-hoc sign (required on macOS 12+) ──────────────────────────────────────
echo "→ Stripping quarantine attributes..."
xattr -cr "$APP_BUNDLE"
echo "→ Code signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "✅  Built:  $APP_BUNDLE"
echo ""
echo "  Run now:          open \"$APP_BUNDLE\""
echo "  Install to Apps:  cp -r \"$APP_BUNDLE\" /Applications/"
echo ""
echo "Once running, click the character in the Dock to make him stand up"
echo "and open Finder. He'll sit back down after ~3.5 seconds."
echo ""
