import Foundation
import AppKit

final class PowerManager {
    private var caffeinateProcess: Process?

    var isEnabled: Bool {
        let output = shell("/usr/bin/pmset", "-g")
        return output.contains("SleepDisabled\t\t1") || output.contains("SleepDisabled        1")
    }

    func enable() {
        FileLogger.shared.log("Enabling sleep prevention...")
        
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "standby", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "autopoweroff", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "networkoversleep", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "tcpkeepalive", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "displaysleep", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-c", "displaysleep", "5")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "sleep", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-c", "sleep", "0")

        startCaffeinate()
        
        if isEnabled {
            FileLogger.shared.log("Sleep prevention enabled successfully")
        } else {
            FileLogger.shared.log("Warning: Sleep prevention may not be enabled")
        }
    }

    func disable() {
        FileLogger.shared.log("Disabling sleep prevention...")
        
        stopCaffeinate()

        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "standby", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "autopoweroff", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "10")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "networkoversleep", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "sleep", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-c", "sleep", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "displaysleep", "2")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-c", "displaysleep", "5")
        
        FileLogger.shared.log("Sleep prevention disabled")
    }

    func sleepNow() {
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "sleepnow")
    }
    
    func enableWakeOnPower() {
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "womp", "1")
        FileLogger.shared.log("Wake-on-Power enabled")
    }
    
    func disableWakeOnPower() {
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "womp", "0")
    }

    // MARK: - Caffeinate

    /// macOS 可能在电源切换、display sleep 等事件时重置 pmset disablesleep，
    /// 导致 app 认为防休眠已启用但实际已失效。此方法检测并修复这种不一致。
    func ensureEnabled() {
        var reapplied = false
        
        if !isEnabled {
            FileLogger.shared.log("⚠️ disablesleep 被外部重置！正在重新应用...")
            shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1")
            shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "standby", "0")
            shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "autopoweroff", "0")
            shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "0")
            shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "sleep", "0")
            shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-c", "sleep", "0")
            reapplied = true
            
            if isEnabled {
                FileLogger.shared.log("✅ disablesleep 重新应用成功")
            } else {
                FileLogger.shared.log("❌ disablesleep 重新应用失败！")
            }
        }
        
        if caffeinateProcess == nil || !caffeinateProcess!.isRunning {
            FileLogger.shared.log("⚠️ caffeinate 进程已死亡，正在重启...")
            startCaffeinate()
            reapplied = true
        }
        
        if !reapplied {
            FileLogger.shared.log("✓ 防休眠状态正常（disablesleep=1, caffeinate 运行中）")
        }
    }
    
    var isCaffeinateRunning: Bool {
        return caffeinateProcess?.isRunning ?? false
    }

    private func startCaffeinate() {
        stopCaffeinate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-ims"]
        try? process.run()
        caffeinateProcess = process
        FileLogger.shared.log("caffeinate 进程已启动 (PID: \(process.processIdentifier))")
    }

    private func stopCaffeinate() {
        if let process = caffeinateProcess, process.isRunning {
            process.terminate()
            FileLogger.shared.log("caffeinate 进程已停止 (PID: \(process.processIdentifier))")
            caffeinateProcess = nil
        }
    }

    // MARK: - Shell

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
