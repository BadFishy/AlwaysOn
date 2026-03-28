import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let conditionalController = ConditionalSleepController()
    private let loginItemManager = LoginItemManager()
    private let powerManager = PowerManager()
    
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var wifiMenuItem: NSMenuItem!
    private var powerMenuItem: NSMenuItem!
    private var lidMenuItem: NSMenuItem!
    private var modeMenuItem: NSMenuItem!
    private var whitelistMenuItem: NSMenuItem!
    private var separator1: NSMenuItem!
    private var separator2: NSMenuItem!
    private var loginMenuItem: NSMenuItem!
    private var isEnabled: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        ConfigManager.shared.loadConfig()

        setupStatusItem()
        setupConditionalController()
        updateMenuState()
        
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

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: NSLocalizedString("app_name", comment: ""))
        button.imagePosition = .imageLeading
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        
        statusItem.behavior = .removalAllowed

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_status", comment: ""), "--"), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        toggleMenuItem = NSMenuItem(title: NSLocalizedString("menu_enable", comment: ""), action: #selector(toggleAlwaysOn), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)
        
        separator1 = NSMenuItem.separator()
        menu.addItem(separator1)
        
        wifiMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_wifi", comment: ""), "--"), action: nil, keyEquivalent: "")
        wifiMenuItem.isEnabled = false
        menu.addItem(wifiMenuItem)
        
        powerMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_power", comment: ""), "--"), action: nil, keyEquivalent: "")
        powerMenuItem.isEnabled = false
        menu.addItem(powerMenuItem)
        
        lidMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_lid", comment: ""), "--"), action: nil, keyEquivalent: "")
        lidMenuItem.isEnabled = false
        menu.addItem(lidMenuItem)
        
        modeMenuItem = NSMenuItem(title: String(format: NSLocalizedString("menu_mode", comment: ""), "--"), action: nil, keyEquivalent: "")
        modeMenuItem.isEnabled = false
        menu.addItem(modeMenuItem)
        
        separator2 = NSMenuItem.separator()
        menu.addItem(separator2)
        
        whitelistMenuItem = NSMenuItem(title: NSLocalizedString("menu_add_whitelist_no_wifi", comment: ""), action: #selector(toggleWhitelist), keyEquivalent: "")
        whitelistMenuItem.target = self
        menu.addItem(whitelistMenuItem)

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

        statusItem.menu = menu
        
        menu.delegate = self
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        conditionalController.wifiMonitor.forceRefresh()
        updateMenuState()
    }
    
    private func setupConditionalController() {
        conditionalController.onStatusChange = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMenuState()
            }
        }
        
        conditionalController.wifiMonitor.onPermissionGranted = { [weak self] in
            DispatchQueue.main.async {
                self?.updateMenuState()
            }
        }
        
        conditionalController.start()
    }

    private func updateMenuState() {
        let (_, detail) = conditionalController.getStatusDescription()
        let wifiSSID = conditionalController.wifiMonitor.currentSSID ?? NSLocalizedString("wifi_not_connected", comment: "")
        let info = conditionalController.batteryMonitor.currentInfo()
        let lidClosed = isLidClosed()
        
        if lidClosed {
            let status = conditionalController.currentStatus == .inactive ? "待机" : "运行中"
            statusMenuItem.title = String(format: NSLocalizedString("menu_status", comment: ""), localizeStatus(status))
        } else {
            let ssid = conditionalController.wifiMonitor.currentSSID
            let isWhitelisted = ConfigManager.shared.isWhitelisted(ssid)
            let willStayAwake = (info.isOnAC && ssid != nil) || isWhitelisted
            let prediction = willStayAwake
                ? NSLocalizedString("lid_prediction_wake", comment: "")
                : NSLocalizedString("lid_prediction_sleep", comment: "")
            statusMenuItem.title = String(format: NSLocalizedString("lid_prediction", comment: ""), prediction)
        }
        
        wifiMenuItem.title = String(format: NSLocalizedString("menu_wifi", comment: ""), wifiSSID)
        powerMenuItem.title = String(format: NSLocalizedString("menu_power", comment: ""), info.isOnAC ? NSLocalizedString("menu_power_ac", comment: "") : NSLocalizedString("menu_power_battery", comment: ""))
        lidMenuItem.title = String(format: NSLocalizedString("menu_lid", comment: ""), lidClosed ? NSLocalizedString("menu_lid_closed", comment: "") : NSLocalizedString("menu_lid_open", comment: ""))
        modeMenuItem.title = String(format: NSLocalizedString("menu_mode", comment: ""), localizeMode(detail))
        
        isEnabled = powerManager.isEnabled
        toggleMenuItem.title = isEnabled ? NSLocalizedString("menu_disable", comment: "") : NSLocalizedString("menu_enable", comment: "")
        
        guard let button = statusItem.button else { return }
        
        let ssid = conditionalController.wifiMonitor.currentSSID
        let isWhitelisted = ConfigManager.shared.isWhitelisted(ssid)
        let willStayAwake = (info.isOnAC && ssid != nil) || isWhitelisted
        
        if willStayAwake {
            button.image = NSImage(
                systemSymbolName: "cup.and.saucer.fill",
                accessibilityDescription: "\(NSLocalizedString("app_name", comment: "")) \(NSLocalizedString("status_running", comment: ""))"
            )
        } else {
            button.image = NSImage(
                systemSymbolName: "moon.fill",
                accessibilityDescription: "\(NSLocalizedString("app_name", comment: "")) \(NSLocalizedString("status_standby", comment: ""))"
            )
        }
        button.title = ""
        
        let config = ConfigManager.shared
        let currentSSID = conditionalController.wifiMonitor.currentSSID
        if let ssid = currentSSID {
            let isWhitelisted = config.isWhitelisted(ssid)
            whitelistMenuItem.title = String(format: isWhitelisted ? NSLocalizedString("menu_remove_from_whitelist", comment: "") : NSLocalizedString("menu_add_to_whitelist", comment: ""), ssid)
            whitelistMenuItem.isEnabled = true
        } else {
            whitelistMenuItem.title = NSLocalizedString("menu_add_whitelist_no_wifi", comment: "")
            whitelistMenuItem.isEnabled = false
        }
        
        loginMenuItem.state = loginItemManager.isEnabled ? .on : .off
    }
    
    private func localizeStatus(_ status: String) -> String {
        switch status {
        case "运行中", "Running":
            return NSLocalizedString("status_running", comment: "")
        case "待机", "Standby":
            return NSLocalizedString("status_standby", comment: "")
        case "白名单模式", "Whitelist Mode":
            return NSLocalizedString("status_whitelist_mode", comment: "")
        case "电源模式", "AC Mode":
            return NSLocalizedString("status_ac_mode", comment: "")
        case "休眠中", "Sleeping":
            return NSLocalizedString("status_sleeping", comment: "")
        default:
            return status
        }
    }
    
    private func localizeMode(_ mode: String) -> String {
        if mode.contains("白名单") || mode.contains("Whitelist") {
            return NSLocalizedString("menu_mode_whitelist", comment: "")
        } else if mode.contains("电源") || mode.contains("AC") {
            return NSLocalizedString("menu_mode_ac", comment: "")
        } else if mode.contains("电池") || mode.contains("Battery") {
            return NSLocalizedString("menu_mode_battery", comment: "")
        } else if mode.contains("禁用") || mode.contains("Disabled") {
            return NSLocalizedString("menu_mode_disabled", comment: "")
        }
        return mode
    }
    
    private func isLidClosed() -> Bool {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-k", "AppleClamshellState", "-d", "4"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            return output.contains("\"AppleClamshellState\" = Yes")
        } catch {
            return false
        }
    }

    @objc private func toggleAlwaysOn() {
        if powerManager.isEnabled {
            powerManager.disable()
        } else {
            powerManager.enable()
        }
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
            showNotification(title: NSLocalizedString("notification_title", comment: ""), 
                           body: String(format: NSLocalizedString("notification_removed_from_whitelist", comment: ""), currentSSID))
        } else {
            config.addToWhitelist(currentSSID)
            showNotification(title: NSLocalizedString("notification_title", comment: ""), 
                           body: String(format: NSLocalizedString("notification_added_to_whitelist", comment: ""), currentSSID))
        }
        
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