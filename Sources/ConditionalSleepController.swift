import Foundation
import IOKit.ps

final class ConditionalSleepController {
    let wifiMonitor = WiFiMonitor()
    let batteryMonitor = BatteryMonitor()
    private let powerManager = PowerManager()
    private let config = ConfigManager.shared
    
    private var checkTimer: Timer?
    private var lastShouldPreventSleep: Bool = false
    
    var onStatusChange: (() -> Void)?
    
    /// 当前是否正在阻止休眠
    var isPreventingSleep: Bool {
        return powerManager.isEnabled
    }
    
    /// 启动条件检测
    func start() {
        // 如果启用了唤醒功能，先设置 Wake-on-Power
        if config.enableWakeOnPower {
            powerManager.enableWakeOnPower()
        }
        
        // 请求位置权限（获取 WiFi SSID 需要）
        wifiMonitor.requestPermissionIfNeeded()
        
        // 立即执行一次检测
        checkConditions()
        
        // 设置定时器定期检测
        let interval = config.checkInterval
        let validInterval = max(1.0, min(interval, 300.0))
        if interval != validInterval {
            print("[AlwaysOn] Warning: checkInterval \(interval)s is out of range, using \(validInterval)s")
        }
        
        checkTimer = Timer.scheduledTimer(withTimeInterval: validInterval, repeats: true) { [weak self] _ in
            print("[AlwaysOn] Timer fired at \(Date())")
            self?.checkConditions()
        }
        
        print("[AlwaysOn] ConditionalSleepController started (interval: \(validInterval)s)")
    }
    
    /// 停止条件检测
    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        
        // 确保恢复系统默认设置
        if powerManager.isEnabled {
            powerManager.disable()
        }
        
        print("[AlwaysOn] ConditionalSleepController stopped")
    }
    
    /// 检测当前条件并决定是否阻止休眠
    func checkConditions() {
        let shouldPrevent = shouldPreventSleep()
        let currentSSID = wifiMonitor.currentSSID ?? "未连接"
        let info = batteryMonitor.currentInfo()
        let isOnAC = info.isOnAC
        let isWhitelisted = config.isWhitelisted(wifiMonitor.currentSSID)
        let lidClosed = LidStateProvider.shared.isLidClosed()
        
        print("[AlwaysOn] 检测: WiFi='\(currentSSID)', 电源=\(isOnAC ? "插电" : "电池"), 白名单=\(isWhitelisted), 合盖=\(lidClosed), enabled=\(config.enabled), 阻止休眠=\(shouldPrevent)")
        
        // 只在状态变化时执行操作
        if shouldPrevent != lastShouldPreventSleep {
            if shouldPrevent {
                print("[AlwaysOn] 启动防休眠 (WiFi: \(currentSSID), 电源: \(isOnAC ? "插电" : "电池"))")
                powerManager.enable()
            } else {
                print("[AlwaysOn] 停止防休眠 (WiFi: \(currentSSID), 电源: \(isOnAC ? "插电" : "电池"))")
                powerManager.disable()
            }
            
            lastShouldPreventSleep = shouldPrevent
            onStatusChange?()
        }
    }
    
    /// 判断是否应该阻止休眠
    /// 不再要求合盖才启用 — 条件满足就提前启用 pmset disablesleep
    ///
    /// 手动开关关闭时，直接返回 false
    /// AC 模式 "always": 插电即不休眠
    /// AC 模式 "wifi_required": 插电 + WiFi 连接
    /// 电池模式 "whitelist": 白名单 WiFi（无论是否插电）
    /// 电池模式 "any_wifi": 有 WiFi 就行（无论是否插电）
    func shouldPreventSleep() -> Bool {
        // 手动开关
        guard config.enabled else {
            return false
        }
        
        let info = batteryMonitor.currentInfo()
        let currentSSID = wifiMonitor.currentSSID
        let isWiFiConnected = currentSSID != nil
        let isWhitelisted = config.isWhitelisted(currentSSID)
        
        if info.isOnAC {
            // AC 模式判断
            switch config.acMode {
            case "always":
                return true
            case "wifi_required":
                return isWiFiConnected
            default:
                return true
            }
        } else {
            // 电池模式判断
            switch config.batteryMode {
            case "whitelist":
                return isWhitelisted
            case "any_wifi":
                return isWiFiConnected
            default:
                return isWhitelisted
            }
        }
    }
    
    /// 预测合盖后是否会保持唤醒（用于菜单状态显示）
    /// 与 shouldPreventSleep 逻辑一致，但用于 UI 文本
    func predictedStatus() -> PredictedStatus {
        guard config.enabled else {
            return .disabled
        }
        
        if shouldPreventSleep() {
            return .willStayAwake
        } else {
            return .willSleep
        }
    }
    
    enum PredictedStatus {
        case willStayAwake  // 合盖后保持唤醒
        case willSleep      // 未保持唤醒
        case disabled       // 已关闭
    }
}
