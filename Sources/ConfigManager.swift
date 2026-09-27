import Foundation

/// 配置管理器 - 线程安全版本
///
/// 审计修正：旧版用 `try decoder.decode(Config.self, from: data)` 配合**全部必填**的字段，
/// 于是配置文件里只要缺一个键（版本升级新增字段、用户手改删了一行、字段类型写错），
/// 解码就抛错 → `catch` 分支把配置整体替换成 `Config()` 默认值 →
/// **白名单被静默清空** → 电池模式下 `isWhitelisted` 恒为 false → 机器在你没让它睡的时候睡。
/// 现在 `init(from:)` 对每个字段单独容错，缺字段只影响该字段。
final class ConfigManager {
    static let shared = ConfigManager()

    // MARK: - 线程安全锁
    private let lock = NSLock()

    // MARK: - 配置存储（必须通过锁访问）
    private var _config: Config = Config()
    private var config: Config {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }

    // MARK: - 文件路径
    private let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".alwayson")
    private let configFile: URL

    // MARK: - 公开属性（线程安全）

    var whitelistWiFi: [String] {
        return lock.withLock { _config.whitelist_wifi }
    }

    /// 条件检测间隔。真正的防休眠保障是 1 秒守护循环 + 系统电源事件，
    /// 这个间隔只决定"条件变化后多久兜底复核一次"。
    var checkInterval: TimeInterval {
        let interval = lock.withLock { _config.check_interval }
        return TimeInterval(max(5, min(interval, 300)))
    }

    /// 校验 `disablesleep` 是否被外部清零的守护循环间隔（秒）。
    var guardInterval: TimeInterval {
        let interval = lock.withLock { _config.guard_interval }
        guard interval.isFinite else { return 1.0 }
        return TimeInterval(max(0.5, min(interval, 10.0)))
    }

    /// 电池电量下限（%）。低于此值且在用电池时强制放开休眠；0 = 关闭该保护。
    var batteryFloor: Int {
        let floor = lock.withLock { _config.battery_floor }
        return max(0, min(floor, 90))
    }

    var enableWakeOnPower: Bool {
        return lock.withLock { _config.enable_wake_on_power }
    }

    /// 手动开关：是否启用阻止休眠功能
    var enabled: Bool {
        return lock.withLock { _config.enabled }
    }

    /// AC 模式："always"（插电即不休眠）或 "wifi_required"（插电+WiFi）
    var acMode: String {
        return lock.withLock { _config.ac_mode }
    }

    /// 电池模式："whitelist"（仅白名单WiFi）或 "any_wifi"（有WiFi即可）
    var batteryMode: String {
        return lock.withLock { _config.battery_mode }
    }

    // MARK: - 初始化

    private init() {
        configFile = configDirectory.appendingPathComponent("config.json")
        loadConfig()
    }

    // MARK: - 配置加载

    func loadConfig() {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            createDefaultConfig()
            return
        }

        do {
            let data = try Data(contentsOf: configFile)
            var validated = try JSONDecoder().decode(Config.self, from: data)

            // 逐字段校验（解码已经容错，这里只做取值域收敛）
            validated.check_interval = max(5, min(validated.check_interval, 300))
            validated.battery_floor = max(0, min(validated.battery_floor, 90))
            if !validated.guard_interval.isFinite {
                validated.guard_interval = 1.0
            }
            validated.guard_interval = max(0.5, min(validated.guard_interval, 10.0))
            if !["always", "wifi_required"].contains(validated.ac_mode) {
                validated.ac_mode = "always"
            }
            if !["whitelist", "any_wifi"].contains(validated.battery_mode) {
                validated.battery_mode = "whitelist"
            }
            validated.whitelist_wifi = validated.whitelist_wifi
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            lock.withLock { _config = validated }

            FileLogger.shared.log("""
                Config loaded: \(whitelistWiFi.count) WiFi(s) in whitelist, enabled=\(enabled), \
                ac_mode=\(acMode), battery_mode=\(batteryMode), \
                guard=\(guardInterval)s, battery_floor=\(batteryFloor)%
                """)
        } catch {
            // 只有在文件真的读不出来/不是合法 JSON 时才回退默认值，
            // 并且**明确告警**（旧版这里是静默的，白名单会无声消失）。
            FileLogger.shared.log("❌ Failed to load config: \(error). 保留内存中的现有配置，不回退默认值。")
        }
    }

    // MARK: - 白名单操作（线程安全）

    func isWhitelisted(_ ssid: String?) -> Bool {
        guard let ssid = ssid, !ssid.isEmpty else { return false }
        return lock.withLock { _config.whitelist_wifi.contains(ssid) }
    }

    @discardableResult
    func addToWhitelist(_ ssid: String) -> Bool {
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty else { return false }

        lock.lock()
        guard !_config.whitelist_wifi.contains(trimmedSSID) else {
            lock.unlock()
            return false
        }
        _config.whitelist_wifi.append(trimmedSSID)
        lock.unlock()

        saveConfig()
        FileLogger.shared.log("Added '\(trimmedSSID)' to whitelist")
        return true
    }

    func removeFromWhitelist(_ ssid: String) {
        lock.lock()
        _config.whitelist_wifi.removeAll { $0 == ssid }
        lock.unlock()

        saveConfig()
        FileLogger.shared.log("Removed '\(ssid)' from whitelist")
    }

    // MARK: - 设置操作

    func setEnabled(_ value: Bool) {
        lock.lock()
        _config.enabled = value
        lock.unlock()

        saveConfig()
        FileLogger.shared.log("Enabled set to \(value)")
    }

    func setAcMode(_ mode: String) {
        guard ["always", "wifi_required"].contains(mode) else { return }

        lock.lock()
        _config.ac_mode = mode
        lock.unlock()

        saveConfig()
        FileLogger.shared.log("AC mode set to \(mode)")
    }

    func setBatteryMode(_ mode: String) {
        guard ["whitelist", "any_wifi"].contains(mode) else { return }

        lock.lock()
        _config.battery_mode = mode
        lock.unlock()

        saveConfig()
        FileLogger.shared.log("Battery mode set to \(mode)")
    }

    // MARK: - 配置持久化

    private func createDefaultConfig() {
        lock.withLock { _config = Config() }
        saveConfig()
    }

    func saveConfig() {
        do {
            try FileManager.default.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            lock.lock()
            let data = try encoder.encode(_config)
            lock.unlock()

            try data.write(to: configFile)
        } catch {
            FileLogger.shared.log("Failed to save config: \(error)")
        }
    }
}

// MARK: - NSLock 扩展

extension NSLock {
    func withLock<T>(_ block: () -> T) -> T {
        lock()
        defer { unlock() }
        return block()
    }
}

// MARK: - 数据模型

struct Config: Codable {
    var whitelist_wifi: [String]
    var check_interval: Int
    var enable_wake_on_power: Bool
    var enabled: Bool
    var ac_mode: String
    var battery_mode: String
    /// 电池电量下限（%）：低于此值且在用电池时强制放开休眠。0 = 关闭。
    var battery_floor: Int
    /// 守护循环间隔（秒）：校验 `disablesleep` 是否被外部清零。
    var guard_interval: Double

    init() {
        self.whitelist_wifi = []
        self.check_interval = 60
        self.enable_wake_on_power = true
        self.enabled = true
        self.ac_mode = "always"
        self.battery_mode = "whitelist"
        self.battery_floor = 5
        self.guard_interval = 1.0
    }

    /// 逐字段容错解码：缺字段/类型不符只影响该字段，不会让整份配置失效。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        whitelist_wifi = (try? container.decode([String].self, forKey: .whitelist_wifi))
            ?? defaults.whitelist_wifi
        check_interval = (try? container.decode(Int.self, forKey: .check_interval))
            ?? defaults.check_interval
        enable_wake_on_power = (try? container.decode(Bool.self, forKey: .enable_wake_on_power))
            ?? defaults.enable_wake_on_power
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? defaults.enabled
        ac_mode = (try? container.decode(String.self, forKey: .ac_mode)) ?? defaults.ac_mode
        battery_mode = (try? container.decode(String.self, forKey: .battery_mode))
            ?? defaults.battery_mode
        battery_floor = (try? container.decode(Int.self, forKey: .battery_floor))
            ?? defaults.battery_floor
        guard_interval = (try? container.decode(Double.self, forKey: .guard_interval))
            ?? defaults.guard_interval
    }
}
