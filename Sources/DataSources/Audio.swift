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

    // CoreAudio listener blocks live as class properties so the SAME Swift→
    // ObjC bridged block reference is passed to both Add and Remove. The
    // listener API compares by block identity; reading a property returns
    // the same heap-block pointer the first reference produced. The lock
    // serializes mutation of these refs and the underlying CoreAudio
    // registrations — the device-change listener fires on a background
    // utility queue while Token.cancel typically runs on main, so without
    // synchronization rebind() and unbindDevice() can race on a hot AirPods
    // swap during stack unload.
    private var deviceChangeBlock: AudioObjectPropertyListenerBlock?
    private var volumeBlock:       AudioObjectPropertyListenerBlock?
    private var muteBlock:         AudioObjectPropertyListenerBlock?
    private var boundDevice: AudioDeviceID?
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue.global(qos: .utility)

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.fire() }
    }

    override func install() -> Token? {
        // Default-output-device change → re-bind volume / mute listeners onto
        // the new device and notify subscribers.
        let dev: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebind()
            self?.notify()
        }
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        lock.lock()
        deviceChangeBlock = dev
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devAddr,
            listenerQueue, dev)
        lock.unlock()

        rebind()

        // Capture the exact `dev` reference in the Token's closure so the
        // pointer passed to AudioObjectRemovePropertyListenerBlock is the same
        // one CoreAudio retained at Add time — surviving any later mutation
        // of self.deviceChangeBlock.
        return Token { [weak self] in
            guard let self = self else { return }
            var devAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            self.lock.lock()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &devAddr,
                self.listenerQueue, dev)
            self.deviceChangeBlock = nil
            self.lock.unlock()
            self.unbindDevice()
        }
    }

    private func rebind() {
        // Drop volume/mute listeners on the previous device first.
        unbindDevice()
        guard let id = Audio.defaultOutputDevice() else { return }

        let vol: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
        let mute: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
        var volAddr  = Audio.mainVolumeAddress
        var muteAddr = Audio.muteAddress
        lock.lock()
        boundDevice = id
        volumeBlock = vol
        muteBlock   = mute
        AudioObjectAddPropertyListenerBlock(id, &volAddr,  listenerQueue, vol)
        AudioObjectAddPropertyListenerBlock(id, &muteAddr, listenerQueue, mute)
        lock.unlock()
    }

    private func unbindDevice() {
        lock.lock()
        let id = boundDevice
        let vol = volumeBlock
        let mute = muteBlock
        boundDevice = nil
        volumeBlock = nil
        muteBlock = nil
        lock.unlock()
        guard let id = id else { return }
        var volAddr  = Audio.mainVolumeAddress
        var muteAddr = Audio.muteAddress
        if let vol  = vol  { AudioObjectRemovePropertyListenerBlock(id, &volAddr,  listenerQueue, vol)  }
        if let mute = mute { AudioObjectRemovePropertyListenerBlock(id, &muteAddr, listenerQueue, mute) }
    }
}
