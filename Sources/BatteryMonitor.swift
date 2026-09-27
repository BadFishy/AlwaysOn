import Foundation
import IOKit.ps
import UserNotifications

/// 电池状态读取 + 低电量提醒。
///
/// 审计修正：
/// - 旧版 `start()` / `onCriticalBattery` **从未被调用**（`AppDelegate` 只用了
///   `currentInfo()` 来显示电量），README 承诺的"电量 5% 自动休眠"是死代码；
///   同时 `enable()` 把电池系统休眠设成 0，等于一路跑到 0% 硬关机。
/// - 旧版"是否合盖"自己再 `fork/exec` 一次 `ioreg`（`isClamshellClosed()`），
///   现统一走 `SystemEvents`，零子进程。
/// - 旧版没有区分"在用电池"与"电池正在放电"（插着电源但未充电时 `isOnAC` 为真，
///   而只是没在充电不应触发保底）。这里暴露 `isDraining`。
final class BatteryMonitor {
    private var timer: Timer?
    private let interval: TimeInterval = 60
    private let warningThreshold = 10

    /// 低电量（≤10%）且在用电池：控制器据此触发保底
    var onCriticalBattery: (() -> Void)?

    struct BatteryInfo {
        let percentage: Int          // -1 = 读不到（桌面机）
        let isOnAC: Bool
        let isDraining: Bool
        var hasBattery: Bool { percentage >= 0 }
    }

    private var lastWarnedLevel: Int?

    func start() {
        checkBattery()
        // 加到 .common 模式：菜单跟踪/模态面板期间也照常触发
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkBattery()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func currentInfo() -> BatteryInfo {
        return readBattery()
    }

    private func checkBattery() {
        let info = readBattery()
        // 桌面机没有电池 → 跳过所有电池逻辑
        guard info.hasBattery, !info.isOnAC else {
            lastWarnedLevel = nil
            return
        }

        if info.percentage <= warningThreshold {
            if lastWarnedLevel == nil || (lastWarnedLevel! - info.percentage) >= 5 {
                lastWarnedLevel = info.percentage
                sendNotification(
                    title: "AlwaysOn",
                    body: "电量 \(info.percentage)% —— 到达下限后会放开休眠"
                )
            }
            onCriticalBattery?()
        }
    }

    private func readBattery() -> BatteryInfo {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?
                  .takeUnretainedValue() as? [String: Any]
        else {
            // 无电源信息 —— 桌面 Mac 或读取失败
            return BatteryInfo(percentage: -1, isOnAC: true, isDraining: false)
        }

        let capacity = desc[kIOPSCurrentCapacityKey] as? Int ?? -1
        let source = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let isOnAC = (source == kIOPSACPowerValue)
        let draining = (desc[kIOPSIsChargingKey] as? Bool == false) && !isOnAC

        return BatteryInfo(percentage: capacity, isOnAC: isOnAC, isDraining: draining)
    }

    private func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
