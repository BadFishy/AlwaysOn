import Foundation
import CoreAudio

/// 合盖静音：在「盖子合上 **且** 处于防休眠状态」时把输出设备静音，
/// 开盖（或不再防休眠）后恢复原状。
///
/// 设计要点：
///
/// 1. **用 CoreAudio 而不是 `osascript -e 'set volume ...'`**：AppleScript 控制音量会
///    触发「自动化」TCC 授权（还可能弹窗拦住用户），而 CoreAudio 是进程内 API，
///    不需要任何权限、也不会打断用户。
/// 2. **只在"真的会保持唤醒"时静音**：如果合盖后本来就要睡（例如电池 + 非白名单 WiFi），
///    静音没有意义，还可能在睡眠失败时把机器留在静音状态。
/// 3. **恢复的是"原来的状态"而不是"取消静音"**：用户本来是静音的话，我们恢复成静音。
/// 4. **崩溃自愈**：静音快照持久化到 UserDefaults；下次启动若发现"上次是我们静的音"，
///    先恢复再说，避免机器被永久静音。
/// 5. **输出设备会变**：静音期间用户插拔耳机/AirPlay 会让默认设备变化，
///    `refreshIfDeviceChanged()` 负责把新设备也静音，避免声音从新设备漏出来。
/// 6. **两个"默认输出"都要处理**：macOS 有 `DefaultOutputDevice`（媒体）和
///    `DefaultSystemOutputDevice`（**系统提示音**）两个概念，可以在「声音 → 声音效果 →
///    播放声音效果通过」里分开指定。合盖接外接显示器时媒体切到显示器扬声器、提示音
///    却可能仍留在内建扬声器 —— 只静音前者就会漏掉提示音。所以两个设备都静音。
final class AudioMuter {

    /// 单个设备的静音前状态。`usedMute == true` 表示用设备静音属性；false 表示退回音量 0。
    private struct DeviceState: Codable {
        var deviceID: UInt32
        var usedMute: Bool
        var previousMute: UInt32
        var previousVolume: Float32
        var volumeElement: UInt32
    }

    /// 一次静音可能涉及多个设备（媒体输出 + 系统提示音输出）
    private struct Snapshot: Codable {
        var devices: [DeviceState]
    }

    private static let snapshotKey = "audioMuteSnapshotForLidClose"

    /// 当前是否由我们静音着
    private(set) var isMutedByLidClose = false

    // MARK: - 对外接口

    /// 合盖且防休眠中：静音媒体输出与系统提示音输出。返回是否真的改动了音频状态。
    @discardableResult
    func muteForClosedLid() -> Bool {
        guard !isMutedByLidClose else { return false }

        let targets = Self.targetDevices()
        guard !targets.isEmpty else {
            FileLogger.shared.log("🔇 找不到输出设备，跳过静音")
            return false
        }

        // 如果上次留下了没恢复的快照，先恢复，保证基准是"用户真实的状态"
        if let stale = Self.loadSnapshot() {
            Self.apply(stale)
            Self.clearSnapshot()
        }

        var states: [DeviceState] = []
        for device in targets {
            if let state = Self.makeSnapshot(device: device) {
                states.append(state)
            }
        }
        guard !states.isEmpty else {
            FileLogger.shared.log("🔇 输出设备既没有静音属性也没有音量属性，跳过静音")
            return false
        }

        var applied = 0
        for state in states where Self.applyMuted(state) {
            applied += 1
        }
        guard applied > 0 else {
            FileLogger.shared.log("🔇 静音写入失败，已跳过")
            return false
        }

        Self.saveSnapshot(Snapshot(devices: states))
        isMutedByLidClose = true
        let names = states.map { $0.usedMute ? "" : "(音量)" }.joined()
        FileLogger.shared.log("🔇 已静音 \(applied) 个输出设备（媒体 + 系统提示音）\(names)")
        return true
    }

    /// 恢复到静音之前的状态。
    @discardableResult
    func restoreAfterClosedLid() -> Bool {
        guard isMutedByLidClose || Self.loadSnapshot() != nil else { return false }
        if let snapshot = Self.loadSnapshot() {
            Self.apply(snapshot)
            Self.clearSnapshot()
        }
        isMutedByLidClose = false
        return true
    }

    /// 静音期间默认输出设备变了（插了耳机 / 切了 AirPlay / 接了显示器）→ 把新设备也静音。
    @discardableResult
    func refreshIfDeviceChanged() -> Bool {
        guard isMutedByLidClose, let snapshot = Self.loadSnapshot() else { return false }
        let saved = Set(snapshot.devices.map { $0.deviceID })
        let current = Set(Self.targetDevices().map { UInt32($0) })
        guard saved != current else { return false }

        FileLogger.shared.log("🔇 输出设备已切换，正在把新设备也静音")
        // 先尽量恢复旧设备（它可能还在用），再对新设备静音
        Self.apply(snapshot)
        Self.clearSnapshot()
        isMutedByLidClose = false
        return muteForClosedLid()
    }

    /// 启动自愈：上次异常退出可能留下静音状态。
    func healOnLaunch() {
        if let snapshot = Self.loadSnapshot() {
            FileLogger.shared.log("🔊 检测到上次静音未恢复（可能异常退出），正在恢复")
            Self.apply(snapshot)
            Self.clearSnapshot()
        }
        isMutedByLidClose = false
    }

    // MARK: - 持久化

    private static func saveSnapshot(_ snapshot: Snapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
    }

    private static func loadSnapshot() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func clearSnapshot() {
        UserDefaults.standard.removeObject(forKey: snapshotKey)
    }

    // MARK: - CoreAudio

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func propertyDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// 需要静音的设备集合：媒体输出 + 系统提示音输出（去重）。
    ///
    /// 为什么两个都要：macOS 允许把「声音效果」单独指到别的设备。合盖接外接显示器时
    /// 媒体输出会切到显示器扬声器，而提示音可能仍走内建扬声器 —— 只静音前者会漏音。
    private static func targetDevices() -> [AudioObjectID] {
        var devices: [AudioObjectID] = []
        if let media = propertyDevice(kAudioHardwarePropertyDefaultOutputDevice) {
            devices.append(media)
        }
        if let system = propertyDevice(kAudioHardwarePropertyDefaultSystemOutputDevice),
           !devices.contains(system) {
            devices.append(system)
        }
        return devices
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        return AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func volumeAddress(element: UInt32) -> AudioObjectPropertyAddress {
        return AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }

    private static func readUInt32(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> UInt32? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func writeUInt32(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
        var mutable = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &mutable) == noErr
    }

    private static func readFloat32(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Float32? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func writeFloat32(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress, _ value: Float32) -> Bool {
        var mutable = value
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &mutable) == noErr
    }

    /// 优先用设备静音属性；不支持则退回音量 0。
    /// 元素优先级：main → 1 → 2（不同声卡暴露的元素不一样）。
    private static func makeSnapshot(device: AudioObjectID) -> DeviceState? {
        var muteAddr = muteAddress()
        if let wasMuted = readUInt32(device, &muteAddr) {
            return DeviceState(deviceID: UInt32(device),
                               usedMute: true,
                               previousMute: wasMuted,
                               previousVolume: 0,
                               volumeElement: kAudioObjectPropertyElementMain)
        }

        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var volumeAddr = volumeAddress(element: element)
            if let wasVolume = readFloat32(device, &volumeAddr) {
                return DeviceState(deviceID: UInt32(device),
                                   usedMute: false,
                                   previousMute: 0,
                                   previousVolume: wasVolume,
                                   volumeElement: element)
            }
        }
        return nil
    }

    /// 按快照把设备静音（mute=1 或 volume=0）
    private static func applyMuted(_ state: DeviceState) -> Bool {
        let device = AudioObjectID(state.deviceID)
        if state.usedMute {
            var muteAddr = muteAddress()
            return writeUInt32(device, &muteAddr, 1)
        }
        var volumeAddr = volumeAddress(element: state.volumeElement)
        return writeFloat32(device, &volumeAddr, 0)
    }

    /// 按快照恢复原状态
    private static func apply(_ snapshot: Snapshot) {
        for state in snapshot.devices {
            let device = AudioObjectID(state.deviceID)
            if state.usedMute {
                var muteAddr = muteAddress()
                _ = writeUInt32(device, &muteAddr, state.previousMute)
            } else {
                var volumeAddr = volumeAddress(element: state.volumeElement)
                _ = writeFloat32(device, &volumeAddr, state.previousVolume)
            }
        }
    }
}
