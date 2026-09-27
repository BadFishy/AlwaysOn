import Foundation
import CoreWLAN
import CoreLocation
import OSLog

/// WiFi 状态。**关键区别**（审计修正）：
///
/// 旧版只有 `currentSSID: String?`，于是"没连 WiFi"和"读不到 SSID"无法区分，而
/// `isWhitelisted(nil)` 返回 false → 两者都被当成"不在白名单" → 直接 `disable()`，
/// 也就是**主动放开休眠**。而 `interface.ssid()` 返回 nil 的原因大多与"用户是否在
/// 白名单网络上"无关：未授予定位权限（macOS 10.15+ 必需）、漫游/唤醒瞬间读不到、
/// WiFi 关闭、走网线……
///
/// 2026-09-08 09:32 那次事故就是"掉电"和"SSID 瞬时读不到"撞在同一个 tick 里触发的。
enum SSIDState {
    case connected(String)
    case notConnected
    /// 读不到（未授权 / 瞬时失败）。**不应据此放开休眠。**
    case unavailable(String)

    var description: String {
        switch self {
        case .connected(let ssid): return "已连接(\(ssid))"
        case .notConnected: return "未连接"
        case .unavailable(let why): return "读不到(\(why))"
        }
    }
}

/// WiFi 检测管理器
final class WiFiMonitor: NSObject, CLLocationManagerDelegate {
    private var client: CWWiFiClient?
    private var locationManager: CLLocationManager?

    private var lastKnownSSID: String?
    private var lastKnownSSIDTime: Date = .distantPast
    /// 刚读到时给一段宽限期：这段时间内的 nil 视为"瞬时丢失"而不是"已断开"
    private let gracePeriod: TimeInterval = 10.0

    private let logger = Logger(subsystem: "com.alwayson.app", category: "WiFiMonitor")

    /// 权限状态回调
    var onPermissionStatusChanged: ((Bool) -> Void)?

    /// 权限授予回调（简化版，仅在授权成功时触发）
    var onPermissionGranted: (() -> Void)?

    // MARK: - 状态读取

    /// 三态 WiFi 状态。直接调用 CoreWLAN（本地 API，不阻塞网络）。
    var ssidState: SSIDState {
        guard let interface = client?.interface() else {
            logger.warning("CoreWLAN: 无 WiFi 接口")
            return .unavailable("无 WiFi 接口")
        }

        guard interface.powerOn() else {
            // WiFi 明确关着 = 明确没有连接
            lastKnownSSID = nil
            return .notConnected
        }

        // 没有定位权限时 ssid() 必然返回 nil，这不是"没连 WiFi"
        guard hasLocationPermission else {
            logger.debug("CoreWLAN: 未授予定位权限，无法读取 SSID")
            return .unavailable("未授予定位权限")
        }

        if let ssid = interface.ssid(), !ssid.isEmpty {
            lastKnownSSID = ssid
            lastKnownSSIDTime = Date()
            logger.info("CoreWLAN got SSID: \(ssid)")
            return .connected(ssid)
        }

        // ssid() 为 nil：若刚刚还读到过，视为漫游/唤醒瞬间的瞬时丢失
        if let previous = lastKnownSSID,
           Date().timeIntervalSince(lastKnownSSIDTime) < gracePeriod {
            logger.debug("CoreWLAN: SSID 瞬时读不到，沿用 \(previous)")
            return .unavailable("瞬时丢失")
        }

        lastKnownSSID = nil
        return .notConnected
    }

    /// 兼容旧接口：仅用于菜单显示。
    var currentSSID: String? {
        if case .connected(let ssid) = ssidState { return ssid }
        return nil
    }


    /// 清除缓存（菜单打开时强制刷新）
    func forceRefresh() {
        lastKnownSSID = nil
        lastKnownSSIDTime = .distantPast
    }

    // MARK: - 权限

    private var hasLocationPermission: Bool {
        switch locationManager?.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    /// 请求位置权限（首次使用时调用）
    func requestPermissionIfNeeded() {
        guard let locationManager = locationManager else { return }
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            logger.info("正在请求定位权限（读取 WiFi SSID 需要）")
            locationManager.requestWhenInUseAuthorization()
        }
    }

    override init() {
        super.init()
        client = CWWiFiClient.shared()
        locationManager = CLLocationManager()
        locationManager?.delegate = self
        logger.info("WiFiMonitor initialized")
    }

    // MARK: - CLLocationManagerDelegate

    /// macOS 11+ 的新回调（旧版 `didChangeAuthorization status:` 已废弃）
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        logger.info("定位授权状态变化: \(String(describing: status))")

        let granted: Bool
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: granted = true
        default: granted = false
        }

        // 授权状态还在"未决定"时不算结果，等待用户选择
        guard status != .notDetermined else { return }

        onPermissionStatusChanged?(granted)
        if granted { onPermissionGranted?() }
    }
}

