import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// 系统电源事件源。
///
/// 旧版每个 tick 都 `fork/exec` 一次 `ioreg` 去问盖子状态（一天 1440 次子进程），
/// 而且**完全靠 60 秒轮询**——审计里 524 次 `disablesleep` 被外部清零的窗口就靠它兜。
///
/// 这里换成 Apple 官方的事件机制，全部零子进程：
///
/// - `kIOPMMessageClamshellStateChange`：注册在 `IOPMrootDomain` 上的通用兴趣通知。
///   `IOPM.h` 的原文是 —— *"If this clamshell change results in a sleep, the sleep will
///   initiate soon AFTER delivery of this message."* 也就是说**通知先于睡眠送达**，
///   所以在这个回调里补写 `disablesleep` 是有机会拦下合盖睡眠的。这是本项目唯一
///   能真正"关上那扇门"的机制。
/// - `kIOPMMessageSleepWakeUUIDChange`：睡眠开始时设置 UUID、唤醒完成时清除，
///   用来在任何一次睡眠之后**立刻恢复保护**，避免"醒一下又睡回去"。
/// - `IOPSNotificationCreateRunLoopSource`：电源（适配器/电池）切换。
/// - `AppleClamshellState` / `SleepDisabled` 等键直接从 IORegistry 进程内读（~7µs），
///   不再起 `ioreg` 进程。
///
/// 消息常量按 Apple 头文件展开：`iokit_family_msg(sub, msg) = sys_iokit | sub | msg`，
/// 其中 `sys_iokit = err_system(0x38) = 0x38 << 26`、
/// `sub_iokit_powermanagement = err_sub(13) = 13 << 14`。
final class SystemEvents {

    /// 从 `IOPMrootDomain` 读一个布尔属性（进程内）。
    private static func rootDomainBool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        let value = property.takeRetainedValue()
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    /// 盖子是否合上。`nil` = 读不到（桌面 Mac 没有这个键）。
    static var isLidClosed: Bool? { rootDomainBool("AppleClamshellState") }

    // MARK: - 消息常量（数值由 Apple 头文件展开得出）

    private static let messageClamshellStateChange: UInt32 = (0x38 << 26) | (13 << 14) | 0x100
    private static let messageInternalBatteryFullyDischarged: UInt32 = (0x38 << 26) | (13 << 14) | 0x120
    private static let messageSleepWakeUUIDChange: UInt32 = (0x38 << 26) | (13 << 14) | 0x140
    private static let messageDriverAssertionsChanged: UInt32 = (0x38 << 26) | (13 << 14) | 0x150
    private static let messageDarkWakeThermalEmergency: UInt32 = (0x38 << 26) | (13 << 14) | 0x160

    /// 已经记录过的事件类型。用来对"无关但可能高频"的事件只记一次日志。
    private var loggedTypes = Set<UInt32>()

    // MARK: - 回调

    /// 收到任何 `IOPMrootDomain` 电源事件。参数是消息类型，便于日志区分。
    var onPowerEvent: ((UInt32) -> Void)?

    // MARK: - 私有状态

    private var rootDomainService: io_service_t = IO_OBJECT_NULL
    private var notificationPort: IONotificationPortRef?
    private var interestNotifier: io_object_t = IO_OBJECT_NULL
    private var powerSourceSource: CFRunLoopSource?
    private var started = false

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        startRootDomainInterest()
        startPowerSourceWatch()
    }

    func stop() {
        guard started else { return }
        started = false

        if interestNotifier != IO_OBJECT_NULL {
            IOObjectRelease(interestNotifier)
            interestNotifier = IO_OBJECT_NULL
        }
        if let port = notificationPort {
            let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        if rootDomainService != IO_OBJECT_NULL {
            IOObjectRelease(rootDomainService)
            rootDomainService = IO_OBJECT_NULL
        }
        if let source = powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceSource = nil
        }
    }

    // MARK: - IOPMrootDomain 通用兴趣通知

    private func startRootDomainInterest() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else {
            FileLogger.shared.log("⚠️ 找不到 IOPMrootDomain，无法注册电源事件通知")
            return
        }
        rootDomainService = service

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            FileLogger.shared.log("⚠️ IONotificationPortCreate 失败")
            return
        }
        notificationPort = port

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refcon, _, messageType, _ in
            guard let refcon = refcon else { return }
            let events = Unmanaged<SystemEvents>.fromOpaque(refcon).takeUnretainedValue()
            // 通知回调在注册它的 run loop 线程上执行，即主线程 —— 直接调用是安全的。
            events.handle(messageType: messageType)
        }

        let result = IOServiceAddInterestNotification(
            port, service, kIOGeneralInterest, callback, context, &interestNotifier)
        guard result == KERN_SUCCESS else {
            FileLogger.shared.log("⚠️ IOServiceAddInterestNotification 失败：0x\(String(result, radix: 16))")
            return
        }

        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        FileLogger.shared.log("已注册 IOPMrootDomain 电源事件通知（合盖/睡眠唤醒/电池耗尽）")
    }

    private func handle(messageType: UInt32) {
        // 只对**真正相关**的事件触发条件评估。
        //
        // 注意 `kIOPMMessageDriverAssertionsChanged`(0x150)：内核 PM 驱动断言一变就发，
        // 实测启动瞬间会连发一串。对它做完整条件评估（读 CoreWLAN 等）纯属浪费，
        // 而且会刷日志，所以这里明确忽略。
        switch messageType {
        case SystemEvents.messageClamshellStateChange:
            FileLogger.shared.log("⚡️ 合盖状态变化（睡眠会在本通知之后才发起）")
        case SystemEvents.messageSleepWakeUUIDChange:
            FileLogger.shared.log("⚡️ 睡眠/唤醒切换")
        case SystemEvents.messageInternalBatteryFullyDischarged:
            FileLogger.shared.log("🔋 电池完全耗尽")
        case SystemEvents.messageDarkWakeThermalEmergency:
            FileLogger.shared.log("🌡️ DarkWake 过热，系统可能很快再次休眠")
        case SystemEvents.messageDriverAssertionsChanged:
            if loggedTypes.insert(messageType).inserted {
                FileLogger.shared.log("（忽略高频事件 0x\(String(messageType, radix: 16))：驱动断言变化，不触发条件评估）")
            }
            return
        default:
            if loggedTypes.insert(messageType).inserted {
                FileLogger.shared.log("（忽略未处理事件 0x\(String(messageType, radix: 16))）")
            }
            return
        }
        onPowerEvent?(messageType)
    }

    // MARK: - 电源切换通知

    private func startPowerSourceWatch() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { refcon in
            guard let refcon = refcon else { return }
            let events = Unmanaged<SystemEvents>.fromOpaque(refcon).takeUnretainedValue()
            FileLogger.shared.log("⚡️ 收到电源切换通知")
            events.onPowerEvent?(0)
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else {
            FileLogger.shared.log("⚠️ IOPSNotificationCreateRunLoopSource 失败")
            return
        }
        powerSourceSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        FileLogger.shared.log("已注册电源切换通知")
    }
}
