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

# Code sign with entitlements (required for SMAppService + Location).
#
# 优先使用**真实的签名身份**：ad-hoc 签名每次重建都会改变 cdhash，macOS 的 TCC 会把
# 新版当成另一个 app 从而回收定位权限 —— 于是 WiFi 白名单会静默失效（实测发生过：
# 一次重建之后整天 637 次检测全部读不到 SSID，而当时盖子合着没有屏幕显示授权弹窗）。
# 用固定身份的证书签名后，重建前后被认作同一个 app，权限不再被回收。
# 可用 SIGN_ID 环境变量显式指定；未找到证书时回退 ad-hoc。
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Developer ID Application|Apple Development|Mac Developer)[^"]*"' \
    | head -1 | tr -d '"')}"

if [ -n "$SIGN_ID" ]; then
    echo ""
    echo "  Signing with: $SIGN_ID"
    codesign -s "$SIGN_ID" --force --deep \
        --entitlements "$SCRIPT_DIR/Resources/AlwaysOn.entitlements" \
        "$APP_BUNDLE"
else
    echo ""
    echo "  Signing ad-hoc (no code-signing certificate found)."
    echo "  ⚠️  注意：ad-hoc 签名下，替换 app 会让 macOS 回收定位权限，WiFi 白名单会失效，"
    echo "      需要在菜单里点「定位权限」重新授权。安装一张 Apple 开发证书可永久解决。"
    codesign -s - --force --deep \
        --entitlements "$SCRIPT_DIR/Resources/AlwaysOn.entitlements" \
        "$APP_BUNDLE"
fi

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
