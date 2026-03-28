import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let conditionalController = ConditionalSleepController()
    private let loginItemManager = LoginItemManager()
    
    // Menu items
    private var statusMenuItem: NSMenuItem!
    private var toggleEnableMenuItem: NSMenuItem!
    private var powerMenuItem: NSMenuItem!
    private var lidMenuItem: NSMenuItem!
    private var wifiMenuItem: NSMenuItem!
    private var whitelistMenuItem: NSMenuItem!
    private var acModeAlwaysItem: NSMenuItem!
    private var acModeWifiItem: NSMenuItem!
    private var batteryModeWhitelistItem: NSMenuItem!
    private var batteryModeAnyWifiItem: NSMenuItem!
    private var loginMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // 加载配置
        ConfigManager.shared.loadConfig()

        // 先设置菜单栏，确保 UI 不被阻塞
        setupStatusItem()
        setupConditionalController()
        updateMenuState()
        
        // 异步检查权限，不阻塞 UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if !PrivilegeManager.hasPasswordlessPmset() {
                let granted = PrivilegeManager.requestPrivileges()
                if !granted {
                    DispatchQueue.main.async {
                        self.showPermissionAlert()
                    }
                    return
                }
            }
            
            // 权限检查通过后，刷新状态
            DispatchQueue.main.async {
                self.updateMenuState()
            }
        }
    }
    
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("permission_alert_title", comment: "")
        alert.informativeText = NSLocalizedString("permission_alert_message", comment: "")
        alert.alertStyle = .critical
        alert.addButton(withTitle: NSLocalizedString("permission_alert_quit", comment: ""))
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "AlwaysOn")
        button.imagePosition = .imageLeading
        
        // 允许菜单栏图标被移除
        statusItem.behavior = .removalAllowed

        let menu = NSMenu()

        // 状态行
        statusMenuItem = NSMenuItem(title: "...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        // 关闭/启用阻止休眠
        toggleEnableMenuItem = NSMenuItem(title: NSLocalizedString("menu_disable_sleep_prevention", comment: ""), action: #selector(toggleEnable), keyEquivalent: "")
        toggleEnableMenuItem.target = self
        menu.addItem(toggleEnableMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 电源状态
        powerMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_power", comment: ""), "--"), action: nil, keyEquivalent: "")
        powerMenuItem.isEnabled = false
        menu.addItem(powerMenuItem)
        
        // 盖子状态
        lidMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_lid", comment: ""), "--"), action: nil, keyEquivalent: "")
        lidMenuItem.isEnabled = false
        menu.addItem(lidMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // WiFi 信息
        wifiMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_wifi", comment: ""), "--"), action: nil, keyEquivalent: "")
        wifiMenuItem.isEnabled = false
        menu.addItem(wifiMenuItem)
        
        // 白名单操作
        whitelistMenuItem = NSMenuItem(title: NSLocalizedString("menu_add_whitelist_no_wifi", comment: ""), action: #selector(toggleWhitelist), keyEquivalent: "")
        whitelistMenuItem.target = self
        menu.addItem(whitelistMenuItem)

        menu.addItem(NSMenuItem.separator())
        
        // AC 模式选项
        acModeAlwaysItem = NSMenuItem(title: NSLocalizedString("menu_ac_mode_always", comment: ""), action: #selector(setAcModeAlways), keyEquivalent: "")
        acModeAlwaysItem.target = self
        menu.addItem(acModeAlwaysItem)
        
        acModeWifiItem = NSMenuItem(title: NSLocalizedString("menu_ac_mode_wifi", comment: ""), action: #selector(setAcModeWifi), keyEquivalent: "")
        acModeWifiItem.target = self
        menu.addItem(acModeWifiItem)
        
        // 电池模式选项
        batteryModeWhitelistItem = NSMenuItem(title: NSLocalizedString("menu_battery_mode_whitelist", comment: ""), action: #selector(setBatteryModeWhitelist), keyEquivalent: "")
        batteryModeWhitelistItem.target = self
        menu.addItem(batteryModeWhitelistItem)
        
        batteryModeAnyWifiItem = NSMenuItem(title: NSLocalizedString("menu_battery_mode_any_wifi", comment: ""), action: #selector(setBatteryModeAnyWifi), keyEquivalent: "")
        batteryModeAnyWifiItem.target = self
        menu.addItem(batteryModeAnyWifiItem)

        menu.addItem(NSMenuItem.separator())
        
        // 开机自启
        loginMenuItem = NSMenuItem(title: NSLocalizedString("menu_launch_at_login", comment: ""), action: #selector(toggleLoginItem), keyEquivalent: "")
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        
        // 打开配置文件夹
        let configItem = NSMenuItem(title: NSLocalizedString("menu_open_config_folder", comment: ""), action: #selector(openConfigFolder), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(NSMenuItem.separator())

        // 退出
        let quitItem = NSMenuItem(title: NSLocalizedString("menu_quit", comment: ""), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        
        // 设置菜单委托以便在菜单打开时刷新状态
        menu.delegate = self
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        // 菜单即将打开时，强制刷新 WiFi 状态并更新菜单
        conditionalController.wifiMonitor.forceRefresh()
        updateMenuState()
    }
    
    // MARK: - Conditional Controller

    private func setupConditionalController() {
        conditionalController.onStatusChange = { [weak self] in
            DispatchQueue.main.async {
                self?.updateMenuState()
            }
        }
        
        // 位置权限授予后立即重新检测条件并刷新菜单
        conditionalController.wifiMonitor.onPermissionGranted = { [weak self] in
            DispatchQueue.main.async {
                self?.conditionalController.checkConditions()
                self?.updateMenuState()
            }
        }
        
        conditionalController.start()
    }

    // MARK: - State Management

    private func updateMenuState() {
        let config = ConfigManager.shared
        let info = conditionalController.batteryMonitor.currentInfo()
        let lidClosed = LidStateProvider.shared.isLidClosed()
        let wifiSSID = conditionalController.wifiMonitor.currentSSID
        
        // 更新状态行 — 始终显示预测式文本
        let prediction = conditionalController.predictedStatus()
        switch prediction {
        case .willStayAwake:
            statusMenuItem.title = NSLocalizedString("status_will_stay_awake", comment: "")
        case .willSleep:
            statusMenuItem.title = NSLocalizedString("status_will_sleep", comment: "")
        case .disabled:
            statusMenuItem.title = NSLocalizedString("status_disabled", comment: "")
        }
        
        // 更新开关菜单项
        if config.enabled {
            toggleEnableMenuItem.title = NSLocalizedString("menu_disable_sleep_prevention", comment: "")
        } else {
            toggleEnableMenuItem.title = NSLocalizedString("menu_enable_sleep_prevention", comment: "")
        }
        
        // 更新电源和盖子状态
        powerMenuItem.title = String(format: NSLocalizedString("menu_power", comment: ""), 
            info.isOnAC ? NSLocalizedString("menu_power_ac", comment: "") : NSLocalizedString("menu_power_battery", comment: ""))
        lidMenuItem.title = String(format: NSLocalizedString("menu_lid", comment: ""), 
            lidClosed ? NSLocalizedString("menu_lid_closed", comment: "") : NSLocalizedString("menu_lid_open", comment: ""))
        
        // 更新 WiFi 信息
        let wifiDisplay = wifiSSID ?? NSLocalizedString("wifi_not_connected", comment: "")
        wifiMenuItem.title = String(format: NSLocalizedString("menu_wifi", comment: ""), wifiDisplay)
        
        // 更新白名单菜单项
        if let ssid = wifiSSID {
            let isWhitelisted = config.isWhitelisted(ssid)
            whitelistMenuItem.title = String(format: isWhitelisted ? NSLocalizedString("menu_remove_from_whitelist", comment: "") : NSLocalizedString("menu_add_to_whitelist", comment: ""), ssid)
            whitelistMenuItem.isEnabled = true
        } else {
            whitelistMenuItem.title = NSLocalizedString("menu_add_whitelist_no_wifi", comment: "")
            whitelistMenuItem.isEnabled = false
        }
        
        // 更新 AC 模式选项
        acModeAlwaysItem.state = config.acMode == "always" ? .on : .off
        acModeWifiItem.state = config.acMode == "wifi_required" ? .on : .off
        
        // 更新电池模式选项
        batteryModeWhitelistItem.state = config.batteryMode == "whitelist" ? .on : .off
        batteryModeAnyWifiItem.state = config.batteryMode == "any_wifi" ? .on : .off
        
        // 更新菜单栏图标
        guard let button = statusItem.button else { return }
        
        switch prediction {
        case .willStayAwake:
            button.image = NSImage(
                systemSymbolName: "cup.and.saucer.fill",
                accessibilityDescription: "AlwaysOn - \(NSLocalizedString("status_will_stay_awake", comment: ""))"
            )
        case .willSleep, .disabled:
            button.image = NSImage(
                systemSymbolName: "moon.zzz",
                accessibilityDescription: "AlwaysOn - \(NSLocalizedString("status_will_sleep", comment: ""))"
            )
        }
        
        // 更新开机自启状态
        loginMenuItem.state = loginItemManager.isEnabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func toggleEnable() {
        let config = ConfigManager.shared
        let newEnabled = !config.enabled
        config.setEnabled(newEnabled)
        
        // 立即触发条件检测
        conditionalController.checkConditions()
        updateMenuState()
    }
    
    @objc private func setAcModeAlways() {
        ConfigManager.shared.setAcMode("always")
        conditionalController.checkConditions()
        updateMenuState()
    }
    
    @objc private func setAcModeWifi() {
        ConfigManager.shared.setAcMode("wifi_required")
        conditionalController.checkConditions()
        updateMenuState()
    }
    
    @objc private func setBatteryModeWhitelist() {
        ConfigManager.shared.setBatteryMode("whitelist")
        conditionalController.checkConditions()
        updateMenuState()
    }
    
    @objc private func setBatteryModeAnyWifi() {
        ConfigManager.shared.setBatteryMode("any_wifi")
        conditionalController.checkConditions()
        updateMenuState()
    }

    @objc private func toggleLoginItem() {
        let newState = !loginItemManager.isEnabled
        loginItemManager.setEnabled(newState)
        loginMenuItem.state = newState ? .on : .off
    }
    
    @objc private func toggleWhitelist() {
        guard let currentSSID = conditionalController.wifiMonitor.currentSSID else {
            return
        }
        
        let config = ConfigManager.shared
        let isWhitelisted = config.isWhitelisted(currentSSID)
        
        if isWhitelisted {
            config.removeFromWhitelist(currentSSID)
            showNotification(title: "AlwaysOn", 
                           body: String(format: NSLocalizedString("notification_removed_from_whitelist", comment: ""), currentSSID))
        } else {
            config.addToWhitelist(currentSSID)
            showNotification(title: "AlwaysOn", 
                           body: String(format: NSLocalizedString("notification_added_to_whitelist", comment: ""), currentSSID))
        }
        
        // 立即刷新状态
        conditionalController.checkConditions()
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
        conditionalController.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        conditionalController.stop()
    }
}
