import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = ConditionalSleepController()
    private let loginItemManager = LoginItemManager()

    // Menu items
    private var statusMenuItem: NSMenuItem!
    private var toggleEnableMenuItem: NSMenuItem!
    private var powerMenuItem: NSMenuItem!
    private var lidMenuItem: NSMenuItem!
    private var wifiMenuItem: NSMenuItem!
    private var whitelistMenuItem: NSMenuItem!
    private var locationMenuItem: NSMenuItem!
    private var batteryFloorMenuItem: NSMenuItem!
    private var acModeAlwaysItem: NSMenuItem!
    private var acModeWifiItem: NSMenuItem!
    private var batteryModeWhitelistItem: NSMenuItem!
    private var batteryModeAnyWifiItem: NSMenuItem!
    private var grantMenuItem: NSMenuItem!
    private var loginMenuItem: NSMenuItem!

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // 注：`ConfigManager.shared` 的 init 已经 loadConfig() 过一次，这里不再重复调用。

        setupStatusItem()
        installSignalHandlers()

        // 权限处理策略：
        // - **任何情况下都先把守护跑起来**。没有权限时 UI 会显示「防休眠未生效」，
        //   用户可以照样查看状态、配置白名单，并随时从菜单补授权。
        //   （旧版是"取消授权就退出"，对登录项来说很难理解；而它更严重的毛病是先启动
        //   再去异步要权限，于是 enable() 全部静默失败、界面却显示"合盖后保持唤醒"。）
        // - 授权过宽（旧版遗留）→ 不阻塞，菜单里高亮提示可一键收窄。
        // - 完全没有授权（首次运行）→ 主动弹一次授权引导。
        let hasScoped = PrivilegeManager.hasScopedGrant()
        let hasOverbroad = PrivilegeManager.hasOverbroadGrant()

        if hasOverbroad {
            FileLogger.shared.log("⚠️ 检测到过宽的 pmset 授权（任意参数免密），已可在菜单中一键收窄")
        }

        startController()

        if !hasScoped && !hasOverbroad {
            FileLogger.shared.log("首次运行：尚无 pmset 授权，弹出授权引导（应用继续以降级模式运行）")
            PrivilegeManager.requestSetup { [weak self] granted in
                guard let self = self else { return }
                FileLogger.shared.log("首次授权结果：\(granted)，\(PrivilegeManager.describeState())")
                self.controller.checkConditions(reason: "首次授权完成")
                self.updateMenuState()
            }
        }
    }

    private func startController() {
        controller.onStatusChange = { [weak self] in
            DispatchQueue.main.async { self?.updateMenuState() }
        }
        controller.wifiMonitor.onPermissionGranted = { [weak self] in
            DispatchQueue.main.async {
                self?.controller.checkConditions(reason: "定位权限已授予")
                self?.updateMenuState()
            }
        }

        controller.start()
        updateMenuState()

        FileLogger.shared.log("权限状态：\(PrivilegeManager.describeState())")
    }

    /// 无任何清理机会就被强杀（`pkill`、崩溃）一直是本项目的老问题：
    /// 退出后 `disablesleep` 会永久留在 1、`caffeinate` 会变成孤儿（实测残留 2 天 18 小时）。
    /// 这里接住 SIGTERM/SIGINT 走正常清理路径。
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                FileLogger.shared.log("收到信号 \(sig)，正在清理后退出")
                self?.controller.stop()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "AlwaysOn")
        button.imagePosition = .imageLeading

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        toggleEnableMenuItem = NSMenuItem(title: NSLocalizedString("menu_disable_sleep_prevention", comment: ""), action: #selector(toggleEnable), keyEquivalent: "")
        toggleEnableMenuItem.target = self
        menu.addItem(toggleEnableMenuItem)

        menu.addItem(NSMenuItem.separator())

        powerMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_power", comment: ""), "--"), action: nil, keyEquivalent: "")
        powerMenuItem.isEnabled = false
        menu.addItem(powerMenuItem)

        lidMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_lid", comment: ""), "--"), action: nil, keyEquivalent: "")
        lidMenuItem.isEnabled = false
        menu.addItem(lidMenuItem)

        menu.addItem(NSMenuItem.separator())

        wifiMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_wifi", comment: ""), "--"), action: nil, keyEquivalent: "")
        wifiMenuItem.isEnabled = false
        menu.addItem(wifiMenuItem)

        whitelistMenuItem = NSMenuItem(title: NSLocalizedString("menu_add_whitelist_no_wifi", comment: ""), action: #selector(toggleWhitelist), keyEquivalent: "")
        whitelistMenuItem.target = self
        menu.addItem(whitelistMenuItem)

        locationMenuItem = NSMenuItem(title: "", action: #selector(fixLocationPermission), keyEquivalent: "")
        locationMenuItem.target = self
        menu.addItem(locationMenuItem)

        batteryFloorMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        batteryFloorMenuItem.isEnabled = false
        menu.addItem(batteryFloorMenuItem)

        menu.addItem(NSMenuItem.separator())

        acModeAlwaysItem = NSMenuItem(title: NSLocalizedString("menu_ac_mode_always", comment: ""), action: #selector(setAcModeAlways), keyEquivalent: "")
        acModeAlwaysItem.target = self
        menu.addItem(acModeAlwaysItem)

        acModeWifiItem = NSMenuItem(title: NSLocalizedString("menu_ac_mode_wifi", comment: ""), action: #selector(setAcModeWifi), keyEquivalent: "")
        acModeWifiItem.target = self
        menu.addItem(acModeWifiItem)

        batteryModeWhitelistItem = NSMenuItem(title: NSLocalizedString("menu_battery_mode_whitelist", comment: ""), action: #selector(setBatteryModeWhitelist), keyEquivalent: "")
        batteryModeWhitelistItem.target = self
        menu.addItem(batteryModeWhitelistItem)

        batteryModeAnyWifiItem = NSMenuItem(title: NSLocalizedString("menu_battery_mode_any_wifi", comment: ""), action: #selector(setBatteryModeAnyWifi), keyEquivalent: "")
        batteryModeAnyWifiItem.target = self
        menu.addItem(batteryModeAnyWifiItem)

        menu.addItem(NSMenuItem.separator())

        grantMenuItem = NSMenuItem(title: "", action: #selector(reconfigureGrant), keyEquivalent: "")
        grantMenuItem.target = self
        menu.addItem(grantMenuItem)

        loginMenuItem = NSMenuItem(title: NSLocalizedString("menu_launch_at_login", comment: ""), action: #selector(toggleLoginItem), keyEquivalent: "")
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)

        let configItem = NSMenuItem(title: NSLocalizedString("menu_open_config_folder", comment: ""), action: #selector(openConfigFolder), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: NSLocalizedString("menu_quit", comment: ""), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // 关闭 AppKit 的自动启用/禁用：我们要自己精确控制每一项的可点状态
        menu.autoenablesItems = false

        statusItem.menu = menu
        menu.delegate = self
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // 菜单打开会切到事件跟踪模式；定时器已注册在 .common，看门狗不受影响
        controller.wifiMonitor.forceRefresh()
        updateMenuState()
    }

    // MARK: - State Management

    private func updateMenuState() {
        let config = ConfigManager.shared
        let info = controller.batteryMonitor.currentInfo()
        let lidClosed = SystemEvents.isLidClosed
        let ssid = controller.wifiMonitor.currentSSID

        // 状态行 —— 使用**真实**状态，而不是配置预测
        let status = controller.status()
        switch status {
        case .willStayAwake:
            statusMenuItem.title = NSLocalizedString("status_will_stay_awake", comment: "")
        case .willSleep:
            statusMenuItem.title = NSLocalizedString("status_will_sleep", comment: "")
        case .disabled:
            statusMenuItem.title = NSLocalizedString("status_disabled", comment: "")
        case .inconsistent:
            statusMenuItem.title = NSLocalizedString("status_inconsistent", comment: "")
        }

        if config.enabled {
            toggleEnableMenuItem.title = NSLocalizedString("menu_disable_sleep_prevention", comment: "")
        } else {
            toggleEnableMenuItem.title = NSLocalizedString("menu_enable_sleep_prevention", comment: "")
        }

        powerMenuItem.title = String(format: NSLocalizedString("menu_power", comment: ""),
            info.isOnAC ? NSLocalizedString("menu_power_ac", comment: "") : NSLocalizedString("menu_power_battery", comment: ""))
        lidMenuItem.title = String(format: NSLocalizedString("menu_lid", comment: ""),
            lidClosed == nil
                ? NSLocalizedString("menu_lid_unknown", comment: "")
                : (lidClosed! ? NSLocalizedString("menu_lid_closed", comment: "") : NSLocalizedString("menu_lid_open", comment: "")))

        // WiFi 显示：区分"未连接"和"读不到"（读不到时本地化说明原因，而不是用日志里的中文描述）
        let wifiDisplay: String
        switch controller.wifiMonitor.ssidState {
        case .connected(let name): wifiDisplay = name
        case .notConnected: wifiDisplay = NSLocalizedString("wifi_not_connected", comment: "")
        case .unavailable: wifiDisplay = NSLocalizedString("wifi_unavailable", comment: "")
        }
        wifiMenuItem.title = String(format: NSLocalizedString("menu_wifi", comment: ""), wifiDisplay)

        if let ssid = ssid {
            let isWhitelisted = config.isWhitelisted(ssid)
            whitelistMenuItem.title = String(format: isWhitelisted ? NSLocalizedString("menu_remove_from_whitelist", comment: "") : NSLocalizedString("menu_add_to_whitelist", comment: ""), ssid)
            whitelistMenuItem.isEnabled = true
        } else {
            whitelistMenuItem.title = NSLocalizedString("menu_add_whitelist_no_wifi", comment: "")
            whitelistMenuItem.isEnabled = false
        }

        // 定位权限：ad-hoc 签名导致每次重建 app 都可能被回收权限 → WiFi 白名单静默失效
        let wifi = controller.wifiMonitor
        if !wifi.isLocationPermissionMissing {
            // 已授权 → 没有可做的事。**把 action 置空**而不是只设 isEnabled：
            // 这样它与其它信息行一样渲染为灰色且确定不可点，不依赖 isEnabled/自动启用的语义。
            locationMenuItem.title = NSLocalizedString("location_ok", comment: "")
            locationMenuItem.action = nil          // 确定性不可点
            locationMenuItem.target = nil
            locationMenuItem.isEnabled = false     // 且渲染为灰色（autoenablesItems 已关闭，一定生效）
        } else {
            locationMenuItem.title = NSLocalizedString(
                wifi.isLocationPermissionDenied ? "location_denied" : "location_missing", comment: "")
            locationMenuItem.action = #selector(fixLocationPermission)
            locationMenuItem.target = self
            locationMenuItem.isEnabled = true
        }

        let floor = config.batteryFloor
        batteryFloorMenuItem.title = floor > 0
            ? String(format: NSLocalizedString("menu_battery_floor", comment: ""), floor)
            : NSLocalizedString("menu_battery_floor_off", comment: "")

        acModeAlwaysItem.state = config.acMode == "always" ? .on : .off
        acModeWifiItem.state = config.acMode == "wifi_required" ? .on : .off
        batteryModeWhitelistItem.state = config.batteryMode == "whitelist" ? .on : .off
        batteryModeAnyWifiItem.state = config.batteryMode == "any_wifi" ? .on : .off

        // 权限状态：过宽时高亮提示并可点击修复
        let overbroad = PrivilegeManager.hasOverbroadGrant()
        let scoped = PrivilegeManager.hasScopedGrant()
        if overbroad || !scoped {
            grantMenuItem.title = NSLocalizedString(
                overbroad ? "menu_grant_overbroad" : "menu_grant_missing", comment: "")
            grantMenuItem.action = #selector(reconfigureGrant)
            grantMenuItem.target = self
            grantMenuItem.isEnabled = true
        } else {
            grantMenuItem.title = String(
                format: NSLocalizedString("menu_grant_ok", comment: ""),
                String(PrivilegeManager.allowedCommands.count))
            grantMenuItem.action = nil             // 确定性不可点
            grantMenuItem.target = nil
            grantMenuItem.isEnabled = false
        }

        loginMenuItem.state = loginItemManager.isEnabled ? .on : .off

        // 菜单栏图标：与状态行一致，用真实状态
        guard let button = statusItem.button else { return }
        switch status {
        case .willStayAwake:
            button.image = NSImage(systemSymbolName: "cup.and.saucer.fill",
                                   accessibilityDescription: "AlwaysOn - \(NSLocalizedString("status_will_stay_awake", comment: ""))")
        case .inconsistent:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "AlwaysOn - \(NSLocalizedString("status_inconsistent", comment: ""))")
        case .willSleep, .disabled:
            button.image = NSImage(systemSymbolName: "moon.zzz",
                                   accessibilityDescription: "AlwaysOn - \(NSLocalizedString("status_will_sleep", comment: ""))")
        }
    }

    // MARK: - Actions

    @objc private func toggleEnable() {
        let config = ConfigManager.shared
        config.setEnabled(!config.enabled)
        controller.checkConditions(reason: "手动开关")
        updateMenuState()
    }

    @objc private func setAcModeAlways() {
        ConfigManager.shared.setAcMode("always")
        controller.checkConditions(reason: "切换插电模式")
        updateMenuState()
    }

    @objc private func setAcModeWifi() {
        ConfigManager.shared.setAcMode("wifi_required")
        controller.checkConditions(reason: "切换插电模式")
        updateMenuState()
    }

    @objc private func setBatteryModeWhitelist() {
        ConfigManager.shared.setBatteryMode("whitelist")
        controller.checkConditions(reason: "切换电池模式")
        updateMenuState()
    }

    @objc private func setBatteryModeAnyWifi() {
        ConfigManager.shared.setBatteryMode("any_wifi")
        controller.checkConditions(reason: "切换电池模式")
        updateMenuState()
    }

    /// 修复定位权限：应用是 ad-hoc 签名，重建后权限可能被 TCC 回收，
    /// 于是一整天的 SSID 都读不到、白名单静默失效。这里给出两条明确出路。
    @objc private func fixLocationPermission() {
        let wifi = controller.wifiMonitor

        if wifi.isLocationPermissionDenied {
            FileLogger.shared.log("定位权限被拒，打开系统设置")
            WiFiMonitor.openLocationSettings()
            return
        }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("location_alert_title", comment: "")
        alert.informativeText = NSLocalizedString("location_alert_body", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("location_alert_request", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("location_alert_settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("grant_alert_cancel", comment: ""))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            FileLogger.shared.log("重新请求定位权限")
            wifi.requestLocationPermissionNow()
        case .alertSecondButtonReturn:
            FileLogger.shared.log("打开系统设置的定位服务面板")
            WiFiMonitor.openLocationSettings()
        default:
            break
        }
        updateMenuState()
    }

    @objc private func reconfigureGrant() {
        PrivilegeManager.requestSetup { [weak self] granted in
            FileLogger.shared.log("权限重配置结果：\(granted)，\(PrivilegeManager.describeState())")
            self?.updateMenuState()
        }
    }

    @objc private func toggleLoginItem() {
        let newState = !loginItemManager.isEnabled
        loginItemManager.setEnabled(newState)
        loginMenuItem.state = newState ? .on : .off
    }

    @objc private func toggleWhitelist() {
        guard let currentSSID = controller.wifiMonitor.currentSSID else { return }

        let config = ConfigManager.shared
        if config.isWhitelisted(currentSSID) {
            config.removeFromWhitelist(currentSSID)
            showNotification(title: "AlwaysOn",
                             body: String(format: NSLocalizedString("notification_removed_from_whitelist", comment: ""), currentSSID))
        } else {
            config.addToWhitelist(currentSSID)
            showNotification(title: "AlwaysOn",
                             body: String(format: NSLocalizedString("notification_added_to_whitelist", comment: ""), currentSSID))
        }

        controller.checkConditions(reason: "修改白名单")
        updateMenuState()
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @objc private func openConfigFolder() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alwayson")
        NSWorkspace.shared.open(configPath)
    }

    @objc private func quitApp() {
        controller.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
