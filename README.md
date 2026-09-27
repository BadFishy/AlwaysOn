<p align="center">
  <img src="site/icon.svg" width="120" height="120" alt="AlwaysOn">
</p>

<h1 align="center">AlwaysOn</h1>

<p align="center">
  <a href="./README_CN.md">📖 中文文档</a>
</p>

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
- **1-second watchdog + power events** -- `disablesleep` is a *global* flag that other software (and the OS) can clear at any time. AlwaysOn verifies it every second by reading the kernel state directly (IORegistry, no subprocess) and re-asserts immediately. It also subscribes to `IOPMrootDomain` power events — notably the clamshell notification, which Apple documents as arriving *before* the sleep begins.
- **AC mode** -- Choose "always awake on AC" (default) or "AC + WiFi required".
- **Battery mode** -- Choose "whitelist WiFi only" (default) or "any WiFi".
- **Manual toggle** -- Enable/disable sleep prevention from the menu bar. Persisted across restarts.
- **WiFi whitelist** -- Add/remove WiFi networks from the menu bar. Whitelist WiFi keeps your Mac awake even on battery.
- **Battery floor** -- Below a configurable charge level (default 5%) on battery, prevention is released and the Mac is allowed to sleep, so it can never drain to a hard shutdown.
- **Honest status** -- The menu bar reflects the *real* kernel state, not a prediction. If something else overrides the flag and AlwaysOn cannot win, you get a ⚠️ state instead of a false "will stay awake".
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
  "battery_floor": 5,
  "check_interval": 60,
  "guard_interval": 1.0,
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
| `battery_floor` | On battery, release prevention at/below this charge (%). `0` disables the guard | `5` |
| `check_interval` | Condition re-check interval in seconds (5-300) | `60` |
| `guard_interval` | How often the `disablesleep` flag is verified, in seconds (0.5-10) | `1.0` |
| `enable_wake_on_power` | Turn on Wake for Network Access (`womp 1`) | `true` |

Missing or malformed fields fall back to their defaults individually — a partially
written config never wipes your whitelist.

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
├── Battery floor: allow sleep below 5%
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

AlwaysOn uses `pmset disablesleep 1` and **nothing else** — it is the only reliable way to
prevent macOS clamshell sleep. Public power assertions (including `caffeinate`) do not
prevent lid-close sleep; Apple's own `IOPMLib.h` says the system *"may still sleep for lid
close, Apple menu, low battery, or other sleep reasons"*.

**It changes exactly one setting.** Earlier versions also rewrote `sleep`, `displaysleep`,
`standby`, `autopoweroff`, `disksleep`, `tcpkeepalive` and `networkoversleep`, then "restored"
them to hardcoded guesses on exit — which permanently clobbered the user's real configuration.
That is gone: nothing but `disablesleep` is written, so there is nothing to restore.

Because `disablesleep` is a single global flag, anything on the system can clear it.
AlwaysOn therefore:

- verifies it **every second** by reading `IOPMrootDomain`'s `SleepDisabled` straight from
  the IORegistry (~7 µs, no subprocess) and re-asserts within milliseconds;
- subscribes to `IOPMrootDomain` power events, including `kIOPMMessageClamshellStateChange`,
  which Apple documents as being delivered **before** a clamshell sleep begins.

### Logs
`~/.alwayson/logs/` — one file per day, rotated at 5 MB, older than 7 days removed.

---

## Permissions

### pmset (required)
First launch shows an explanation, then the macOS password prompt once. It installs a
**scoped** sudoers rule — `/etc/sudoers.d/alwayson-pmset` — that allows exactly these
commands and nothing else:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a womp 0
/usr/bin/pmset -a womp 1
/usr/bin/pmset sleepnow
```

The rule is validated with `visudo -c` and self-tested inside the same privileged session
before the old rule is retired; if the self-test fails it rolls back automatically. The menu
shows the current grant state and lets you re-run this at any time. Declining is fine — the
app keeps running and reports `⚠️ Not effective` rather than pretending to work.

### Location Services (optional, for WiFi whitelist)
Required to read the WiFi SSID. macOS requires Location Services for this. No location data
is used or stored. Without it the SSID reads as *unavailable* and AlwaysOn keeps its previous
decision instead of assuming you are on an untrusted network.

---

## Uninstall

1. Click **Quit** in the menu bar (releases sleep prevention)
2. Delete `AlwaysOn.app` from `/Applications`
3. Optional: `rm -rf ~/.alwayson`
4. Optional: `sudo rm /etc/sudoers.d/alwayson-pmset`

---

## Technical Specs

| | |
|:--|:--|
| **Language** | Pure Swift (swiftc, no Xcode project) |
| **Binary** | Universal (arm64 + x86_64) |
| **Frameworks** | AppKit, IOKit, ServiceManagement, CoreWLAN, CoreLocation |
| **Sleep control** | `pmset disablesleep 1` |
| **Privileges** | `/etc/sudoers.d/alwayson-pmset` (5 exact commands) |
| **Login item** | SMAppService (macOS 13+) |
| **Signing** | Ad-hoc codesigned with entitlements |
| **Minimum OS** | macOS 13.0 (Ventura) |

---

## License

MIT
