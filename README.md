<p align="center">
  <img src="site/icon.svg" width="120" height="120" alt="AlwaysOn">
</p>

<h1 align="center">AlwaysOn</h1>

<p align="center">
  <strong>Your Mac, always awake.</strong><br>
  Keep your Mac running with the lid closed. Built for the AI Agent era.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-000?style=flat-square&logo=apple&logoColor=fff" alt="macOS 13+">
  <img src="https://img.shields.io/badge/arch-Universal%20Binary-000?style=flat-square" alt="Universal Binary">
  <img src="https://img.shields.io/badge/language-Swift-000?style=flat-square&logo=swift&logoColor=F05138" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-000?style=flat-square" alt="MIT">
</p>

<p align="center">
  <a href="#install">Install</a> · <a href="#configuration">Configuration</a> · <a href="#menu-bar">Menu Bar</a>
</p>

---

## Features

- **Clamshell sleep prevention** -- Uses `pmset disablesleep 1` to keep your Mac running with the lid closed. WiFi stays connected, processes keep running.
- **AC mode** -- Choose "always awake on AC" (default) or "AC + WiFi required".
- **Battery mode** -- Choose "whitelist WiFi only" (default) or "any WiFi".
- **Manual toggle** -- Enable/disable sleep prevention from the menu bar. Persisted across restarts.
- **WiFi whitelist** -- Add/remove WiFi networks from the menu bar. Whitelist WiFi keeps your Mac awake even on battery.
- **Smart battery protection** -- Monitors battery every 60 seconds. Auto-sleeps at 5% with lid closed.
- **Deep sleep prevention** -- Disables `standby` and `autopoweroff` when active, preventing the system from entering deep sleep.
- **Launch at login** -- Uses SMAppService (macOS 13+).
- **Native menu bar** -- SF Symbols icons, no Dock icon, no Electron.
- **Bilingual** -- English and Simplified Chinese, auto-detected.

---

## Install

### Download

Download `AlwaysOn.zip`, unzip, and drag to `/Applications`. First launch: right-click -> Open.

### Build from source

```bash
git clone <repo-url>
cd AlwaysOn
./build.sh
./install.sh   # copies to /Applications
```

Requires: macOS 13+, Xcode Command Line Tools (for `swiftc`).

---

## Configuration

Config file: `~/.alwayson/config.json`

```json
{
  "ac_mode": "always",
  "battery_mode": "whitelist",
  "check_interval": 60,
  "enable_wake_on_power": true,
  "enabled": true,
  "whitelist_wifi": ["Home WiFi", "Office 5G"]
}
```

| Field | Description | Default |
|:---|:---|:---|
| `enabled` | Master switch for sleep prevention | `true` |
| `ac_mode` | `"always"` (AC = always awake) or `"wifi_required"` (AC + WiFi) | `"always"` |
| `battery_mode` | `"whitelist"` (whitelist WiFi only) or `"any_wifi"` (any WiFi) | `"whitelist"` |
| `whitelist_wifi` | WiFi networks that keep your Mac awake on battery | `[]` |
| `check_interval` | Check interval in seconds (1-300) | `60` |
| `enable_wake_on_power` | Wake from sleep when power is connected | `true` |

---

## Menu Bar

```
cup.and.saucer.fill / moon.zzz
├── Will stay awake after lid close
├── Disable Sleep Prevention
├── ──────────────
├── Power: Power Adapter
├── Lid: Open
├── ──────────────
├── WiFi: Home WiFi
├── Add "Home WiFi" to Whitelist
├── ──────────────
├── AC Mode: Always Awake        ✓
├── AC Mode: WiFi Required
├── Battery Mode: Whitelist WiFi Only  ✓
├── Battery Mode: Any WiFi
├── ──────────────
├── ✓ Launch at Login
├── Open Config Folder
├── ──────────────
└── Quit AlwaysOn (⌘Q)
```

**Icons:**
- Coffee cup (`cup.and.saucer.fill`) = will stay awake
- Moon (`moon.zzz`) = will not stay awake

---

## How It Works

AlwaysOn uses `pmset disablesleep 1` as the sole mechanism to prevent sleep. This is the only reliable way to prevent macOS clamshell sleep.

When active, it also sets:
- `standby 0` and `autopoweroff 0` to prevent deep sleep
- `disksleep 0` and `networkoversleep 1` to keep disk and network alive
- `tcpkeepalive 1` to maintain network connections

When disabled, all settings are restored to macOS defaults.

---

## Permissions

### pmset (required)
First launch prompts for your password once. Creates `/etc/sudoers.d/pmset` allowing passwordless `pmset` only.

### Location Services (optional, for WiFi whitelist)
Required to read WiFi SSID. macOS requires Location Services permission for this. No actual location data is used.

---

## Uninstall

1. Click **Quit** in the menu bar (restores default power settings)
2. Delete `AlwaysOn.app` from `/Applications`
3. Optional: `rm -rf ~/.alwayson`
4. Optional: `sudo rm /etc/sudoers.d/pmset`

---

## Technical Specs

| | |
|:--|:--|
| **Language** | Pure Swift (swiftc, no Xcode project) |
| **Binary** | Universal (arm64 + x86_64) |
| **Frameworks** | AppKit, IOKit, ServiceManagement, CoreWLAN, CoreLocation |
| **Sleep control** | `pmset disablesleep 1` |
| **Privileges** | `/etc/sudoers.d/pmset` |
| **Login item** | SMAppService (macOS 13+) |
| **Signing** | Ad-hoc codesigned with entitlements |
| **Minimum OS** | macOS 13.0 (Ventura) |

---

## License

MIT
