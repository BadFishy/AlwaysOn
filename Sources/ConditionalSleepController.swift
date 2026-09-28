import Foundation
import IOKit.ps

/// 条件判断 + 守护。
///
/// 审计修正要点：
///
/// 1. **守护循环 1 秒**（旧版 60 秒）。`disablesleep` 是全局标志，实测会被其它程序
///    每 ~10 分钟清零一次（受控实验：插电 7.6 小时 0 次 → 改成某档后 44 分钟 5 次），
///    旧版只能在下一个 60 秒 tick 补回来，留下最长 60 秒的裸奔窗口——2026-09-16 11:29
///    机器就是这样在合盖状态下睡着的（标志被清后 3 秒即进入 Clamshell Sleep）。
///    现在每秒读一次内核状态（IORegistry，~7µs，无子进程），发现被清零**立即**补写。
/// 2. **系统电源事件驱动**：注册 `IOPMrootDomain` 通用兴趣通知。Apple 在 `IOPM.h` 里写明
///    合盖通知"睡眠会在本通知之后才发起"，所以这是唯一能在合盖瞬间拦下睡眠的路径；
///    旧版完全没有监听，只靠轮询。
/// 3. **定时器用 `.common` 模式**：旧版 `Timer.scheduledTimer` 只注册在 `.default`，
///    菜单跟踪/模态面板期间看门狗是暂停的。
/// 4. **SSID 三态**：旧版把"读不到 SSID"（未授予定位权限、漫游瞬时失败）等同于
///    "连了陌生网络"，直接 `disable()` → 主动放开休眠。现在只有**明确连上且不在白名单**
///    才会放开；读不到时沿用上一次判定。
/// 5. **电池保底真正接上**：旧版 `BatteryMonitor.start()` / `onCriticalBattery` /
///    `sleepNow()` 全是死代码，README 承诺的"5% 自动休眠"从未生效，而 `enable()` 又把
///    电池系统休眠设成 0 → 会一路跑到 0% 硬关机。
/// 6. **"允许休眠"状态也设防**：旧版 `prevent=false` 只在切换那一刻写一次 0，之后再也不复核，
///    于是任何第三方把标志写回 1 都会永久生效（用户会发现"再也睡不着"）。现在条件循环会复核，
///    并且在 UI 上暴露"期望与真实不一致"。
final class ConditionalSleepController {

    let wifiMonitor = WiFiMonitor()
    let batteryMonitor = BatteryMonitor()

    private let powerManager = PowerManager()
    private let systemEvents = SystemEvents()
    private let config = ConfigManager.shared

    private var conditionTimer: Timer?
    private var guardTimer: Timer?

    /// 条件判断得出的"是否应该阻止休眠"
    private(set) var desiredPrevention = false
    /// 上一次"读得到状态"时的条件判定，用于 SSID 读不到时保守沿用
    private var lastDecision: Bool?

    /// 电池保底是否已触发（触发期间强制放开休眠）
    private(set) var batteryFloorTriggered = false

    /// 真实状态：内核此刻是否真的禁用了休眠
    var actualPrevention: Bool { powerManager.isEnabled }

    var onStatusChange: (() -> Void)?

    /// 最近一次判定说明，供 UI/日志使用
    private(set) var lastReason = "尚未评估"

    /// 上一次"SSID 读不到"的原因，用于只告警一次
    private var lastSSIDWarningReason: String?

    // MARK: - 生命周期

    /// 是否已启动（用于让 `stop()` 幂等 —— 信号处理器与 `applicationWillTerminate`
    /// 都会调用它，重复清理不但会写两次日志，还会多做一次 pmset 写入）
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if config.enableWakeOnPower {
            powerManager.setWakeOnNetwork(true)
        }

        wifiMonitor.requestPermissionIfNeeded()

        // 系统电源事件：合盖（先于睡眠送达）、睡眠/唤醒切换、电池耗尽、电源切换
        systemEvents.onPowerEvent = { [weak self] _ in
            guard let self = self else { return }
            // 1) 立刻做最关键且零成本的动作：确保内核标志符合期望。
            //    合盖通知"先于睡眠送达"，这一句才是真正能拦下合盖睡眠的关键路径。
            self.guardTick()
            // 2) 之后再补一次完整的条件复核；连续事件会被合并成一次，
            //    避免在事件风暴里反复读 CoreWLAN（那是会阻塞主线程的调用）。
            self.scheduleConditionCheck(reason: "系统电源事件")
        }
        systemEvents.start()

        // 启动自愈：如果上一次是崩溃退出的，标志可能还留在 1。
        // 先按当前条件评估一次，条件不满足时会主动写回 0。
        checkConditions(reason: "启动")

        let interval = config.checkInterval
        conditionTimer = makeTimer(interval: interval) { [weak self] in
            self?.conditionsTick()
        }

        let guardInterval = config.guardInterval
        guardTimer = makeTimer(interval: guardInterval) { [weak self] in
            self?.guardTick()
        }

        batteryMonitor.onCriticalBattery = { [weak self] in
            self?.handleCriticalBattery()
        }
        batteryMonitor.start()

        FileLogger.shared.log("""
            守护已启动：条件检测 \(interval)s + 标志守护 \(guardInterval)s + 系统电源事件
            """)
    }

    /// 幂等：信号处理器与 `applicationWillTerminate` 都会调用，重复执行无意义。
    func stop() {
        guard isRunning else { return }
        isRunning = false

        conditionTimer?.invalidate()
        conditionTimer = nil
        guardTimer?.invalidate()
        guardTimer = nil
        pendingCheck?.cancel()
        pendingCheck = nil
        batteryMonitor.stop()
        systemEvents.stop()

        // 退出时把标志恢复成"允许休眠"，避免把全局标志留在禁用状态
        if powerManager.readSleepDisabled() == true {
            powerManager.disable()
        }

        FileLogger.shared.log("守护已停止，休眠已恢复")
    }

    /// `Timer.scheduledTimer` 只注册在 `.default` 模式，菜单打开或模态弹窗期间不会触发。
    /// 这里显式加到 `.common`，保证菜单跟踪期间守查看门狗照常工作。
    private func makeTimer(interval: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: - 事件

    /// 条件循环：评估电源/WiFi/盖子条件并切换状态（兜底）
    private func conditionsTick() {
        checkConditions(reason: "定时")
    }

    /// 守护循环：只做一件事 —— 确保内核标志与期望一致。默认每秒一次。
    private func guardTick() {
        let actual = powerManager.readSleepDisabled()

        guard desiredPrevention else {
            guard actual == true else { return }
            // 期望"允许休眠"但标志是 1（被别的程序写回）：低频纠正，每个条件周期最多一次，
            // 避免和对方做每秒一次的热循环写。
            let now = Date()
            guard now.timeIntervalSince(lastSleepAllowedDefense) >= config.checkInterval else { return }
            lastSleepAllowedDefense = now
            FileLogger.shared.log("⚠️ 期望允许休眠但标志被外部写成 1，正在改回 0")
            attemptWrite { self.powerManager.disable() }
            onStatusChange?()
            return
        }

        guard actual == false else { return }   // 正常：标志为 1

        // 没有写入权限时（例如首次运行还没授权），**不要每秒去撞一次**：
        // 那会产生 60 次/分钟的子进程和刷屏日志。改成按条件周期重试，
        // 并在第一次被拒时明确告诉用户，权限恢复后自动重新接管。
        if !writeAccessGranted {
            let now = Date()
            guard now.timeIntervalSince(lastWriteAttempt) >= config.checkInterval else { return }
        }
        lastWriteAttempt = Date()

        FileLogger.shared.log("⚠️ disablesleep 被外部清零（守护循环发现），立即重新断言")
        attemptWrite { self.powerManager.enable() }
        onStatusChange?()
    }

    /// 执行一次写入；失败时标记为"无写入权限"并只告警一次（避免刷屏）。
    private func attemptWrite(_ body: () -> Bool) {
        let ok = body()
        if ok {
            if !writeAccessGranted {
                FileLogger.shared.log("✅ pmset 写入权限已恢复，重新接管守护")
            }
            writeAccessGranted = true
        } else {
            if writeAccessGranted {
                FileLogger.shared.log("""
                    ❌ pmset 写入被拒：缺少免密授权。已暂停每秒重试（改为每分钟一次），\
                    请在菜单中点击「缺少权限」完成授权
                    """)
            }
            writeAccessGranted = false
        }
    }

    /// 当前是否具备 pmset 写入权限（供 UI 显示）
    private(set) var writeAccessGranted = true

    /// 上一次"把标志改回 0"的时间，用于低频纠正限流
    private var lastSleepAllowedDefense = Date.distantPast
    /// 上一次写入尝试时间，用于无权限时的降频重试
    private var lastWriteAttempt = Date.distantPast

    /// 系统电源事件只做防抖复核（真正的即时动作是 `guardTick()`，由事件回调直接调用）
    private func scheduleConditionCheck(reason: String, delay: TimeInterval = 0.3) {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.checkConditions(reason: reason)
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 待执行的防抖复核
    private var pendingCheck: DispatchWorkItem?

    private func handleCriticalBattery() {
        batteryFloorTriggered = true
        FileLogger.shared.log("🔋 电池保底触发：立即放开休眠")
        powerManager.disable()
        if SystemEvents.isLidClosed == true {
            FileLogger.shared.log("🔋 合盖状态，直接进入休眠")
            powerManager.sleepNow()
        }
        checkConditions(reason: "电池保底")
    }

    // MARK: - 条件评估

    func checkConditions(reason: String) {
        updateBatteryFloor()
        // 只读一次 SSID 状态，评估与日志共用同一个快照
        // （旧版在同一个 tick 里读了 3 次，日志会与实际决策互相矛盾，排障很痛苦）
        let ssid = wifiMonitor.ssidState
        let decision = evaluateShouldPreventSleep(ssidState: ssid)
        lastDecision = decision
        desiredPrevention = decision

        // SSID 读不到是一条**会让白名单失效**的降级路径，不能静默：
        // 只在原因变化时告警一次，避免每分钟刷屏。
        if case .unavailable(let why) = ssid {
            if why != lastSSIDWarningReason {
                lastSSIDWarningReason = why
                FileLogger.shared.log("""
                    ⚠️ WiFi SSID 读不到（\(why)）：白名单无法判定，暂沿用上一次决定。\
                    若是权限问题，请在菜单里点「定位权限」修复
                    """)
            }
        } else {
            lastSSIDWarningReason = nil
        }

        let actual = powerManager.readSleepDisabled()
        let info = batteryMonitor.currentInfo()
        let lid = SystemEvents.isLidClosed

        FileLogger.shared.log("""
            检测[\(reason)]: WiFi=\(ssid.description)，\
            电源=\(info.isOnAC ? "插电" : "电池")\(info.percentage >= 0 ? "(\(info.percentage)%)" : "")，\
            合盖=\(lid.map { $0 ? "是" : "否" } ?? "未知")，\
            enabled=\(config.enabled)，期望=\(decision)，实际=\(actual.map { $0 ? "1" : "0" } ?? "未知")，\
            说明=\(lastReason)
            """)

        let changed = (actual != decision)
        if changed {
            if decision {
                FileLogger.shared.log("启动防休眠")
                attemptWrite { self.powerManager.enable() }
            } else {
                FileLogger.shared.log("停止防休眠（恢复系统休眠）")
                attemptWrite { self.powerManager.disable() }
            }
            onStatusChange?()
        }
    }

    /// 电池保底：低于下限且在用电池 → 强制放开休眠（合盖时直接睡）。
    private func updateBatteryFloor() {
        let floor = config.batteryFloor
        guard floor > 0 else {
            batteryFloorTriggered = false
            return
        }
        let info = batteryMonitor.currentInfo()
        guard info.percentage >= 0 else { return }        // 桌面机/读不到

        let onBattery = !info.isOnAC
        if onBattery, info.percentage <= floor {
            if !batteryFloorTriggered {
                batteryFloorTriggered = true
                FileLogger.shared.log("🔋 电池 \(info.percentage)% ≤ 下限 \(floor)%：放开休眠")
                attemptWrite { self.powerManager.disable() }
                if SystemEvents.isLidClosed == true {
                    powerManager.sleepNow()
                }
            }
        } else if info.percentage > floor + 2 {           // 2% 迟滞，避免在阈值上抖
            batteryFloorTriggered = false
        }
    }

    /// 判断是否应该阻止休眠。
    ///
    /// - AC："always" 插电即阻止；"wifi_required" 需要已连接 WiFi
    /// - 电池："whitelist" 仅白名单 WiFi；"any_wifi" 有 WiFi 即可
    /// - SSID 读不到（权限未授予 / 漫游瞬时失败）时**沿用上一次判定**，不主动放开休眠
    func evaluateShouldPreventSleep(ssidState: SSIDState) -> Bool {
        guard config.enabled else {
            lastReason = "手动开关已关闭"
            return false
        }
        if batteryFloorTriggered {
            lastReason = "电池保底已触发"
            return false
        }

        let info = batteryMonitor.currentInfo()
        let onAC = info.isOnAC
        let powerText = onAC ? "插电" : "电池"

        switch ssidState {
        case .connected(let ssid):
            let whitelisted = config.isWhitelisted(ssid)
            if onAC {
                switch config.acMode {
                case "wifi_required":
                    lastReason = "\(powerText)+WiFi(\(ssid))"
                    return true
                default:
                    lastReason = "\(powerText) 恒阻止"
                    return true
                }
            } else {
                switch config.batteryMode {
                case "any_wifi":
                    lastReason = "\(powerText)+任意 WiFi(\(ssid))"
                    return true
                default:
                    lastReason = whitelisted
                        ? "\(powerText)+白名单 WiFi(\(ssid))"
                        : "\(powerText)+非白名单 WiFi(\(ssid))"
                    return whitelisted
                }
            }

        case .notConnected:
            if onAC {
                let decision = (config.acMode != "wifi_required")
                lastReason = decision ? "\(powerText) 恒阻止（未连 WiFi）" : "\(powerText) 需要 WiFi 但未连接"
                return decision
            }
            lastReason = "\(powerText)+未连接 WiFi"
            return false

        case .unavailable(let why):
            // 关键：读不到 SSID 不等于"连了陌生网络"，不要因此放开休眠
            if let previous = lastDecision {
                lastReason = "SSID 读不到（\(why)），沿用上一次判定 \(previous ? "阻止" : "放开")"
                return previous
            }
            let conservative = onAC
            lastReason = "SSID 读不到（\(why)），无历史判定，按\(conservative ? "阻止" : "放开")处理"
            return conservative
        }
    }

    // MARK: - UI 状态

    enum PredictedStatus {
        case willStayAwake   // 期望并已实际阻止休眠
        case willSleep       // 允许休眠
        case disabled        // 手动关闭
        case inconsistent    // 期望阻止但实际未生效（被外部改写 / 权限缺失）
    }

    func status() -> PredictedStatus {
        guard config.enabled else { return .disabled }
        if desiredPrevention && !actualPrevention { return .inconsistent }
        return desiredPrevention ? .willStayAwake : .willSleep
    }
}
