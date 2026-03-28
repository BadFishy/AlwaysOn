import Foundation

final class ConfigManager {
    static let shared = ConfigManager()
    
    private let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".alwayson")
    private let configFile: URL
    
    private var config: Config = Config()
    
    var whitelistWiFi: [String] {
        return config.whitelist_wifi
    }
    
    var checkInterval: TimeInterval {
        return TimeInterval(config.check_interval)
    }
    
    var enableWakeOnPower: Bool {
        return config.enable_wake_on_power
    }
    
    init() {
        configFile = configDirectory.appendingPathComponent("config.json")
        loadConfig()
    }
    
    func loadConfig() {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            createDefaultConfig()
            return
        }
        
        do {
            let data = try Data(contentsOf: configFile)
            let decoder = JSONDecoder()
            config = try decoder.decode(Config.self, from: data)
            print("[AlwaysOn] Config loaded: \(config.whitelist_wifi.count) WiFi(s) in whitelist")
        } catch {
            print("[AlwaysOn] Failed to load config: \(error). Using defaults.")
            config = Config()
        }
    }
    
    func isWhitelisted(_ ssid: String?) -> Bool {
        guard let ssid = ssid else { return false }
        return config.whitelist_wifi.contains(ssid)
    }
    
    func addToWhitelist(_ ssid: String) {
        if !config.whitelist_wifi.contains(ssid) {
            config.whitelist_wifi.append(ssid)
            saveConfig()
            print("[AlwaysOn] Added '\(ssid)' to whitelist")
        }
    }
    
    func removeFromWhitelist(_ ssid: String) {
        config.whitelist_wifi.removeAll { $0 == ssid }
        saveConfig()
        print("[AlwaysOn] Removed '\(ssid)' from whitelist")
    }
    
    private func createDefaultConfig() {
        config = Config()
        saveConfig()
        
        let readmeFile = configDirectory.appendingPathComponent("README.txt")
        let readmeContent = """
        AlwaysOn 配置说明
        =================
        
        编辑 config.json 添加受信任的 WiFi 网络。
        
        配置示例:
        {
          "whitelist_wifi": ["家里WiFi", "公司5G"],
          "check_interval": 60,
          "enable_wake_on_power": true
        }
        
        字段说明:
        - whitelist_wifi: 白名单 WiFi 列表
        - check_interval: 检测间隔（秒），默认 60 秒
        - enable_wake_on_power: 休眠时插入电源是否自动唤醒
        """
        
        try? readmeContent.write(to: readmeFile, atomically: true, encoding: .utf8)
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
            let data = try encoder.encode(config)
            try data.write(to: configFile)
        } catch {
            print("[AlwaysOn] Failed to save config: \(error)")
        }
    }
}

struct Config: Codable {
    var whitelist_wifi: [String]
    var check_interval: Int
    var enable_wake_on_power: Bool
    
    init() {
        self.whitelist_wifi = []
        self.check_interval = 60
        self.enable_wake_on_power = true
    }
}