<p align="center">
  <img src="site/icon.svg" width="120" height="120" alt="AlwaysOn">
</p>

<h1 align="center">AlwaysOn</h1>

<p align="center">
  <a href="./README.md">📖 English Documentation</a>
</p>

<p align="center">
  <strong>你的 Mac，永不休眠。</strong><br>
  合盖后保持 Mac 运行，为 AI Agent 时代而生。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-000?style=flat-square&logo=apple&logoColor=fff" alt="macOS 13+">
  <img src="https://img.shields.io/badge/arch-Universal%20Binary-000?style=flat-square" alt="Universal Binary">
  <img src="https://img.shields.io/badge/language-Swift-000?style=flat-square&logo=swift&logoColor=F05138" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-000?style=flat-square" alt="MIT">
</p>

<p align="center">
  <a href="#安装">安装</a> · <a href="#配置">配置</a> · <a href="#菜单栏">菜单栏</a>
</p>

---

## 功能特性

- **合盖防休眠** -- 使用 `pmset disablesleep 1` 保持 Mac 在合盖后继续运行。WiFi 保持连接，所有进程继续运行。
- **AC 模式** -- 可选"接电源时始终保持唤醒"（默认）或"接电源且连接 WiFi 时保持唤醒"。
- **电池模式** -- 可选"仅白名单 WiFi"（默认）或"任意 WiFi"。
- **手动开关** -- 从菜单栏启用/禁用防休眠功能，状态跨重启持久化。
- **WiFi 白名单** -- 从菜单栏添加/移除 WiFi 网络。白名单中的 WiFi 即使在电池模式下也能保持唤醒。
- **智能电池保护** -- 每 60 秒监测电池电量。合盖状态下电量低于 5% 自动休眠。
- **深度休眠防护** -- 激活时禁用 `standby` 和 `autopoweroff`，防止系统进入深度休眠。
- **登录时启动** -- 使用 SMAppService（macOS 13+）。
- **原生菜单栏应用** -- SF Symbols 图标，无 Dock 图标，无 Electron。
- **双语支持** -- 英文和简体中文，根据系统语言自动切换。

---

## 安装

### 下载安装

下载 `AlwaysOn.zip`，解压后拖入 `/Applications`。首次启动：右键点击 -> 打开。

### 从源码构建

```bash
git clone <repo-url>
cd AlwaysOn
./build.sh
./install.sh   # 复制到 /Applications
```

要求：macOS 13+，Xcode 命令行工具（需要 `swiftc`）。

---

## 配置

配置文件：`~/.alwayson/config.json`

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

| 字段 | 说明 | 默认值 |
|:---|:---|:---|
| `enabled` | 防休眠主开关 | `true` |
| `ac_mode` | `"always"`（接电源时始终唤醒）或 `"wifi_required"`（接电源 + WiFi） | `"always"` |
| `battery_mode` | `"whitelist"`（仅白名单 WiFi）或 `"any_wifi"`（任意 WiFi） | `"whitelist"` |
| `whitelist_wifi` | 电池模式下保持唤醒的 WiFi 网络列表 | `[]` |
| `check_interval` | 检查间隔（秒），范围 1-300 | `60` |
| `enable_wake_on_power` | 接入电源时自动唤醒 | `true` |

---

## 菜单栏

```
cup.and.saucer.fill / moon.zzz
├── 合盖后将保持唤醒
├── 禁用防休眠
├── ──────────────
├── 电源：电源适配器
├── 盖子：打开
├── ──────────────
├── WiFi：Home WiFi
├── 添加 "Home WiFi" 到白名单
├── ──────────────
├── AC 模式：始终保持唤醒        ✓
├── AC 模式：需要 WiFi
├── 电池模式：仅白名单 WiFi  ✓
├── 电池模式：任意 WiFi
├── ──────────────
├── ✓ 登录时启动
├── 打开配置文件夹
├── ──────────────
└── 退出 AlwaysOn (⌘Q)
```

**图标说明：**
- 咖啡杯（`cup.and.saucer.fill`）= 将保持唤醒
- 月亮（`moon.zzz`）= 不会保持唤醒

---

## 工作原理

AlwaysOn 使用 `pmset disablesleep 1` 作为防止休眠的核心机制。这是防止 macOS 合盖休眠的唯一可靠方式。

激活时，还会设置：
- `standby 0` 和 `autopoweroff 0` 防止深度休眠
- `disksleep 0` 和 `networkoversleep 1` 保持磁盘和网络活跃
- `tcpkeepalive 1` 维持网络连接

禁用时，所有设置恢复为 macOS 默认值。

---

## 权限

### pmset（必需）
首次启动时提示输入一次密码，创建 `/etc/sudoers.d/pmset` 以允许仅对 `pmset` 命令进行免密操作。

### 定位服务（可选，用于 WiFi 白名单）
读取 WiFi SSID 需要定位服务权限。macOS 要求此权限才能获取 WiFi 名称。不会使用任何实际位置数据。

---

## 卸载

1. 在菜单栏点击**退出**（恢复默认电源设置）
2. 从 `/Applications` 删除 `AlwaysOn.app`
3. 可选：`rm -rf ~/.alwayson`
4. 可选：`sudo rm /etc/sudoers.d/pmset`

---

## 技术规格

| | |
|:--|:--|
| **语言** | 纯 Swift（swiftc 编译，无 Xcode 项目） |
| **二进制** | Universal Binary（arm64 + x86_64） |
| **框架** | AppKit、IOKit、ServiceManagement、CoreWLAN、CoreLocation |
| **休眠控制** | `pmset disablesleep 1` |
| **权限** | `/etc/sudoers.d/pmset` |
| **登录项** | SMAppService（macOS 13+） |
| **签名** | Ad-hoc 代码签名（含 entitlements） |
| **最低系统** | macOS 13.0（Ventura） |

---

## 许可证

MIT
