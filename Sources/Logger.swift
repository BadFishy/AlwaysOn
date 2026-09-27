import Foundation

/// 文件日志管理器。
///
/// 审计修正：
/// - 旧版把日志文件名在 `init()` 里算一次就**固定**了。进程连续运行 17.7 天，全部日志
///   写进启动那天的 `2026-08-28.log`，实测长到 **10.7 MB 且没有上限**，`cleanupOldLogs()`
///   也只在启动时执行一次。
/// - 旧版写在 `FileManager.default.temporaryDirectory`（`$TMPDIR`），系统会清理，
///   用户也很难找到。现改到 `~/.alwayson/logs/`，与配置文件同处一个目录（菜单里有
///   "打开配置文件夹"）。
final class FileLogger {
    static let shared = FileLogger()

    private let logDirectory: URL
    private let maxAgeDays: TimeInterval = 7 * 24 * 60 * 60
    /// 单个文件上限；超过就轮转成 `<date>.1.log`
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private let lock = NSLock()
    private let dayFormatter: DateFormatter

    private init() {
        let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alwayson")
        logDirectory = supportDirectory.appendingPathComponent("logs")

        try? FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true)

        dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        cleanupOldLogs()
        log("=== AlwaysOn started at \(ISO8601DateFormatter().string(from: Date())) ===")
    }

    /// 写入日志
    func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logLine = "[\(timestamp)] [\(fileName):\(line)] \(function) - \(message)\n"
        guard let data = logLine.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        let url = logFileURL(for: Date())
        rotateIfNeeded(url)

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }
    }

    /// 当天日志文件路径。**每次写入时重新计算**，进程跨天也不会写错文件。
    private func logFileURL(for date: Date) -> URL {
        return logDirectory.appendingPathComponent("\(dayFormatter.string(from: date)).log")
    }

    /// 单文件超过上限就改名成 `<date>.1.log`（覆盖上一份），保证占用有界。
    private func rotateIfNeeded(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              size >= maxBytes
        else { return }

        let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }

    /// 清理超过保留期的日志文件
    private func cleanupOldLogs() {
        let now = Date()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }

        for fileURL in files {
            guard fileURL.pathExtension == "log" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            if now.timeIntervalSince(modified) > maxAgeDays {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}
