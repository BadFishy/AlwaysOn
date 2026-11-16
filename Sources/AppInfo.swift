import Foundation

/// 应用信息的统一来源。
enum AppInfo {
    /// 本地化后的显示名。
    ///
    /// `Bundle.object(forInfoDictionaryKey:)` 会返回 `InfoPlist.strings` 里按语言覆盖的值，
    /// 所以这里跟着 `CFBundleDisplayName` 走：简体中文是「糕咖啡」、英文是 CoffeeGuard。
    /// 注意 **bundle identifier 保持 `com.alwayson.app` 不变** —— 改它会让 macOS 认为
    /// 换了新 app，导致定位权限被回收、登录项失效、配置目录要迁移。
    static var displayName: String {
        if let localized = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !localized.isEmpty {
            return localized
        }
        return "CoffeeGuard"
    }

    /// 版本号（用于日志）
    static var version: String {
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }
}
