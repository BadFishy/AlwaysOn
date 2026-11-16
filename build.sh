#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# bundle 的显示名（Finder 里看到的）与内部可执行文件名是两件事：
# 改 bundle 名不会动 CFBundleExecutable，所以登录项/ps/pkill 仍然认 AlwaysOn。
APP_NAME="糕咖啡"
EXEC_NAME="AlwaysOn"
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
    "$SWIFTC" -o "$TMPDIR_BUILD/$EXEC_NAME-$ARCH" \
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
    "$TMPDIR_BUILD/$EXEC_NAME-arm64" \
    "$TMPDIR_BUILD/$EXEC_NAME-x86_64" \
    -output "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
rm -rf "$TMPDIR_BUILD"

# Code sign with entitlements (required for SMAppService + Location).
#
# 为什么要固定签名身份：ad-hoc 签名每次重建都会改变 cdhash，macOS 的 TCC 会把新版当成
# 另一个 app 从而回收定位权限 —— 于是 WiFi 白名单静默失效（实测发生过：一次重建之后
# 整天 637 次检测全部读不到 SSID，而当时盖子合着、没有屏幕显示授权弹窗）。
#
# 优先用**本地自签身份**（放在独立钥匙串里，密码在 ~/.alwayson/signing/keychain.pass）：
# 它的 designated requirement 只有 `identifier + certificate root`，不含 cdhash，
# 所以重建后身份不变、权限不会被回收，而且全程无需钥匙串弹窗。
#
# 想用 Apple 开发者证书：先由你自己在终端里跑一次（会提示输入登录密码，别把它交给我）
#   security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
#     -k "" -t private "Apple Development: <你的名字> (XXXXXXXXXX)"
# 然后用 SIGN_ID="Apple Development: ..." ./build.sh 覆盖。
LOCAL_KEYCHAIN="${LOCAL_KEYCHAIN:-$HOME/Library/Keychains/coffeeguard-signing.keychain-db}"
LOCAL_PASS_FILE="${LOCAL_PASS_FILE:-$HOME/.alwayson/signing/keychain.pass}"
LOCAL_SIGN_NAME="${LOCAL_SIGN_NAME:-CoffeeGuard Local Signing}"

SIGN_ID="${SIGN_ID:-}"
if [ -z "$SIGN_ID" ] && [ -f "$LOCAL_PASS_FILE" ] && [ -f "$LOCAL_KEYCHAIN" ]; then
    security unlock-keychain -p "$(cat "$LOCAL_PASS_FILE")" "$LOCAL_KEYCHAIN" >/dev/null 2>&1 || true
    if security find-certificate -c "$LOCAL_SIGN_NAME" "$LOCAL_KEYCHAIN" >/dev/null 2>&1; then
        SIGN_ID="$LOCAL_SIGN_NAME"
    fi
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"(Developer ID Application|Apple Development|Mac Developer)[^"]*"' \
        | head -1 | tr -d '"')"
fi

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
"$LIPO" -archs "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME" | sed 's/^/  archs: /'
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
