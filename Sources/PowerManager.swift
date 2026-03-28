import Foundation

final class PowerManager {
    private var caffeinateProcess: Process?

    var isEnabled: Bool {
        let output = shell("/usr/bin/pmset", "-g")
        return output.contains("SleepDisabled\t\t1") || output.contains("SleepDisabled        1")
    }

    func enable() {
        print("[CoffeeGuard] Enabling sleep prevention...")
        
        // Prevent sleep (including lid close) - use -a for all power sources
        // 确保在电池和电源适配器模式下都禁用休眠
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1")
        
        // Prevent disk sleep
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "0")
        
        // Keep network alive when display sleeps
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "networkoversleep", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "tcpkeepalive", "1")
        
        // Set display sleep times (display can sleep, but system won't)
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "displaysleep", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-c", "displaysleep", "5")
        
        // 额外：确保电池模式下也禁用系统休眠（某些Mac需要单独设置）
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "sleep", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-c", "sleep", "0")

        startCaffeinate()
        
        // 验证设置是否生效
        let verifyOutput = shell("/usr/bin/pmset", "-g")
        print("[CoffeeGuard] pmset status: \(verifyOutput.contains("SleepDisabled\t\t1") || verifyOutput.contains("SleepDisabled        1") ? "enabled" : "warning - may not be enabled")")
    }

    func disable() {
        print("[CoffeeGuard] Disabling sleep prevention...")
        
        stopCaffeinate()

        // Restore defaults using -a so it works on both laptops and desktops
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "10")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "networkoversleep", "0")
        
        // Restore sleep settings for battery and charger
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "sleep", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-c", "sleep", "0")  // 插电时默认不休眠
        
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "displaysleep", "2")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-c", "displaysleep", "5")
        
        print("[CoffeeGuard] Sleep prevention disabled")
    }

    func sleepNow() {
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "sleepnow")
    }
    
    /// 启用 Wake-on-Power（插入电源时唤醒休眠的系统）
    func enableWakeOnPower() {
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "womp", "1")
        print("[CoffeeGuard] Wake-on-Power enabled")
    }
    
    /// 禁用 Wake-on-Power
    func disableWakeOnPower() {
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "womp", "0")
    }

    private func startCaffeinate() {
        stopCaffeinate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-ims"]
        try? process.run()
        caffeinateProcess = process
    }

    private func stopCaffeinate() {
        if let process = caffeinateProcess, process.isRunning {
            process.terminate()
            caffeinateProcess = nil
        }
    }

    @discardableResult
    private func shell(_ args: String...) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
