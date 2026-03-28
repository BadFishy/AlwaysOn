<p align="center">
  <img src="site/icon.svg" width="120" height="120" alt="AlwaysOn">
</p>

<h1 align="center">AlwaysOn</h1>

<p align="center">
  <strong>你的 Mac 永不休眠。</strong><br>
  在 AI Agent 时代，让你的 Mac 永远在线。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-000?style=flat-square&logo=apple&logoColor=fff" alt="macOS 13+">
  <img src="https://img.shields.io/badge/arch-Universal%20Binary-000?style=flat-square" alt="Universal Binary">
  <img src="https://img.shields.io/badge/size-83KB-000?style=flat-square" alt="83KB">
  <img src="https://img.shields.io/badge/language-Swift-000?style=flat-square&logo=swift&logoColor=F05138" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-000?style=flat-square" alt="MIT">
</p>

<p align="center">
  <a href="https://github.com/mochimon/AlwaysOn/releases/latest/download/AlwaysOn.zip"><strong>下载</strong></a> · <a href="#安装">安装说明</a> · <a href="#配置">配置指南</a>
</p>

<p align="center">
  <sub>支持所有 Mac：MacBook · Mac mini · iMac · Mac Studio · Mac Pro</sub>
</p>

---

## 功能对比

| 功能 | 原版 AlwaysOn | AlwaysOn (增强版) |
|:---|:---|:---|
| 一键防休眠 | ✅ | ✅ |
| 智能电池保护 | ✅ | ✅ |
| 零配置权限 | ✅ | ✅ |
| 原生菜单栏 | ✅ | ✅ |
| **WiFi 白名单** | ❌ | ✅ 连接特定 WiFi 自动防休眠 |
| **开盖检测** | ❌ | ✅ 自动检测笔记本盖子状态 |
| **状态推送** | ❌ | ✅ 支持通用 Webhook |
| **国际化支持** | ❌ | ✅ 中文/英文自动切换 |
| **增强测试功能** | ❌ | ✅ 配置检查 + HTTP 响应显示 |

---

## 功能

> **一键防休眠** — 完全禁用系统休眠，包括合盖。AI Agent、长时间编译、通宵下载不中断。

> **WiFi 白名单** — 连接指定 WiFi 时自动启用防休眠，离开则自动恢复。支持"家里 WiFi"、"办公室"等场景。

> **智能电池保护** — 每 60 秒检测电量。合盖 + ≤5% → 自动休眠。开盖 → 仅通知。10% 时警告。

> **零配置权限** — 首次启动弹出 macOS 原生密码框，输入一次即永久免密。仅授权 `pmset`。

> **状态推送** — 支持通用 Webhook，状态变化自动推送，远程掌握 Mac 状态。

> **原生菜单栏** — SF Symbols 图标 + 实时电量。开关切换，支持开机自启。无 Dock 图标。

---

## 安装

### 方式一：直接下载

```
1. 下载 → 解压 → 拖入 /Applications
2. 右键 → 打开（仅首次）
3. 输入一次密码
4. 点击启用 ☕ 搞定。
```

### 方式二：从源码构建

```bash
git clone https://github.com/mochimon/AlwaysOn.git
cd AlwaysOn
./build.sh
open AlwaysOn.app
```

---

## 配置

编辑 `~/.alwayson/config.json`：

```json
{
  "whitelist_wifi": ["家里5G", "办公室"],
  "check_interval": 60,
  "enable_wake_on_power": true,
  "webhook_enabled": true,
  "webhook_url": "https://your-webhook-url.com"
}
```

### 字段说明

| 字段 | 说明 | 默认值 |
|:---|:---|:---|
| `whitelist_wifi` | 白名单 WiFi 列表，连接这些网络时自动防休眠 | `[]` |
| `check_interval` | 检测间隔（秒） | `60` |
| `enable_wake_on_power` | 插入电源时是否自动唤醒 | `true` |
| `webhook_enabled` | 是否启用 Webhook 推送 | `false` |
| `webhook_url` | 通用 Webhook URL | `null` |

---

## 推送配置

### 通用 Webhook

支持任意兼容的 Webhook 端点：

1. 在菜单栏点击「测试推送」
2. 输入你的 Webhook URL
3. 保存并测试

消息格式：

```json
{
  "event": "status_changed",
  "timestamp": "2026-03-28T01:30:00+08:00",
  "source": "AlwaysOn",
  "data": {
    "status": "运行中",
    "previous_status": "待机",
    "wifi": "家里5G",
    "power": "电源适配器",
    "lid": "合上",
    "mode": "白名单模式"
  }
}
```

---

## 菜单栏

```
☕ 78%
├── 状态: 运行中
├── ──────────────
├── WiFi: 家里5G
├── 电源: 电源适配器
├── 盖子: 打开
├── 模式: 白名单模式
├── ──────────────
├── 添加 "家里5G" 到白名单
├── ✓ 开机启动
├── ──────────────
├── 打开配置文件夹
├── 测试推送
├── ──────────────
└── 退出
```

---

## 权限说明

AlwaysOn 需要以下权限：

### 1. pmset 权限（必需）
首次启动时需要输入密码授权，用于控制系统休眠。
- 创建 `/etc/sudoers.d/pmset` 文件
- 仅允许免密执行 `pmset` 命令，不影响其他命令

### 2. 位置服务权限（可选，用于 WiFi 白名单）
- 用于获取当前连接的 WiFi 名称（SSID）
- macOS 位置服务隐私设置中授权
- 不获取实际位置信息，仅用于 WiFi 名称识别

---

## 卸载

1. 菜单栏点击 **退出**（自动恢复电源默认设置）
2. 删除应用程序中的 AlwaysOn.app
3. 可选：`rm -rf ~/.alwayson`
4. 可选：`sudo rm /etc/sudoers.d/pmset`

---

## 技术规格

| | |
|:--|:--|
| **语言** | Pure Swift |
| **二进制** | 83KB, Universal (arm64 + x86_64) |
| **框架** | AppKit, IOKit, ServiceManagement |
| **休眠控制** | `pmset disablesleep` + `caffeinate -ims` |
| **权限** | `/etc/sudoers.d/pmset` (仅 pmset 免密) |
| **登录项** | SMAppService (macOS 13+) |
| **签名** | Ad-hoc codesigned |
| **最低系统** | macOS 13.0 (Ventura) |

---

## 常见问题

<details>
<summary><b>为什么打不开 App？</b></summary>
<br>
右键 → 打开 → 打开。仅需一次。<br><br>
如果仍然无法打开：<b>系统设置 → 隐私与安全性 → 安全性</b>，点击<b>「仍要打开」</b>。
</details>

<details>
<summary><b>密码弹窗做了什么？</b></summary>
<br>
创建 <code>/etc/sudoers.d/pmset</code>，仅允许免密执行 <code>pmset</code>，不影响其他命令。
</details>

<details>
<summary><b>菜单栏看不到图标？</b></summary>
<br>
刘海屏 MacBook 上图标过多会被挤到摄像头后面。按住 <code>⌘</code> 拖拽重新排列，或使用 <a href="https://github.com/jordanbaird/Ice">Ice</a>（免费开源）管理菜单栏。
</details>

<details>
<summary><b>测试推送失败怎么办？</b></summary>
<br>
1. 检查网络连接<br>
2. 确认 Webhook URL 正确<br>
3. 查看弹窗显示的 HTTP 状态码：<br>
   - <code>200-299</code>: 成功<br>
   - <code>404</code>: 路径不存在或 URL 错误<br>
   - <code>500</code>: 服务端错误<br>
4. 检查弹窗中的响应内容获取详细信息
</details>

<details>
<summary><b>白名单 WiFi 不生效？</b></summary>
<br>
1. 确保已授予 Location Services 权限（获取 WiFi 名称需要）<br>
2. 检查 WiFi 名称是否完全匹配（区分大小写）<br>
3. 打开配置文件夹查看日志输出<br>
4. 尝试重启应用
</details>

---

## 许可证

MIT

---

<p align="center">
  <sub>Made with ☕ by LobsterAI</sub>
</p>