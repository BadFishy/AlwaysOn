import Foundation
import IOKit.ps

final class ConditionalSleepController {
    let wifiMonitor = WiFiMonitor()
    let batteryMonitor = BatteryMonitor()
    private let powerManager = PowerManager()
    private let config = ConfigManager.shared
    private var webhook: WebhookManager { WebhookManager.shared }
    
    private var checkTimer: Timer?
    private var lastShouldPreventSleep: Bool = false
    private var lastStatusDescription: (status: String, detail: String)?
    
    // 低电量警告状态跟踪
    private var lowBatteryWarningSent = false
    
    var onStatusChange: ((SleepStatus) -> Void)?
    
    enum SleepStatus: String {
        case active = "运行中"
        case inactive = "待机"
        case whitelistMode = "白名单模式"
        case acMode = "电源模式"
    }
    
    var currentStatus: SleepStatus {
        let isPreventing = shouldPreventSleep()
        let isOnAC = batteryMonitor.currentInfo().isOnAC
        let isWhitelisted = config.isWhitelisted(wifiMonitor.currentSSID)
        
        if isPreventing {
            if isOnAC {
                return .acMode
            } else if isWhitelisted {
                return .whitelistMode
            }
        }
        return isPreventing ? .active : .inactive
    }
    
    /// 启动条件检测
    func start() {
        // 如果启用了唤醒功能，先设置 Wake-on-Power
        if config.enableWakeOnPower {
            powerManager.enableWakeOnPower()
        }
        
        // 立即执行一次检测
        checkConditions()
        
        // 设置定时器定期检测
        let interval = config.checkInterval
        
        // 验证间隔值，确保在合理范围内
        let validInterval = max(1.0, min(interval, 300.0)) // 限制在 1-300 秒之间
        if interval != validInterval {
            print("[CoffeeGuard] Warning: checkInterval \(interval)s is out of range, using \(validInterval)s")
        }
        
        checkTimer = Timer.scheduledTimer(withTimeInterval: validInterval, repeats: true) { [weak self] _ in
            print("[CoffeeGuard] Timer fired at \(Date())")
            self?.checkConditions()
        }
        
        print("[CoffeeGuard] ConditionalSleepController started (interval: \(validInterval)s, raw config: \(interval)s)")
    }
    
    /// 停止条件检测
    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        
        // 确保恢复系统默认设置
        if powerManager.isEnabled {
            powerManager.disable()
        }
        
        print("[CoffeeGuard] ConditionalSleepController stopped")
    }
    
    /// 检测当前条件并决定是否阻止休眠
    func checkConditions() {
        let shouldPrevent = shouldPreventSleep()
        let currentSSID = wifiMonitor.currentSSID ?? "未连接"
        let info = batteryMonitor.currentInfo()
        let isOnAC = info.isOnAC
        let isWhitelisted = config.isWhitelisted(wifiMonitor.currentSSID)
        let lidClosed = isLidClosed()
        let currentDesc = getStatusDescription()
        
        print("[AlwaysOn] 检测: WiFi='\(currentSSID)', 电源=\(isOnAC ? "插电" : "电池"), 白名单=\(isWhitelisted), 合盖=\(lidClosed), 阻止休眠=\(shouldPrevent)")
        
        // 检查 WiFi 检测是否失败
        if let wifiError = wifiMonitor.lastError {
            webhook.sendErrorNotification(
                errorType: NSLocalizedString("error_type_network", comment: ""),
                details: wifiError.localizedDescription
            )
            wifiMonitor.lastError = nil // 清除错误，避免重复发送
        }
        
        // 检查低电量警告（白名单模式下电池 < 20%）
        if isWhitelisted && !isOnAC {
            let batteryLevel = info.percentage
            if batteryLevel < 20 && !lowBatteryWarningSent {
                webhook.sendLowBatteryWarning(batteryLevel: batteryLevel)
                lowBatteryWarningSent = true
            } else if batteryLevel >= 25 {
                // 电量恢复到25%以上时重置警告状态
                lowBatteryWarningSent = false
            }
        } else {
            // 不在白名单模式或插电时重置警告状态
            lowBatteryWarningSent = false
        }
        
        // 只在状态变化时执行操作
        if shouldPrevent != lastShouldPreventSleep {
            if shouldPrevent {
                print("[AlwaysOn] 启动防休眠 (WiFi: \(currentSSID), 电源: \(isOnAC ? "插电" : "电池"))")
                powerManager.enable()
            } else {
                print("[AlwaysOn] 停止防休眠 (WiFi: \(currentSSID), 电源: \(isOnAC ? "插电" : "电池"))")
                powerManager.disable()
            }
            
            // 发送 webhook 通知
            let previousStatus = lastStatusDescription?.status ?? "未知"
            let powerStr = isOnAC ? "电源适配器" : "电池"
            let lidStr = lidClosed ? "合上" : "打开"
            let modeStr = isOnAC ? "电源模式" : (isWhitelisted ? "白名单模式" : "正常模式")
            
            webhook.sendStatusChanged(
                previousStatus: previousStatus,
                currentStatus: currentDesc.status,
                wifi: wifiMonitor.currentSSID,
                power: powerStr,
                lid: lidStr,
                mode: modeStr
            )
            
            lastShouldPreventSleep = shouldPrevent
            lastStatusDescription = currentDesc
            onStatusChange?(currentStatus)
        }
    }
    
    /// 判断是否应该阻止休眠
    /// 条件1: 插电 + WiFi连接 + 合盖
    /// 条件2: 白名单WiFi + 合盖 (无论是否插电)
    func shouldPreventSleep() -> Bool {
        let info = batteryMonitor.currentInfo()
        let currentSSID = wifiMonitor.currentSSID
        let isWiFiConnected = currentSSID != nil
        let isWhitelisted = config.isWhitelisted(currentSSID)
        let isClamshellClosed = isLidClosed()
        
        // 只有合盖时才需要处理
        guard isClamshellClosed else {
            return false
        }
        
        // 条件1: 插电 + WiFi连接 + 合盖
        let condition1 = info.isOnAC && isWiFiConnected
        
        // 条件2: 白名单WiFi + 合盖 (电池模式下也生效)
        let condition2 = isWhitelisted
        
        let shouldPrevent = condition1 || condition2
        
        // 详细的调试日志
        if shouldPrevent {
            print("[CoffeeGuard] Sleep prevention triggered:")
            print("  - Condition 1 (AC+WiFi): \(condition1)")
            print("  - Condition 2 (Whitelist): \(condition2)")
            print("  - SSID: \(currentSSID ?? "nil")")
            print("  - Is Whitelisted: \(isWhitelisted)")
            print("  - Is On AC: \(info.isOnAC)")
            print("  - Is Lid Closed: \(isClamshellClosed)")
        }
        
        return shouldPrevent
    }
    
    /// 获取当前状态描述（用于菜单显示）
    func getStatusDescription() -> (status: String, detail: String) {
        let ssid = wifiMonitor.currentSSID ?? "未连接"
        let info = batteryMonitor.currentInfo()
        let isWhitelisted = ConfigManager.shared.isWhitelisted(wifiMonitor.currentSSID)
        let isPreventing = shouldPreventSleep()
        
        let status = isPreventing ? "运行中" : "待机"
        let mode = info.isOnAC ? "电源" : (isWhitelisted ? "白名单" : "正常")
        
        return (status, "\(mode) · \(ssid)")
    }
    
    // MARK: - Private Helpers
    
    /// 检测盖子是否合上
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
            print("[CoffeeGuard] Failed to check lid state: \(error)")
            return false
        }
    }
}
