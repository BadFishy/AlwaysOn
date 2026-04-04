import Foundation

/// 文件日志管理器
/// 日志存储在系统临时目录，保留最近 3 天
final class FileLogger {
    static let shared = FileLogger()
    
    private let logFileURL: URL
    private let maxAgeDays: TimeInterval = 3 * 24 * 60 * 60
    private let lock = NSLock()
    private let formatter: DateFormatter
    
    private init() {
        let tempDir = FileManager.default.temporaryDirectory
        let logDir = tempDir.appendingPathComponent("AlwaysOnLogs")
        
        // 创建日志目录
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        
        // 使用日期作为日志文件名
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        let today = formatter.string(from: Date())
        logFileURL = logDir.appendingPathComponent("\(today).log")
        
        // 清理过期日志
        cleanupOldLogs()
        
        // 写入启动标记
        log("=== AlwaysOn started at \(ISO8601DateFormatter().string(from: Date())) ===")
    }
    
    /// 写入日志
    func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logLine = "[\(timestamp)] [\(fileName):\(line)] \(function) - \(message)\n"
        
        lock.lock()
        defer { lock.unlock() }
        
        // 追加写入
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
        
        // 同时输出到 stdout（方便调试）
        Swift.print(message)
    }
    
    /// 清理超过 3 天的日志文件
    private func cleanupOldLogs() {
        let logDir = logFileURL.deletingLastPathComponent()
        let now = Date()
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return
        }
        
        for fileURL in files {
            guard fileURL.pathExtension == "log" else { continue }
            
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let creationDate = attrs[.creationDate] as? Date,
               now.timeIntervalSince(creationDate) > maxAgeDays {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
    
    /// 获取当前日志文件路径（供外部查看）
    var currentLogPath: String {
        return logFileURL.path
    }
    
    /// 获取最近 3 天的所有日志文件路径列表
    var allLogPaths: [String] {
        let logDir = logFileURL.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.path }
    }
}
