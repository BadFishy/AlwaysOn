import Foundation

/// 配置管理器 - 线程安全版本
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
    
    var checkInterval: TimeInterval {
        let interval = lock.withLock { _config.check_interval }
        return TimeInterval(max(1, min(interval, 300)))
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
            let decoder = JSONDecoder()
            let loadedConfig = try decoder.decode(Config.self, from: data)
            
            // 验证配置值
            var validatedConfig = loadedConfig
            validatedConfig.check_interval = max(1, min(loadedConfig.check_interval, 300))
            
            // 验证 ac_mode 和 battery_mode 的值
            if !["always", "wifi_required"].contains(validatedConfig.ac_mode) {
                validatedConfig.ac_mode = "always"
            }
            if !["whitelist", "any_wifi"].contains(validatedConfig.battery_mode) {
                validatedConfig.battery_mode = "whitelist"
            }
            
            lock.withLock {
                _config = validatedConfig
            }
            
            FileLogger.shared.log("Config loaded: \(whitelistWiFi.count) WiFi(s) in whitelist, enabled=\(enabled), ac_mode=\(acMode), battery_mode=\(batteryMode)")
        } catch {
            FileLogger.shared.log("Failed to load config: \(error). Using defaults.")
            lock.withLock {
                _config = Config()
            }
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
        lock.withLock {
            _config = Config()
        }
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
    
    init() {
        self.whitelist_wifi = []
        self.check_interval = 60
        self.enable_wake_on_power = true
        self.enabled = true
        self.ac_mode = "always"
        self.battery_mode = "whitelist"
    }
}
