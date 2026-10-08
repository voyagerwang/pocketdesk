import CoreAudio
import AudioToolbox
import Foundation

/// Native notifications avoid waiting for the controller's safety polling timer.
/// The retained listener is removed on device changes; queued old callbacks are ignored.
/// start/stop and controller callbacks run on main; the audio queue only timestamps notifications.
final class HeadsetVolumeObserver {
    private var device: AudioDeviceID?
    private var listener: AudioObjectPropertyListenerBlock?
    private var generation = 0
    private let callbackQueue = DispatchQueue(label: "pocketdesk.headset-volume", qos: .userInteractive)
    @discardableResult func start(device id: AudioDeviceID, changed: @escaping (TimeInterval) -> Void) -> Bool {
        guard device != id else { return true }
        stop()
        let expected = generation
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            let notifiedAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected, self.device == id else { return }
                changed(notifiedAt)
            }
        }
        var address = HeadsetAudio.volumeAddress()
        guard AudioObjectAddPropertyListenerBlock(id, &address, callbackQueue, block) == noErr else { return false }
        device = id; listener = block
        return true
    }
    func stop() {
        generation += 1
        if let device, let listener {
            var address = HeadsetAudio.volumeAddress()
            AudioObjectRemovePropertyListenerBlock(device, &address, callbackQueue, listener)
        }
        device = nil; listener = nil
    }
    deinit { stop() }
}

struct HeadsetAudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let volume: Float?
}

enum HeadsetAudio {
    static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var raw: Unmanaged<CFString>?; var size = UInt32(MemoryLayout.size(ofValue: raw))
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &raw) == noErr else { return nil }
        return raw?.takeRetainedValue() as String?
    }
    static func read(_ id: AudioDeviceID) -> HeadsetAudioDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
        var a = volumeAddress(); var volume: Float = 0; var size = UInt32(MemoryLayout<Float>.size)
        let result = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &volume)
        return HeadsetAudioDevice(id: id, uid: uid, name: name, volume: result == noErr ? volume : nil)
    }
    static func current() -> HeadsetAudioDevice? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr else { return nil }
        return read(id)
    }
    static func outputs() -> [HeadsetAudioDevice] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { return [] }
        return ids.filter { id in
            var stream = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &stream, 0, nil, &bytes) == noErr && bytes > 0
        }.compactMap { read($0) }
    }
    static func setVolume(_ value: Float, device: AudioDeviceID) -> Bool {
        var value = value; var a = volumeAddress()
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr
    }
}
