import Foundation
import AppKit

/// 特权配置。
///
/// 审计修正（安全 + 休眠风险）：
///
/// 旧规则是 `%admin ALL=(ALL) NOPASSWD: /usr/bin/pmset`（实测文件 42 字节，与源码字符串
/// 逐字节吻合）。sudoers 的语义是「**不带参数的命令行匹配任意参数**」，所以这条规则等于
/// 给**所有管理员**开了「免密执行任意 `pmset`」——包括 `pmset sleepnow`（立刻休眠）、
/// `pmset -a sleep 1`（改成 1 分钟就睡）、`pmset restoredefaults`（抹掉全部电源设置）。
///
/// 正确做法（同行 `Sleepless` / `LidAwake` / `mac-clamshell-toggle` 都这么做）：
/// 精确到参数的收窄规则 + `visudo -c` 校验 + 原子安装并设对属主权限。
///
/// 注意一个**必须同时列两条**的陷阱：`disablesleep 1` 和 `disablesleep 0` 都要写进规则，
/// 否则"恢复休眠"这条路径会变成需要密码，在无人值守时把标志永久卡在 1。
final class PrivilegeManager {

    /// 收窄后的规则文件（名字里不能有 `.`，也不能以 `~` 结尾，否则 sudo 会静默忽略）
    static let scopedRulePath = "/etc/sudoers.d/alwayson-pmset"
    /// 旧版过宽规则
    static let legacyRulePath = "/etc/sudoers.d/pmset"
    /// 旧规则的备份名。**含 `.` → sudo 会静默跳过**（`man 5 sudoers`：
    /// "skipping file names that end in '~' or contain a '.' character"），
    /// 所以改名就等于即刻停用，但文件仍在，回滚只是一次 `mv`。
    static let legacyBackupPath = "/etc/sudoers.d/pmset.disabled"

    private static let pmset = "/usr/bin/pmset"

    /// 精确放行的命令（与 PowerManager 实际调用的 argv 完全一致）
    static var allowedCommands: [String] {
        return [
            "\(pmset) -a disablesleep 0",
            "\(pmset) -a disablesleep 1",
            "\(pmset) -a womp 0",
            "\(pmset) -a womp 1",
            "\(pmset) sleepnow",
        ]
    }

    /// 完整规则行（单行、逗号分隔）
    static var scopedRuleLine: String {
        let user = NSUserName()
        return "\(user) ALL=(root) NOPASSWD: " + allowedCommands.joined(separator: ", ")
    }

    // MARK: - 探测

    /// 收窄授权是否生效：写一次**当前值**（无副作用），成功即说明清单里的命令被放行。
    static func hasScopedGrant() -> Bool {
        let current = PowerManager.registryFlag() ?? false
        let target = current ? "1" : "0"
        let (status, _) = run("/usr/bin/sudo",
                              ["-n", "-k", pmset, "-a", "disablesleep", target])
        return status == 0
    }

    /// 授权是否过宽：能否免密执行一个**不在**收窄清单里的命令。
    ///
    /// 用 `pmset -g` 做探针：收窄规则下 sudo 会拒绝（`-n` 直接失败），
    /// 旧版宽规则下会返回 0。只读命令，安全。
    ///
    /// 注：`sudo -n -l <cmd>` **不能**用来判断——实测它对未授权的命令也照样输出且退出码为 0。
    static func hasOverbroadGrant() -> Bool {
        let (status, _) = run("/usr/bin/sudo", ["-n", "-k", pmset, "-g"])
        return status == 0
    }

    /// 人类可读的当前状态，用于日志/弹窗
    static func describeState() -> String {
        let scoped = hasScopedGrant()
        let overbroad = hasOverbroadGrant()
        if overbroad { return "授权过宽（任意参数均可免密执行 pmset）" }
        if scoped { return "授权正常（已收窄到 \(allowedCommands.count) 条命令）" }
        return "未授权"
    }

    // MARK: - 安装

    /// 在主线程弹窗确认 → 后台用 osascript 提权安装 → 主线程回调。
    ///
    /// 首次运行（完全没有授权）与"旧版遗留过宽授权"共用这个流程，只是文案不同；
    /// 两种情况下都**不会**因为用户点"取消"而退出应用 —— 应用继续以降级模式运行，
    /// UI 会显示「防休眠未生效」，菜单里也留着入口随时可以再来一次。
    static func requestSetup(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let overbroad = hasOverbroadGrant()
            let commands = allowedCommands.map { "  • \($0)" }.joined(separator: "\n")
            let count = String(allowedCommands.count)

            let alert = NSAlert()
            alert.messageText = overbroad
                ? NSLocalizedString("grant_alert_title_overbroad", comment: "")
                : NSLocalizedString("grant_alert_title_firstrun", comment: "")
            alert.informativeText = overbroad
                ? String(format: NSLocalizedString("grant_alert_body_overbroad", comment: ""), count, commands)
                : String(format: NSLocalizedString("grant_alert_body_firstrun", comment: ""), count, commands)
            alert.alertStyle = overbroad ? .critical : .informational
            alert.addButton(withTitle: NSLocalizedString("grant_alert_confirm", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("grant_alert_cancel", comment: ""))

            guard alert.runModal() == .alertFirstButtonReturn else {
                FileLogger.shared.log("用户取消了授权配置，应用继续以降级模式运行")
                completion(false)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let ok = installScopedRule()
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    /// 通过 osascript 提权安装收窄规则 —— **自带功能自检，失败自动回滚**。
    ///
    /// 用户最担心的是「收窄之后 App 反而写不了标志 → 机器又睡回去」。所以这里的顺序是：
    ///
    /// 1. 临时文件 → 设权限属主 → `visudo -c` **语法校验**（坏规则绝不进
    ///    `/etc/sudoers.d/`，那会让 sudo 整机拒绝工作）；
    /// 2. `install` 原子落盘新规则；
    /// 3. 把旧宽规则**改名**成 `pmset.disabled`。`man 5 sudoers` 明确：sudo 会
    ///    *"skipping file names that end in '~' or contain a '.' character"*，
    ///    所以改名即刻停用，但文件还在，回滚只是一次 `mv`；
    /// 4. **在同一个 root 会话里以用户身份实测**（`su - <user> -c 'sudo -n …'`）：
    ///    只有回到用户身份，sudo 才会真正走 sudoers 策略（root 自己 sudo 恒放行，测不出来）。
    ///    - `pmset -a disablesleep 1` 必须**成功**（App 保活的关键路径）
    ///    - `pmset -a womp 1` 必须**成功**（幂等，无副作用）
    ///    - `pmset -g` 必须**失败**（证明收窄确实生效了）
    ///    - **故意不测 `sleepnow`**（会把机器弄睡）和 `disablesleep 0`（会临时放开保护）；
    ///      后者与 `disablesleep 1` 结构完全相同，前者能过则它也能过。
    /// 5. 自检通过 → 删除备份；**自检失败 → 立刻恢复旧规则并返回非 0**，
    ///    整件事只花一次密码，绝不会把机器留在"写不了标志"的状态。
    /// 实际下发给 root 的 shell 脚本。抽成属性是为了能离线做 `sh -n` 语法预检 ——
    /// 免得用户输完密码才发现脚本本身有语法错。
    static var scopedInstallScript: String {
        let user = NSUserName()
        let pmset = PrivilegeManager.pmset
        return """
            T=$(mktemp /tmp/alwayson-sudoers.XXXXXX) || exit 2; \
            printf '%s\\n' '\(scopedRuleLine)' > "$T" \
            && chmod 0440 "$T" && chown root:wheel "$T" \
            && /usr/sbin/visudo -c -f "$T" || { rm -f "$T"; echo 'visudo 校验失败' >&2; exit 3; }; \
            /usr/bin/install -m 0440 -o root -g wheel "$T" \(scopedRulePath) \
            || { rm -f "$T"; echo 'install 失败' >&2; exit 4; }; \
            rm -f "$T"; \
            if [ -f \(legacyRulePath) ]; then \
              echo 'LEGACY-CONTENT:'; cat \(legacyRulePath); \
              rm -f \(legacyBackupPath); mv \(legacyRulePath) \(legacyBackupPath); \
            fi; \
            if su - '\(user)' -c '/usr/bin/sudo -n -k \(pmset) -a disablesleep 1' >/dev/null 2>&1 \
               && su - '\(user)' -c '/usr/bin/sudo -n -k \(pmset) -a womp 1' >/dev/null 2>&1 \
               && ! su - '\(user)' -c '/usr/bin/sudo -n -k \(pmset) -g' >/dev/null 2>&1; then \
              echo 'SELFTEST-OK'; rm -f \(legacyBackupPath); \
            else \
              echo 'SELFTEST-FAILED：收窄后 App 的关键命令未通过，正在回滚' >&2; \
              rm -f \(scopedRulePath); \
              if [ -f \(legacyBackupPath) ]; then mv \(legacyBackupPath) \(legacyRulePath); fi; \
              exit 9; \
            fi
            """
    }

    private static func installScopedRule() -> Bool {
        let script = scopedInstallScript

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escapeForAppleScript(script))\" with administrator privileges"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            FileLogger.shared.log("提权失败：无法启动 osascript：\(error)")
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for line in output.split(separator: "\n") {
            FileLogger.shared.log("提权输出: \(line)")
        }

        guard process.terminationStatus == 0 else {
            FileLogger.shared.log("""
                ❌ 收窄失败（exit=\(process.terminationStatus)），已自动回滚到原规则，\
                App 功能不受影响
                """)
            return false
        }

        FileLogger.shared.log("✅ 已安装收窄授权并通过自检：\(scopedRuleLine)")
        return true
    }

    /// AppleScript 字符串里只需转义反斜杠和双引号。
    private static func escapeForAppleScript(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - 子进程

    private static func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "launch failed: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
