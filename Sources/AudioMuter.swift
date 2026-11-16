import Foundation
import CoreAudio

/// 合盖静音：在「盖子合上 **且** 处于防休眠状态」时把当前输出设备静音，
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
final class AudioMuter {

    /// 静音快照。`usedMute == true` 表示用设备静音属性；false 表示退回音量 0。
    private struct Snapshot: Codable {
        var deviceID: UInt32
        var usedMute: Bool
        var previousMute: UInt32
        var previousVolume: Float32
        var volumeElement: UInt32
    }

    private static let snapshotKey = "audioMuteSnapshotForLidClose"

    /// 当前是否由我们静音着
    private(set) var isMutedByLidClose = false

    // MARK: - 对外接口

    /// 合盖且防休眠中：静音。返回是否真的改动了音频状态。
    @discardableResult
    func muteForClosedLid() -> Bool {
        guard !isMutedByLidClose else { return false }
        guard let device = Self.defaultOutputDevice() else {
            FileLogger.shared.log("🔇 找不到默认输出设备，跳过静音")
            return false
        }

        // 如果上次留下了没恢复的快照，先恢复，保证基准是"用户真实的状态"
        if let stale = Self.loadSnapshot() {
            Self.apply(stale)
            Self.clearSnapshot()
        }

        guard let snapshot = Self.makeSnapshot(device: device) else {
            FileLogger.shared.log("🔇 该输出设备既没有静音属性也没有音量属性，跳过静音")
            return false
        }

        guard Self.applyMuted(snapshot) else {
            FileLogger.shared.log("🔇 静音写入失败，已跳过")
            return false
        }

        Self.saveSnapshot(snapshot)
        isMutedByLidClose = true
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

    /// 静音期间默认输出设备变了（插了耳机 / 切了 AirPlay）→ 把新设备也静音。
    /// 返回是否做了处理。
    @discardableResult
    func refreshIfDeviceChanged() -> Bool {
        guard isMutedByLidClose, let snapshot = Self.loadSnapshot() else { return false }
        guard let current = Self.defaultOutputDevice(), current != snapshot.deviceID else { return false }

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

    /// 当前默认输出设备
    private static func defaultOutputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
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
    private static func makeSnapshot(device: AudioObjectID) -> Snapshot? {
        var muteAddr = muteAddress()
        if let wasMuted = readUInt32(device, &muteAddr) {
            return Snapshot(deviceID: UInt32(device),
                            usedMute: true,
                            previousMute: wasMuted,
                            previousVolume: 0,
                            volumeElement: kAudioObjectPropertyElementMain)
        }

        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var volumeAddr = volumeAddress(element: element)
            if let wasVolume = readFloat32(device, &volumeAddr) {
                return Snapshot(deviceID: UInt32(device),
                                usedMute: false,
                                previousMute: 0,
                                previousVolume: wasVolume,
                                volumeElement: element)
            }
        }
        return nil
    }

    /// 按快照把设备静音（mute=1 或 volume=0）
    private static func applyMuted(_ snapshot: Snapshot) -> Bool {
        let device = AudioObjectID(snapshot.deviceID)
        if snapshot.usedMute {
            var muteAddr = muteAddress()
            return writeUInt32(device, &muteAddr, 1)
        }
        var volumeAddr = volumeAddress(element: snapshot.volumeElement)
        return writeFloat32(device, &volumeAddr, 0)
    }

    /// 按快照恢复原状态
    private static func apply(_ snapshot: Snapshot) {
        let device = AudioObjectID(snapshot.deviceID)
        if snapshot.usedMute {
            var muteAddr = muteAddress()
            _ = writeUInt32(device, &muteAddr, snapshot.previousMute)
        } else {
            var volumeAddr = volumeAddress(element: snapshot.volumeElement)
            _ = writeFloat32(device, &volumeAddr, snapshot.previousVolume)
        }
    }
}
