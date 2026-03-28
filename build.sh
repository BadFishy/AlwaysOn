#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AlwaysOn"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create .app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy Info.plist, icon and localizations
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Copy localization directories
if [ -d "$SCRIPT_DIR/Resources/en.lproj" ]; then
    cp -R "$SCRIPT_DIR/Resources/en.lproj" "$APP_BUNDLE/Contents/Resources/"
fi
if [ -d "$SCRIPT_DIR/Resources/zh-Hans.lproj" ]; then
    cp -R "$SCRIPT_DIR/Resources/zh-Hans.lproj" "$APP_BUNDLE/Contents/Resources/"
fi

# Build universal binary (arm64 + x86_64)
TMPDIR_BUILD=$(mktemp -d)
for ARCH in arm64 x86_64; do
    echo "  Compiling for $ARCH..."
    swiftc -o "$TMPDIR_BUILD/$APP_NAME-$ARCH" \
        -target "${ARCH}-apple-macosx13.0" \
        -framework AppKit \
        -framework IOKit \
        -framework ServiceManagement \
        -framework UserNotifications \
        -framework CoreWLAN \
        -framework CoreLocation \
        -O \
        "$SCRIPT_DIR/Sources/"*.swift
done

echo "  Creating universal binary..."
lipo -create \
    "$TMPDIR_BUILD/$APP_NAME-arm64" \
    "$TMPDIR_BUILD/$APP_NAME-x86_64" \
    -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
rm -rf "$TMPDIR_BUILD"

# Ad-hoc code sign with entitlements (required for SMAppService + Location)
codesign -s - --force --deep \
    --entitlements "$SCRIPT_DIR/Resources/AlwaysOn.entitlements" \
    "$APP_BUNDLE"

echo ""
echo "Build successful: $APP_BUNDLE"
echo ""
echo "Run with:"
echo "  open $APP_BUNDLE"

# Create distributable zip
ZIP_PATH="$SCRIPT_DIR/$APP_NAME.zip"
rm -f "$ZIP_PATH"
cd "$SCRIPT_DIR"
ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_PATH"
echo ""
echo "Distributable zip: $ZIP_PATH"
echo "  (Send this file — preserves code signature and app structure)"
