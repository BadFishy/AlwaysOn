import Foundation
import CoreWLAN
import CoreLocation
import OSLog

/// WiFi 检测管理器
final class WiFiMonitor: NSObject, CLLocationManagerDelegate {
    private var client: CWWiFiClient?
    private var locationManager: CLLocationManager?
    
    private var lastKnownSSID: String?
    private var lastCheckTime: Date = .distantPast
    private let cacheTimeout: TimeInterval = 5.0
    private let logger = Logger(subsystem: "com.alwayson.app", category: "WiFiMonitor")
    
    /// 最后一次错误，用于外部检测错误
    private(set) var lastError: Error?
    
    /// 权限状态回调
    var onPermissionStatusChanged: ((Bool) -> Void)?
    
    /// 权限授予回调（简化版，仅在授权成功时触发）
    var onPermissionGranted: (() -> Void)?
    
    /// 同步获取当前 WiFi SSID
    /// 直接调用 CoreWLAN（本地 API，不阻塞网络）
    /// 权限已授予时总是返回实时值，未授予时返回缓存值
    var currentSSID: String? {
        // 先检查缓存
        let now = Date()
        if now.timeIntervalSince(lastCheckTime) < cacheTimeout, let cached = lastKnownSSID {
            return cached
        }
        
        // 直接从 CoreWLAN 同步获取
        guard let interface = client?.interface() else {
            logger.warning("CoreWLAN: Cannot get WiFi interface")
            lastError = WiFiMonitorError.interfaceNotAvailable
            return nil
        }
        
        guard interface.powerOn() else {
            logger.warning("CoreWLAN: WiFi powered off")
            lastError = WiFiMonitorError.wifiPoweredOff
            lastKnownSSID = nil
            return nil
        }
        
        if let ssid = interface.ssid() {
            lastKnownSSID = ssid
            lastCheckTime = Date()
            lastError = nil
            logger.info("CoreWLAN got SSID: \(ssid)")
            return ssid
        } else {
            logger.debug("CoreWLAN: interface.ssid() returned nil (no location permission or not connected)")
            lastError = WiFiMonitorError.ssidNotAvailable
            lastKnownSSID = nil
            return nil
        }
    }
    
    /// 异步获取当前 WiFi SSID（带权限请求）
    func getCurrentSSID(completion: @escaping (String?) -> Void) {
        // 检查 Location 权限
        checkLocationPermission { [weak self] granted in
            guard let self = self else {
                completion(nil)
                return
            }
            
            guard granted else {
                self.logger.warning("Location permission denied")
                self.lastError = WiFiMonitorError.locationPermissionDenied
                completion(nil)
                return
            }
            
            // 权限已授予，清除缓存强制重新获取
            self.lastCheckTime = .distantPast
            completion(self.currentSSID)
        }
    }
    
    /// 检测是否已连接 WiFi
    var isConnected: Bool {
        return currentSSID != nil
    }
    
    /// 强制刷新，清除缓存
    func forceRefresh() {
        lastKnownSSID = nil
        lastCheckTime = .distantPast
    }
    
    /// 请求位置权限（首次使用时调用）
    func requestPermissionIfNeeded() {
        guard let locationManager = locationManager else { return }
        
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            logger.info("Requesting location permission for WiFi SSID detection...")
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
    
    // MARK: - 私有方法
    
    /// 检查 Location 权限
    private func checkLocationPermission(completion: @escaping (Bool) -> Void) {
        guard let locationManager = locationManager else {
            completion(false)
            return
        }
        
        let status = locationManager.authorizationStatus
        
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            completion(true)
            
        case .notDetermined:
            logger.info("Location permission not determined, requesting...")
            requestLocationPermission(completion: completion)
            
        case .denied, .restricted:
            logger.warning("Location permission denied or restricted")
            completion(false)
            
        @unknown default:
            logger.error("Unknown location authorization status")
            completion(false)
        }
    }
    
    /// 请求 Location 权限
    private func requestLocationPermission(completion: @escaping (Bool) -> Void) {
        guard let locationManager = locationManager else {
            completion(false)
            return
        }
        
        permissionCallback = completion
        locationManager.requestWhenInUseAuthorization()
    }
    
    private var permissionCallback: ((Bool) -> Void)?
    
    /// CLLocationManagerDelegate - 授权状态变化
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        logger.info("Location authorization status changed: \(String(describing: status))")
        
        let granted: Bool
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            granted = true
        case .denied, .restricted, .notDetermined:
            granted = false
        @unknown default:
            granted = false
        }
        
        // 回调并清理
        permissionCallback?(granted)
        permissionCallback = nil
        
        // 通知外部
        onPermissionStatusChanged?(granted)
        if granted {
            onPermissionGranted?()
        }
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
