import Foundation

final class WebhookManager {
    static let shared = WebhookManager()
    
    private let config = ConfigManager.shared
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }
    
    var isConfigured: Bool {
        return config.isWebhookConfigured
    }
    
    func saveWebhookURL(_ url: String) {
        config.setWebhookURL(url)
    }
    
    func setEnabled(_ enabled: Bool) {
        config.setWebhookEnabled(enabled)
    }
    
    func sendStatusChanged(
        previousStatus: String,
        currentStatus: String,
        wifi: String?,
        power: String,
        lid: String,
        mode: String
    ) {
        guard let url = webhookURL else { return }
        
        let appName = NSLocalizedString("app_name", comment: "")
        let payload: [String: Any] = [
            "event": "status_changed",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": appName,
            "data": [
                "status": currentStatus,
                "previous_status": previousStatus,
                "wifi": wifi ?? NSLocalizedString("webhook_payload_wifi_not_connected", comment: ""),
                "power": power,
                "lid": lid,
                "mode": mode
            ]
        ]
        
        sendJSONPayload(to: url, payload: payload)
    }
    
    func sendLaunchNotification(version: String, configStatus: String) {
        guard let url = webhookURL else { return }
        
        let appName = NSLocalizedString("app_name", comment: "")
        let payload: [String: Any] = [
            "event": "launch",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": appName,
            "data": [
                "version": version,
                "config_status": configStatus
            ]
        ]
        
        sendJSONPayload(to: url, payload: payload)
    }
    
    func sendQuitNotification(runtimeMinutes: Int) {
        guard let url = webhookURL else { return }
        
        let appName = NSLocalizedString("app_name", comment: "")
        let payload: [String: Any] = [
            "event": "quit",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": appName,
            "data": [
                "runtime_minutes": runtimeMinutes
            ]
        ]
        
        sendJSONPayload(to: url, payload: payload)
    }
    
    func sendErrorNotification(errorType: String, details: String) {
        guard let url = webhookURL else { return }
        
        let appName = NSLocalizedString("app_name", comment: "")
        let payload: [String: Any] = [
            "event": "error",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": appName,
            "data": [
                "error_type": errorType,
                "details": details
            ]
        ]
        
        sendJSONPayload(to: url, payload: payload)
    }
    
    func sendLowBatteryWarning(batteryLevel: Int) {
        guard let url = webhookURL else { return }
        
        let appName = NSLocalizedString("app_name", comment: "")
        let payload: [String: Any] = [
            "event": "low_battery",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": appName,
            "data": [
                "battery_level": batteryLevel
            ]
        ]
        
        sendJSONPayload(to: url, payload: payload)
    }
    
    func sendTestMessage(completion: ((Bool, Int, String?, String?) -> Void)? = nil) {
        guard let url = webhookURL else {
            completion?(false, 0, "Webhook URL 未配置", nil)
            return
        }
        
        let appName = NSLocalizedString("app_name", comment: "")
        let payload: [String: Any] = [
            "event": "test",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": appName,
            "message": "Test message from \(appName)!"
        ]
        
        sendJSONPayloadWithResponse(to: url, payload: payload, completion: completion)
    }
    
    private var webhookURL: URL? {
        guard config.webhookEnabled,
              let urlString = config.webhookURL,
              let url = URL(string: urlString) else {
            return nil
        }
        return url
    }
    
    private func sendJSONPayload(to url: URL, payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("[AlwaysOn] Failed to encode webhook payload")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[AlwaysOn] Webhook failed: \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if (200...299).contains(httpResponse.statusCode) {
                    print("[AlwaysOn] Webhook sent successfully")
                } else {
                    print("[AlwaysOn] Webhook failed with status: \(httpResponse.statusCode)")
                }
            }
        }
        
        task.resume()
    }
    
    private func sendJSONPayloadWithResponse(
        to url: URL,
        payload: [String: Any],
        completion: ((Bool, Int, String?, String?) -> Void)?
    ) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion?(false, 0, "请求数据编码失败", nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        let task = session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion?(false, 0, error.localizedDescription, nil)
                    return
                }
                
                var responseBody: String?
                if let data = data {
                    responseBody = String(data: data, encoding: .utf8)
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    let statusCode = httpResponse.statusCode
                    let success = (200...299).contains(statusCode)
                    completion?(success, statusCode, nil, responseBody)
                } else {
                    completion?(false, 0, "未知响应", responseBody)
                }
            }
        }
        
        task.resume()
    }
}