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
- **1 秒守护 + 系统电源事件** -- `disablesleep` 是一个**全局**标志，其它软件（乃至系统）随时可能把它清掉。AlwaysOn 每秒直接读内核状态（IORegistry，零子进程）校验并在毫秒级补写；同时订阅 `IOPMrootDomain` 电源事件 —— 其中合盖通知按 Apple 文档说明是**在睡眠发起之前**送达的。
- **电池保底** -- 电池供电且电量低于可配置下限（默认 5%）时主动放开休眠，避免一路跑到 0% 硬关机。
- **状态不撒谎** -- 菜单栏与图标显示的是**内核真实状态**，不是配置预测。被外部覆盖且抢不回来时会显示 ⚠️，而不是继续假装"合盖后保持唤醒"。
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
  "battery_floor": 5,
  "check_interval": 60,
  "guard_interval": 1.0,
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
| `battery_floor` | 电池供电时低于此电量（%）放开休眠；`0` = 关闭该保护 | `5` |
| `check_interval` | 条件复核间隔（秒），范围 5-300 | `60` |
| `guard_interval` | 校验 `disablesleep` 的守护间隔（秒），范围 0.5-10 | `1.0` |
| `enable_wake_on_power` | 开启「网络访问唤醒」（`womp 1`） | `true` |

配置项缺失或格式错误时**只回退该字段**为默认值 —— 半个写坏的配置文件不会再把白名单清空。

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
├── 电池保底：低于 5% 放开休眠
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

AlwaysOn 只用 `pmset disablesleep 1`，**不碰任何其它设置**。这是防止 macOS 合盖休眠的唯一可靠方式 —— 公共电源断言（包括 `caffeinate`）都挡不住合盖休眠，Apple 自己的 `IOPMLib.h` 原文是 *"The system may still sleep for lid close, Apple menu, low battery, or other sleep reasons."*

**只改一个设置**：早期版本还会改写 `sleep`、`displaysleep`、`standby`、`autopoweroff`、`disksleep`、`tcpkeepalive`、`networkoversleep`，退出时再"恢复"成硬编码的猜测值 —— 那会永久破坏用户自己的电源配置。这个行为已经删除：除了 `disablesleep` 什么都不写，也就没有任何东西需要"恢复"。

因为 `disablesleep` 是**全系统唯一**的一个标志，任何程序都能把它清掉。所以 AlwaysOn：

- 每秒从 IORegistry 直读 `IOPMrootDomain` 的 `SleepDisabled`（约 7 µs，无子进程）核对，发现被清零就在毫秒级补写；
- 订阅 `IOPMrootDomain` 电源事件，其中 `kIOPMMessageClamshellStateChange` 按 Apple 文档说明是**在合盖睡眠发起之前**送达的。

### 日志
`~/.alwayson/logs/` —— 每天一个文件，单文件 5 MB 轮转，超过 7 天自动清理。

---

## 权限

### pmset（必需）
首次启动会先说明原因，再弹一次系统密码框，安装**收窄到具体命令**的规则
`/etc/sudoers.d/alwayson-pmset`，只放行下面这些命令，其它一概不放行：

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a womp 0
/usr/bin/pmset -a womp 1
/usr/bin/pmset sleepnow
```

安装前用 `visudo -c` 校验语法，并在**同一个提权会话内**自检；自检不通过会**自动回滚**，
所以不会出现"收窄之后写不了标志、机器又睡回去"的情况。菜单里会显示当前授权状态，
随时可以重做。**选择取消也没问题** —— 应用继续运行并显示 `⚠️ 防休眠未生效`，不会假装在工作。

### 定位服务（可选，用于 WiFi 白名单）
读取 WiFi SSID 需要定位服务权限。不会使用或存储任何位置数据。未授权时 SSID 会显示为
"读不到"，AlwaysOn 会**沿用上一次判定**，而不是误判成"连了陌生网络"就放开休眠。

---

## 卸载

1. 在菜单栏点击**退出**（放开休眠）
2. 从 `/Applications` 删除 `AlwaysOn.app`
3. 可选：`rm -rf ~/.alwayson`
4. 可选：`sudo rm /etc/sudoers.d/alwayson-pmset`

---

## 技术规格

| | |
|:--|:--|
| **语言** | 纯 Swift（swiftc 编译，无 Xcode 项目） |
| **二进制** | Universal Binary（arm64 + x86_64） |
| **框架** | AppKit、IOKit、ServiceManagement、CoreWLAN、CoreLocation |
| **休眠控制** | `pmset disablesleep 1` |
| **权限** | `/etc/sudoers.d/alwayson-pmset`（5 条精确命令） |
| **登录项** | SMAppService（macOS 13+） |
| **签名** | Ad-hoc 代码签名（含 entitlements） |
| **最低系统** | macOS 13.0（Ventura） |

---

## 许可证

MIT
