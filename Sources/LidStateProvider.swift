import Foundation

/// 统一的盖子状态检测器
/// 避免在多个类中重复实现 isLidClosed()
final class LidStateProvider {
    static let shared = LidStateProvider()
    
    private init() {}
    
    /// 检测盖子是否合上
    /// - Returns: true 表示盖子合上，false 表示打开或检测失败
    func isLidClosed() -> Bool {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-k", "AppleClamshellState", "-d", "4"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                print("[LidStateProvider] ioreg failed with status: \(process.terminationStatus)")
                return false
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                print("[LidStateProvider] Failed to decode ioreg output")
                return false
            }
            
            return output.contains("\"AppleClamshellState\" = Yes")
        } catch {
            print("[LidStateProvider] Failed to check lid state: \(error)")
            return false
        }
    }
    
    /// 异步检测盖子状态（用于不阻塞主线程的场景）
    func isLidClosedAsync(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.isLidClosed() ?? false
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
