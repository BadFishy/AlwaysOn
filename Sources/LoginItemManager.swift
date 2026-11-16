import Foundation
import ServiceManagement

/// 开机自启管理。
///
/// 除了注册/注销，这里还负责**自愈**：`SMAppService` 的注册记录带的是 app 的路径，
/// 一旦 app 被移动或改名（例如 `AlwaysOn.app` → `糕咖啡.app`），旧记录就会指向一个
/// 不存在的路径 —— 表现就是"菜单里还勾着开机自启，但重启后根本没启动"。
/// 所以把用户的意愿单独持久化，启动时对账并修复。
final class LoginItemManager {
    private let launchAgentLabel = "com.alwayson.app"
    /// 用户意愿（与系统实际状态分开存，便于对账）
    private let wantedKey = "launchAtLoginWanted"
    /// 一次性迁移标记：bundle 改名后需要把登录项重新注册到新路径
    private let pathMigrationKey = "loginItemPathMigrationDone"

    private var launchAgentPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return FileManager.default.fileExists(atPath: launchAgentPath)
        }
    }

    /// 启动时调用：① 首次运行把系统现状记为"用户意愿"；② app 路径变了就重新注册；
    /// ③ 意愿是开但实际掉了，也重新注册。
    func healOnLaunch() {
        let defaults = UserDefaults.standard

        // ① 首次运行（或从旧版本升级）：以系统当前状态作为用户意愿的基线
        if defaults.object(forKey: wantedKey) == nil {
            let current = isEnabled
            defaults.set(current, forKey: wantedKey)
            FileLogger.shared.log("登录项：建立意愿基线 = \(current)")
        }

        let wanted = defaults.bool(forKey: wantedKey)

        // ② app 被移动/改名后，BTM 里可能留着旧路径 —— 强制重新注册一次
        if defaults.object(forKey: pathMigrationKey) == nil {
            defaults.set(true, forKey: pathMigrationKey)
            guard wanted else { return }
            FileLogger.shared.log("登录项：app 路径可能已变化，重新注册到 \(Bundle.main.bundlePath)")
            setEnabled(false)
            setEnabled(true)
            return
        }

        // ③ 意愿是开但实际没生效
        if wanted && !isEnabled {
            FileLogger.shared.log("登录项：期望开机自启但当前未生效，正在重新注册")
            setEnabled(true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: wantedKey)

        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return
            } catch {
                // Fallback to LaunchAgent
                FileLogger.shared.log("SMAppService 失败（\(error.localizedDescription)），回退到 LaunchAgent")
            }
        }

        if enabled {
            installLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    private func installLaunchAgent() {
        let appPath = Bundle.main.bundlePath
        // 用真实的可执行文件名，不要写死 —— 改 bundle 名后这里必须跟着变
        let executable = Bundle.main.executableURL?.path ?? "\(appPath)/Contents/MacOS/AlwaysOn"
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        let dir = (launchAgentPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        FileManager.default.createFile(atPath: launchAgentPath, contents: data)
    }

    private func removeLaunchAgent() {
        try? FileManager.default.removeItem(atPath: launchAgentPath)
    }
}
