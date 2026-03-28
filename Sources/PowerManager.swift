import Foundation
import AppKit

final class PowerManager {
    private var caffeinateProcess: Process?

    var isEnabled: Bool {
        let output = shell("/usr/bin/pmset", "-g")
        return output.contains("SleepDisabled\t\t1") || output.contains("SleepDisabled        1")
    }

    func enable() {
        print("[AlwaysOn] Enabling sleep prevention...")
        
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
            print("[AlwaysOn] Sleep prevention enabled successfully")
        } else {
            print("[AlwaysOn] Warning: Sleep prevention may not be enabled")
        }
    }

    func disable() {
        print("[AlwaysOn] Disabling sleep prevention...")
        
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
        
        print("[AlwaysOn] Sleep prevention disabled")
    }

    func sleepNow() {
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "sleepnow")
    }
    
    func enableWakeOnPower() {
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "womp", "1")
        print("[AlwaysOn] Wake-on-Power enabled")
    }
    
    func disableWakeOnPower() {
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "womp", "0")
    }

    // MARK: - Caffeinate

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
