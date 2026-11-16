#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="糕咖啡"
EXEC_NAME="AlwaysOn"      # 内部二进制名（ps / pkill 用它）
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications"
# 旧 bundle 名：安装时一并清掉，避免磁盘上同时存在两个副本
LEGACY_BUNDLES=("AlwaysOn.app")

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: $APP_BUNDLE not found. Run ./build.sh first."
    exit 1
fi

echo "Installing $APP_NAME to $INSTALL_DIR..."

pkill -x "$EXEC_NAME" 2>/dev/null || true
sleep 1

for legacy in "${LEGACY_BUNDLES[@]}"; do
    if [ -d "$INSTALL_DIR/$legacy" ]; then
        echo "  移除旧版本: $INSTALL_DIR/$legacy"
        rm -rf "$INSTALL_DIR/$legacy"
    fi
done

rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP_BUNDLE" "$INSTALL_DIR/"

echo "Installed to $INSTALL_DIR/$APP_NAME.app"

echo ""
echo "Setting up configuration..."
CONFIG_DIR="$HOME/.alwayson"
mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
    cat > "$CONFIG_DIR/config.json" << 'EOF'
{
  "ac_mode": "always",
  "battery_mode": "whitelist",
  "battery_floor": 5,
  "check_interval": 60,
  "guard_interval": 1.0,
  "mute_when_lid_closed": true,
  "enable_wake_on_power": true,
  "enabled": true,
  "whitelist_wifi": []
}
EOF
    echo "Created default config at $CONFIG_DIR/config.json"
    echo "Edit this file to add trusted WiFi networks."
fi

echo ""
echo "To launch:"
echo "  open \"/Applications/$APP_NAME.app\""