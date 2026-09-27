#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AlwaysOn"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

# Xcode 的 /usr/bin/swiftc 是个 shim：未同意 Xcode 许可协议时会直接报
# "You have not agreed to the Xcode license agreements" 并退出。
# 直接调用 CommandLineTools 里的工具链本体可以绕过该 shim（实测可用）。
TOOLCHAIN="${TOOLCHAIN:-/Library/Developer/CommandLineTools/usr/bin}"
SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
SWIFTC="$TOOLCHAIN/swiftc"
# /usr/bin/lipo 同样是 Xcode shim（未同意许可时报错），/usr/bin/codesign 是真身
LIPO="$TOOLCHAIN/lipo"
[ -x "$LIPO" ] || LIPO="/usr/bin/lipo"

if [ ! -x "$SWIFTC" ] || [ ! -d "$SDK" ]; then
    echo "  (回退到 xcrun)"
    SWIFTC="$(xcrun --find swiftc)"
    SDK="$(xcrun --show-sdk-path)"
fi

echo "Building $APP_NAME..."
echo "  toolchain: $SWIFTC"
echo "  sdk:       $SDK"

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create .app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy Info.plist, icon and localizations
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

for lproj in en zh-Hans; do
    if [ -d "$SCRIPT_DIR/Resources/$lproj.lproj" ]; then
        cp -R "$SCRIPT_DIR/Resources/$lproj.lproj" "$APP_BUNDLE/Contents/Resources/"
    fi
done

# Build universal binary (arm64 + x86_64)
TMPDIR_BUILD=$(mktemp -d)
for ARCH in arm64 x86_64; do
    echo "  Compiling for $ARCH..."
    "$SWIFTC" -o "$TMPDIR_BUILD/$APP_NAME-$ARCH" \
        -sdk "$SDK" \
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
"$LIPO" -create \
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
"$LIPO" -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | sed 's/^/  archs: /'
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
