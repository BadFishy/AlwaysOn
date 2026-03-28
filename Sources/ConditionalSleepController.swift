import Foundation
import IOKit.ps

final class ConditionalSleepController {
    let wifiMonitor = WiFiMonitor()
    let batteryMonitor = BatteryMonitor()
    private let powerManager = PowerManager()
    private let config = ConfigManager.shared
    
    private var checkTimer: Timer?
    private var lastShouldPreventSleep: Bool = false
    private var lastStatusDescription: (status: String, detail: String)?
    
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
    
    func start() {
        if config.enableWakeOnPower {
            powerManager.enableWakeOnPower()
        }
        
        checkConditions()
        
        let interval = config.checkInterval
        let validInterval = max(1.0, min(interval, 300.0))
        if interval != validInterval {
            print("[AlwaysOn] Warning: checkInterval \(interval)s is out of range, using \(validInterval)s")
        }
        
        checkTimer = Timer.scheduledTimer(withTimeInterval: validInterval, repeats: true) { [weak self] _ in
            print("[AlwaysOn] Timer fired at \(Date())")
            self?.checkConditions()
        }
        
        print("[AlwaysOn] ConditionalSleepController started (interval: \(validInterval)s, raw config: \(interval)s)")
    }
    
    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        
        if powerManager.isEnabled {
            powerManager.disable()
        }
        
        print("[AlwaysOn] ConditionalSleepController stopped")
    }
    
    func checkConditions() {
        let shouldPrevent = shouldPreventSleep()
        let currentSSID = wifiMonitor.currentSSID ?? "未连接"
        let info = batteryMonitor.currentInfo()
        let isOnAC = info.isOnAC
        let isWhitelisted = config.isWhitelisted(wifiMonitor.currentSSID)
        let lidClosed = isLidClosed()
        let currentDesc = getStatusDescription()
        
        print("[AlwaysOn] 检测: WiFi='\(currentSSID)', 电源=\(isOnAC ? "插电" : "电池"), 白名单=\(isWhitelisted), 合盖=\(lidClosed), 阻止休眠=\(shouldPrevent)")
        
        if isWhitelisted && !isOnAC {
            let batteryLevel = info.percentage
            if batteryLevel < 20 && !lowBatteryWarningSent {
                lowBatteryWarningSent = true
            } else if batteryLevel >= 25 {
                lowBatteryWarningSent = false
            }
        } else {
            lowBatteryWarningSent = false
        }
        
        if shouldPrevent != lastShouldPreventSleep {
            if shouldPrevent {
                print("[AlwaysOn] 启动防休眠 (WiFi: \(currentSSID), 电源: \(isOnAC ? "插电" : "电池"))")
                powerManager.enable()
            } else {
                print("[AlwaysOn] 停止防休眠 (WiFi: \(currentSSID), 电源: \(isOnAC ? "插电" : "电池"))")
                powerManager.disable()
            }
            
            lastShouldPreventSleep = shouldPrevent
            lastStatusDescription = currentDesc
            onStatusChange?(currentStatus)
        }
    }
    
    func shouldPreventSleep() -> Bool {
        let info = batteryMonitor.currentInfo()
        let currentSSID = wifiMonitor.currentSSID
        let isWiFiConnected = currentSSID != nil
        let isWhitelisted = config.isWhitelisted(currentSSID)
        
        let condition1 = info.isOnAC && isWiFiConnected
        let condition2 = isWhitelisted
        
        let shouldPrevent = condition1 || condition2
        
        if shouldPrevent {
            print("[AlwaysOn] Sleep prevention triggered:")
            print("  - Condition 1 (AC+WiFi): \(condition1)")
            print("  - Condition 2 (Whitelist): \(condition2)")
            print("  - SSID: \(currentSSID ?? "nil")")
            print("  - Is Whitelisted: \(isWhitelisted)")
            print("  - Is On AC: \(info.isOnAC)")
        }
        
        return shouldPrevent
    }
    
    func getStatusDescription() -> (status: String, detail: String) {
        let ssid = wifiMonitor.currentSSID ?? "未连接"
        let info = batteryMonitor.currentInfo()
        let isWhitelisted = ConfigManager.shared.isWhitelisted(wifiMonitor.currentSSID)
        let isPreventing = shouldPreventSleep()
        
        let status = isPreventing ? "运行中" : "待机"
        let mode = info.isOnAC ? "电源" : (isWhitelisted ? "白名单" : "正常")
        
        return (status, "\(mode) · \(ssid)")
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
            print("[AlwaysOn] Failed to check lid state: \(error)")
            return false
        }
    }
}