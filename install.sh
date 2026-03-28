#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AlwaysOn"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: $APP_BUNDLE not found. Run ./build.sh first."
    exit 1
fi

echo "Installing $APP_NAME to $INSTALL_DIR..."

pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

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
  "whitelist_wifi": [],
  "check_interval": 60,
  "enable_wake_on_power": true
}
EOF
    echo "Created default config at $CONFIG_DIR/config.json"
    echo "Edit this file to add trusted WiFi networks."
fi

echo ""
echo "To launch:"
echo "  open \"/Applications/$APP_NAME.app\""