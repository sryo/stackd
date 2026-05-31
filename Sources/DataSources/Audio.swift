import CoreAudio
import AudioToolbox
import Foundation

// Default output device: read/set volume + mute, plus a single observer
// that re-binds when the user changes their default audio output (e.g.
// plugs in headphones). Volume is the "virtual main" (cross-channel) value
// that matches what the menubar slider and F11/F12 keys touch.

enum Audio {
    static func current() -> [String: Any] {
        guard let id = defaultOutputDevice() else {
            return ["volume": NSNull(), "muted": NSNull(), "deviceName": NSNull()]
        }
        return [
            "volume":     volume(of: id)      as Any? ?? NSNull(),
            "muted":      muted(of: id),
            "deviceName": name(of: id) ?? ""
        ]
    }

    @discardableResult
    static func setVolume(_ value: Float) -> Bool {
        guard let id = defaultOutputDevice() else { return false }
        let clamped: Float32 = max(0, min(1, value))
        var v = clamped
        var addr = mainVolumeAddress
        guard AudioObjectHasProperty(id, &addr) else { return false }
        let err = AudioObjectSetPropertyData(id, &addr, 0, nil,
            UInt32(MemoryLayout.size(ofValue: v)), &v)
        return err == noErr
    }

    @discardableResult
    static func setMuted(_ flag: Bool) -> Bool {
        guard let id = defaultOutputDevice() else { return false }
        var v: UInt32 = flag ? 1 : 0
        var addr = muteAddress
        guard AudioObjectHasProperty(id, &addr) else { return false }
        let err = AudioObjectSetPropertyData(id, &addr, 0, nil,
            UInt32(MemoryLayout.size(ofValue: v)), &v)
        return err == noErr
    }

    // MARK: - CoreAudio plumbing

    static func defaultOutputDevice() -> AudioDeviceID? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: id))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (err == noErr && id != 0) ? id : nil
    }

    static func volume(of id: AudioDeviceID) -> Float? {
        var v: Float32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: v))
        var addr = mainVolumeAddress
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return err == noErr ? v : nil
    }

    static func muted(of id: AudioDeviceID) -> Bool {
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: v))
        var addr = muteAddress
        guard AudioObjectHasProperty(id, &addr) else { return false }
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return err == noErr && v != 0
    }

    static func name(of id: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        guard err == noErr, let n = name?.takeRetainedValue() else { return nil }
        return n as String
    }

    static var mainVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope:    kAudioDevicePropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain
    )
    static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope:    kAudioDevicePropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain
    )
}

final class AudioObserver: RefCountedObserver {
    static let shared = AudioObserver()
    private override init() { super.init() }

    // CoreAudio listener blocks. Stored so install() can return a Token that
    // removes the exact blocks we installed (not by reference; we hold them).
    private var deviceChangeBlock: AudioObjectPropertyListenerBlock?
    private var volumeBlock:       AudioObjectPropertyListenerBlock?
    private var muteBlock:         AudioObjectPropertyListenerBlock?
    private var boundDevice: AudioDeviceID?

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.fire() }
    }

    override func install() -> Token {
        // Default-output-device change → re-bind volume / mute listeners onto
        // the new device and notify subscribers.
        let dev: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebind()
            self?.notify()
        }
        deviceChangeBlock = dev
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devAddr,
            DispatchQueue.global(qos: .utility), dev)

        rebind()

        return Token { [weak self] in
            guard let self = self else { return }
            var devAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            if let blk = self.deviceChangeBlock {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &devAddr,
                    DispatchQueue.global(qos: .utility), blk)
            }
            self.unbindDevice()
            self.deviceChangeBlock = nil
        }
    }

    private func rebind() {
        // Drop volume/mute listeners on the previous device first.
        unbindDevice()
        guard let id = Audio.defaultOutputDevice() else { return }
        boundDevice = id

        let vol: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
        let mute: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
        volumeBlock = vol
        muteBlock   = mute
        var volAddr  = Audio.mainVolumeAddress
        var muteAddr = Audio.muteAddress
        AudioObjectAddPropertyListenerBlock(id, &volAddr,  DispatchQueue.global(qos: .utility), vol)
        AudioObjectAddPropertyListenerBlock(id, &muteAddr, DispatchQueue.global(qos: .utility), mute)
    }

    private func unbindDevice() {
        guard let id = boundDevice else { return }
        var volAddr  = Audio.mainVolumeAddress
        var muteAddr = Audio.muteAddress
        if let blk = volumeBlock {
            AudioObjectRemovePropertyListenerBlock(id, &volAddr,  DispatchQueue.global(qos: .utility), blk)
        }
        if let blk = muteBlock {
            AudioObjectRemovePropertyListenerBlock(id, &muteAddr, DispatchQueue.global(qos: .utility), blk)
        }
        boundDevice = nil
        volumeBlock = nil
        muteBlock   = nil
    }
}
