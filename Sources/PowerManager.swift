import Foundation
import AppKit

final class PowerManager {
    private var caffeinateProcess: Process?
    private var caffeinatePipe: Pipe?

    var isEnabled: Bool {
        let output = shell("/usr/bin/pmset", "-g")
        let lowerOutput = output.lowercased()
        return lowerOutput.contains("sleepdisabled") && lowerOutput.contains("1")
    }

    func enable() {
        print("[AlwaysOn] Enabling sleep prevention...")
        
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1")
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

    private func startCaffeinate() {
        stopCaffeinate()
        
        shell("/usr/bin/pkill", "-f", "caffeinate.*-ims")
        usleep(100000)
        
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-ims"]
        process.standardOutput = pipe
        process.standardError = pipe
        
        process.terminationHandler = { [weak self] process in
            print("[AlwaysOn] caffeinate terminated")
            self?.caffeinateProcess = nil
        }
        
        do {
            try process.run()
            caffeinateProcess = process
            caffeinatePipe = pipe
            print("[AlwaysOn] caffeinate started with PID: \(process.processIdentifier)")
        } catch {
            print("[AlwaysOn] Failed to start caffeinate: \(error)")
        }
    }

    private func stopCaffeinate() {
        if let process = caffeinateProcess, process.isRunning {
            print("[AlwaysOn] Stopping caffeinate (PID: \(process.processIdentifier))")
            process.terminate()
            process.waitUntilExit()
            print("[AlwaysOn] caffeinate terminated")
        }
        caffeinateProcess = nil
        caffeinatePipe = nil
    }

    @discardableResult
    private func shell(_ args: String...) -> String {
        let command = args.joined(separator: " ")
        let task = Process()
        let pipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("[AlwaysOn] Shell error: \(error)")
            return ""
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}