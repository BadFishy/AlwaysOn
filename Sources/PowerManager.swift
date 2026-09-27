import Foundation
import IOKit

/// 单一职责：把 `pmset disablesleep` 这个**全局**标志读准、写对。
///
/// 设计约束（来自 2026-09 审计报告，逐条对应修掉的漏洞）：
///
/// 1. **只写 `disablesleep`**。旧版 `enable()`/`disable()` 还会写 `standby`、`autopoweroff`、
///    `disksleep`、`networkoversleep`、`tcpkeepalive`、`-b/-c sleep`、`-b/-c displaysleep`
///    共 9 个键，而 `disable()` 把它们"恢复"成硬编码的猜测值（其中 `-b sleep 1` 会把电池
///    系统休眠改成 **1 分钟**），且从不保存用户原值 —— 一旦执行就永久破坏用户的电源配置。
///    现在这些写入全部删除。
/// 2. **不用 `caffeinate`**。Apple 的 `IOPMLib.h` 明确写着公共断言
///    "The system may still sleep for lid close"，`caffeinate -s` 对应的
///    `kIOPMAssertionTypePreventSystemSleep` 更是 `@deprecated ... not supported in any OS X
///    releases`。它对合盖保活毫无作用，只会制造孤儿进程（实测残留 2 天 18 小时）。
/// 3. **写入后必须回读校验**。实测 `pmset -a <写>` 在"拒绝写入"时也会返回退出码 **0**
///    （打印 `'pmset' must be run as root...` 但 `exit=0`），所以检查退出码不足够。
/// 4. **状态读取走 IORegistry**（`IOPMrootDomain` 的 `SleepDisabled`）：进程内读取仅 ~7µs
///    （实测 10000 次 0.074s），属性始终存在（0=`No`，1=`Yes`），且它是内核**实际生效**的
///    状态。`pmset -g`/plist 只作兜底 —— 审计中发现过 powerd 侧 `isSleepDisabled : 0`
///    而 plist 仍为 `true` 的分歧，说明持久化值不等于生效值。
final class PowerManager {

    // MARK: - 读取

    /// 内核实际生效的 `SleepDisabled`（进程内，无子进程）。
    static func registryFlag() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0) else { return nil }
        let value = property.takeRetainedValue()
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    /// 兜底一：持久化的电源配置。
    static func prefsFlag() -> Bool? {
        let domain = "com.apple.PowerManagement" as CFString
        let key = "SystemPowerSettings" as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        guard let settings = CFPreferencesCopyValue(
            key, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) as? [String: Any] else {
            return nil
        }
        if let bool = settings["SleepDisabled"] as? Bool { return bool }
        if let number = settings["SleepDisabled"] as? NSNumber { return number.boolValue }
        return nil
    }

    /// 兜底二：解析 `pmset -g`。按空白切分取最后一个 token，**不依赖** tab/空格的数量。
    /// （`pmset -g` 在同一份输出里混用 tab 和空格补齐，写死分隔符的解析很脆。）
    static func parsedFlag() -> Bool? {
        let manager = PowerManager()
        let (status, output) = manager.run("/usr/bin/pmset", ["-g"])
        guard status == 0 else { return nil }
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: "SleepDisabled", options: .caseInsensitive) else { continue }
            let tokens = line[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let last = tokens.last else { return true }   // 只有键名 = 标志已置位
            return last == "1"
        }
        return nil   // 该行不存在
    }

    /// 真实状态。三层来源依次尝试；全部失败返回 nil（**不要**把"读不到"当成 false）。
    func readSleepDisabled() -> Bool? {
        if let value = PowerManager.registryFlag() { return value }
        if let value = PowerManager.prefsFlag() { return value }
        return PowerManager.parsedFlag()
    }

    /// 当前是否真的在阻止休眠。
    var isEnabled: Bool { readSleepDisabled() ?? false }

    // MARK: - 写入

    /// 写入目标状态并**回读校验**。返回是否确实达到目标状态。
    @discardableResult
    func setSleepDisabled(_ disabled: Bool) -> Bool {
        let target = disabled ? "1" : "0"

        // 已经是目标状态就不必起进程（守护循环每秒调用一次，这点很重要）
        if readSleepDisabled() == disabled { return true }

        // `-k` 作废 sudo 的缓存凭据：结果只取决于 /etc/sudoers.d 里的规则，
        // 不受"刚刚输入过密码"影响。`-n` 保证永不提示密码（GUI 进程没有 TTY）。
        let (status, output) = run("/usr/bin/sudo",
                                  ["-n", "-k", "/usr/bin/pmset", "-a", "disablesleep", target])

        let actual = readSleepDisabled()
        let ok = (actual == disabled)

        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if ok {
            FileLogger.shared.log("disablesleep 已置为 \(target)（sudo exit=\(status)）")
        } else {
            FileLogger.shared.log("""
                ❌ disablesleep 写入失败：目标是 \(target)，回读为 \
                \(actual.map { $0 ? "1" : "0" } ?? "读不到")，sudo exit=\(status)\
                \(detail.isEmpty ? "" : "，输出：\(detail)")
                """)
        }
        return ok
    }

    @discardableResult
    func enable() -> Bool { setSleepDisabled(true) }

    @discardableResult
    func disable() -> Bool { setSleepDisabled(false) }

    /// 立即休眠。仅在已经确认可以休眠之后调用（`disablesleep=1` 时 `sleepnow` 无效）。
    @discardableResult
    func sleepNow() -> Bool {
        let (status, _) = run("/usr/bin/sudo", ["-n", "-k", "/usr/bin/pmset", "sleepnow"])
        return status == 0
    }

    /// 唤醒相关（`womp`）。**只设 1，从不设 0** —— 免得把用户自己配的值抹掉。
    @discardableResult
    func setWakeOnNetwork(_ on: Bool) -> Bool {
        guard on else { return true }   // 关闭时不动它，避免覆盖用户设置
        let (status, output) = run("/usr/bin/sudo",
                                   ["-n", "-k", "/usr/bin/pmset", "-a", "womp", "1"])
        if status == 0 {
            FileLogger.shared.log("已启用 Wake for Network Access（womp 1）")
            return true
        }
        FileLogger.shared.log("womp 写入失败：exit=\(status) \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        return false
    }

    // MARK: - 子进程

    /// 同步执行并**同时**返回退出码和输出。
    ///
    /// 与旧版 `shell()` 的差别（都是审计里查出的实际问题）：
    /// - 旧版 `try? process.run()` + 丢弃 `terminationStatus`，10 条 pmset 全失败也无感；
    /// - 旧版不设 `standardInput`，GUI 进程理论上可能挂在提示上；
    /// - 旧版先 `waitUntilExit()` 再读管道，子进程输出超过管道缓冲（64KB）会死锁。
    private func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "launch failed: \(error.localizedDescription)")
        }

        // 先读干净管道，再等待退出
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
