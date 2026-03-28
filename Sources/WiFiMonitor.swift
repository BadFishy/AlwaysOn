import Foundation
import CoreWLAN
import CoreLocation
import OSLog

/// WiFi 检测管理器
/// 使用 CoreWLAN + CoreLocation 获取 WiFi SSID
final class WiFiMonitor: NSObject, CLLocationManagerDelegate {
    private var client: CWWiFiClient?
    private var locationManager: CLLocationManager?
    
    private var lastKnownSSID: String?
    private var lastCheckTime: Date = .distantPast
    private let cacheTimeout: TimeInterval = 3.0
    private let logger = Logger(subsystem: "com.alwayson.app", category: "WiFiMonitor")
    
    /// 位置权限已请求（防止重复请求）
    private var locationPermissionRequested = false
    
    /// 最后一次错误，用于外部检测错误
    var lastError: Error?
    
    /// 权限状态变化回调
    var onPermissionGranted: (() -> Void)?
    
    /// 获取当前 WiFi SSID
    /// 需要 Location Services 权限才能获取 SSID
    var currentSSID: String? {
        let now = Date()
        
        // 检查缓存
        if now.timeIntervalSince(lastCheckTime) < cacheTimeout, let cached = lastKnownSSID {
            logger.info("✅ 使用缓存获取到 SSID: \(cached)")
            return cached
        }
        
        // 检查 Location 权限
        guard let locationManager = locationManager else {
            return nil
        }
        
        let status = locationManager.authorizationStatus
        
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            break // 权限已授予，继续获取 SSID
            
        case .notDetermined:
            // 非阻塞：请求权限，不等待结果
            if !locationPermissionRequested {
                locationPermissionRequested = true
                logger.info("Location 权限未确定，开始请求...")
                locationManager.requestWhenInUseAuthorization()
            }
            return nil
            
        case .denied, .restricted:
            logger.warning("⚠️ 没有 Location 权限，无法获取 WiFi SSID")
            lastError = WiFiMonitorError.locationPermissionDenied
            return nil
            
        @unknown default:
            return nil
        }
        
        // 使用 CoreWLAN 获取 SSID
        guard let interface = client?.interface() else {
            logger.warning("CoreWLAN: 无法获取 WiFi 接口")
            lastError = WiFiMonitorError.interfaceNotAvailable
            return nil
        }
        
        // 检查 WiFi 是否开启
        guard interface.powerOn() else {
            logger.warning("CoreWLAN: WiFi 电源关闭")
            lastError = WiFiMonitorError.wifiPoweredOff
            return nil
        }
        
        // 获取 SSID
        if let ssid = interface.ssid() {
            lastKnownSSID = ssid
            lastCheckTime = now
            lastError = nil
            logger.info("✅ CoreWLAN 成功获取到 SSID: \(ssid)")
            return ssid
        } else {
            logger.warning("⚠️ CoreWLAN: interface.ssid() 返回 nil（可能需要 Location 权限）")
            lastError = WiFiMonitorError.ssidNotAvailable
            return nil
        }
    }
    
    /// 检测是否已连接 WiFi
    var isConnected: Bool {
        return currentSSID != nil
    }
    
    /// 强制刷新，清除缓存
    func forceRefresh() {
        logger.info("🔄 强制刷新 WiFi 状态")
        lastKnownSSID = nil
        lastCheckTime = .distantPast
        _ = currentSSID
    }
    
    override init() {
        super.init()
        client = CWWiFiClient.shared()
        locationManager = CLLocationManager()
        locationManager?.delegate = self
        logger.info("WiFiMonitor 初始化完成")
    }
    
    // MARK: - CLLocationManagerDelegate
    
    /// 授权状态变化回调
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        let statusString = String(describing: status)
        logger.info("Location 授权状态变化: \(statusString)")
        
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            // 权限已授予，清除缓存并通知外部
            lastKnownSSID = nil
            lastCheckTime = .distantPast
            onPermissionGranted?()
            
        case .denied, .restricted:
            logger.warning("Location 权限被拒绝")
            
        default:
            break
        }
    }
    
    // MARK: - 辅助功能
    
    /// 获取当前 WiFi 的详细信息
    func getCurrentWiFiInfo() -> WiFiInfo? {
        guard let interface = client?.interface(),
              let ssid = currentSSID else {
            logger.warning("无法获取 WiFi 详细信息: 未连接或无权限")
            return nil
        }
        
        let info = WiFiInfo(
            ssid: ssid,
            bssid: interface.bssid(),
            rssi: interface.rssiValue(),
            transmitRate: interface.transmitRate(),
            channel: interface.wlanChannel()?.channelNumber,
            noise: interface.noiseMeasurement()
        )
        
        logger.info("📶 WiFi 信息: SSID=\(info.ssid), RSSI=\(info.rssi ?? 0)dBm, 速率=\(info.transmitRate ?? 0)Mbps")
        return info
    }
}

/// WiFi 信息结构体
struct WiFiInfo {
    let ssid: String
    let bssid: String?
    let rssi: Int?
    let transmitRate: Double?
    let channel: Int?
    let noise: Int?
}

/// WiFi 监控错误类型
enum WiFiMonitorError: LocalizedError {
    case locationPermissionDenied
    case interfaceNotAvailable
    case wifiPoweredOff
    case ssidNotAvailable
    
    var errorDescription: String? {
        switch self {
        case .locationPermissionDenied:
            return NSLocalizedString("wifi_error_location_denied", comment: "")
        case .interfaceNotAvailable:
            return NSLocalizedString("wifi_error_interface", comment: "")
        case .wifiPoweredOff:
            return NSLocalizedString("wifi_error_powered_off", comment: "")
        case .ssidNotAvailable:
            return NSLocalizedString("wifi_error_ssid_unavailable", comment: "")
        }
    }
}
