import AppKit
import AudioToolbox
import CoreAudio
import Foundation

// Default output/input device: read/set volume + mute, plus observers
// that re-bind when the user changes their default audio device (e.g.
// plugs in headphones or switches to an external USB mic). Volume is the
// "virtual main" (cross-channel) value that matches what the menubar
// slider and F11/F12 (output) / F10 (input mute) keys touch.

enum Audio {
    static func current() -> [String: Any] {
        guard let id = defaultOutputDevice() else {
            return ["volume": NSNull(), "muted": NSNull(), "deviceName": NSNull()]
        }
        return [
            "volume":     volume(of: id, scope: .output) as Any? ?? NSNull(),
            "muted":      muted(of: id, scope: .output),
            "deviceName": name(of: id) ?? ""
        ]
    }

    /// Mirror of `current()` for the default input device. Reads only —
    /// reading volume/level/name via the CoreAudio property API does NOT
    /// open an input stream, so this is microphone-TCC-free. Only
    /// `AVCaptureSession` / `AudioQueueStart` style stream opens trigger
    /// the prompt; nothing here does that.
    static func currentInput() -> [String: Any] {
        guard let id = defaultInputDevice() else {
            return ["volume": NSNull(), "muted": NSNull(), "deviceName": NSNull()]
        }
        return [
            "volume":     volume(of: id, scope: .input) as Any? ?? NSNull(),
            "muted":      muted(of: id, scope: .input),
            "deviceName": name(of: id) ?? ""
        ]
    }

    @discardableResult
    static func setVolume(_ value: Float) -> Bool {
        guard let id = defaultOutputDevice() else { return false }
        return setVolume(id: id, scope: .output, value)
    }

    @discardableResult
    static func setMuted(_ flag: Bool) -> Bool {
        guard let id = defaultOutputDevice() else { return false }
        return setMuted(id: id, scope: .output, flag)
    }

    @discardableResult
    static func setInputVolume(_ value: Float) -> Bool {
        guard let id = defaultInputDevice() else { return false }
        return setVolume(id: id, scope: .input, value)
    }

    @discardableResult
    static func setInputMuted(_ flag: Bool) -> Bool {
        guard let id = defaultInputDevice() else { return false }
        return setMuted(id: id, scope: .input, flag)
    }

    // MARK: - Device enumeration + default device selection

    /// Scope discriminator for input vs output reads/writes. Wraps the raw
    /// CoreAudio scope constants so call sites don't have to remember which
    /// magic UInt32 corresponds to which direction.
    enum Scope {
        case input, output

        var coreAudioScope: AudioObjectPropertyScope {
            switch self {
            case .input:  return kAudioDevicePropertyScopeInput
            case .output: return kAudioDevicePropertyScopeOutput
            }
        }

        /// Selector for the system-wide default-device pointer matching this
        /// scope. Used by both the listener block install + the read paths.
        var defaultDeviceSelector: AudioObjectPropertySelector {
            switch self {
            case .input:  return kAudioHardwarePropertyDefaultInputDevice
            case .output: return kAudioHardwarePropertyDefaultOutputDevice
            }
        }
    }

    /// Enumerate all audio devices that have at least one stream in `scope`.
    /// A USB headset typically shows up in both lists; a microphone-only
    /// device only in input. Returns the curated payload shape used by
    /// `sd.audio.devices` — id is the AudioDeviceID as Int so JS can pass
    /// it back through `setDefaultDevice`.
    static func devices(scope: Scope) -> [[String: Any]] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                &dataSize, &ids) == noErr else { return [] }

        let defaultID: AudioDeviceID? = {
            switch scope {
            case .input:  return defaultInputDevice()
            case .output: return defaultOutputDevice()
            }
        }()

        var out: [[String: Any]] = []
        for id in ids {
            // Filter to devices that actually have streams in the requested
            // direction — output-only devices clutter an input picker and
            // setDefault would silently fail on them anyway.
            guard hasStreams(id: id, scope: scope) else { continue }
            var row: [String: Any] = [
                "id":            Int(id),
                "name":          name(of: id) ?? "",
                "isDefault":     defaultID == id,
                "transportType": transportType(of: id) ?? NSNull(),
                "manufacturer":  manufacturer(of: id) ?? NSNull(),
                "uid":           uid(of: id) ?? NSNull()
            ]
            // Promote nullable keys to NSNull so JSON shape is stable across
            // devices (some Aggregate Devices return no manufacturer string).
            if row["transportType"] == nil { row["transportType"] = NSNull() }
            if row["manufacturer"]  == nil { row["manufacturer"]  = NSNull() }
            out.append(row)
        }
        return out
    }

    @discardableResult
    static func setDefaultDevice(id: AudioDeviceID, scope: Scope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: scope.defaultDeviceSelector,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var deviceID = id
        let err = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout.size(ofValue: deviceID)), &deviceID)
        return err == noErr
    }

    // MARK: - CoreAudio plumbing

    static func defaultOutputDevice() -> AudioDeviceID? {
        defaultDevice(scope: .output)
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        defaultDevice(scope: .input)
    }

    private static func defaultDevice(scope: Scope) -> AudioDeviceID? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: id))
        var addr = AudioObjectPropertyAddress(
            mSelector: scope.defaultDeviceSelector,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (err == noErr && id != 0) ? id : nil
    }

    static func volume(of id: AudioDeviceID, scope: Scope) -> Float? {
        var v: Float32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: v))
        var addr = volumeAddress(scope: scope)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return err == noErr ? v : nil
    }

    static func muted(of id: AudioDeviceID, scope: Scope) -> Bool {
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: v))
        var addr = muteAddress(scope: scope)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return err == noErr && v != 0
    }

    private static func setVolume(id: AudioDeviceID, scope: Scope, _ value: Float) -> Bool {
        let clamped: Float32 = max(0, min(1, value))
        var v = clamped
        var addr = volumeAddress(scope: scope)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        let err = AudioObjectSetPropertyData(id, &addr, 0, nil,
            UInt32(MemoryLayout.size(ofValue: v)), &v)
        return err == noErr
    }

    private static func setMuted(id: AudioDeviceID, scope: Scope, _ flag: Bool) -> Bool {
        var v: UInt32 = flag ? 1 : 0
        var addr = muteAddress(scope: scope)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        let err = AudioObjectSetPropertyData(id, &addr, 0, nil,
            UInt32(MemoryLayout.size(ofValue: v)), &v)
        return err == noErr
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

    private static func manufacturer(of id: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyManufacturer,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        guard err == noErr, let n = name?.takeRetainedValue() else { return nil }
        return n as String
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        guard err == noErr, let n = name?.takeRetainedValue() else { return nil }
        return n as String
    }

    /// Decoded transport type (USB / Bluetooth / Built-in / Aggregate / HDMI / ...).
    /// CoreAudio stores it as a FourCC — translate to a short string so JS can
    /// switch on it without decoding bits.
    private static func transportType(of id: AudioDeviceID) -> String? {
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: t))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return nil }
        switch t {
        case kAudioDeviceTransportTypeBuiltIn:    return "builtIn"
        case kAudioDeviceTransportTypeAggregate:  return "aggregate"
        case kAudioDeviceTransportTypeVirtual:    return "virtual"
        case kAudioDeviceTransportTypePCI:        return "pci"
        case kAudioDeviceTransportTypeUSB:        return "usb"
        case kAudioDeviceTransportTypeFireWire:   return "firewire"
        case kAudioDeviceTransportTypeBluetooth:  return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:return "bluetoothLE"
        case kAudioDeviceTransportTypeHDMI:       return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort:return "displayPort"
        case kAudioDeviceTransportTypeAirPlay:    return "airplay"
        case kAudioDeviceTransportTypeAVB:        return "avb"
        case kAudioDeviceTransportTypeThunderbolt:return "thunderbolt"
        case kAudioDeviceTransportTypeContinuityCaptureWired:    return "continuityCaptureWired"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuityCaptureWireless"
        case kAudioDeviceTransportTypeUnknown:    return "unknown"
        default:                                  return "unknown"
        }
    }

    /// True iff `id` has at least one stream in `scope`. CoreAudio enumerates
    /// every device under the system object regardless of direction, so this
    /// filter is what makes `devices(scope: .input)` return only mics.
    private static func hasStreams(id: AudioDeviceID, scope: Scope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope:    scope.coreAudioScope,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    // Per-scope address builders. AudioObjectPropertyAddress is a value
    // type — building one inline is cheap, and avoiding the two cached
    // statics keeps the input/output paths from accidentally sharing a
    // mutable address that one of them then races to change.
    static func volumeAddress(scope: Scope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope:    scope.coreAudioScope,
            mElement:  kAudioObjectPropertyElementMain
        )
    }
    static func muteAddress(scope: Scope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    scope.coreAudioScope,
            mElement:  kAudioObjectPropertyElementMain
        )
    }

    // Back-compat statics for AudioObserver's listener-block remove path,
    // which compares property-address selector+scope at unbind time. Kept
    // as `static var` (rather than recomputed inline) because the old code
    // passed `&Audio.mainVolumeAddress` directly to CoreAudio and we want
    // to preserve the same call shape for the output observer.
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

// MARK: - Input observer

/// Mirror of `AudioObserver` for the default input device. Separate class
/// (rather than parameterizing AudioObserver by scope) because each Observer
/// owns a single set of listener-block references — the input + output
/// listeners need independent lifetime + lock state, and the install path
/// uses a different default-device selector. Keeping them split also keeps
/// the install/unbind code paths obvious vs. a parameterized factory.
final class AudioInputObserver: RefCountedObserver {
    static let shared = AudioInputObserver()
    private override init() { super.init() }

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
        // Default-input-device change → re-bind volume / mute listeners onto
        // the new device and notify subscribers. Same shape as the output
        // observer; only the property selector differs.
        let dev: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebind()
            self?.notify()
        }
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
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

        return Token { [weak self] in
            guard let self = self else { return }
            var devAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
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
        unbindDevice()
        guard let id = Audio.defaultInputDevice() else { return }

        let vol: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
        let mute: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
        var volAddr  = Audio.volumeAddress(scope: .input)
        var muteAddr = Audio.muteAddress(scope: .input)
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
        var volAddr  = Audio.volumeAddress(scope: .input)
        var muteAddr = Audio.muteAddress(scope: .input)
        if let vol  = vol  { AudioObjectRemovePropertyListenerBlock(id, &volAddr,  listenerQueue, vol)  }
        if let mute = mute { AudioObjectRemovePropertyListenerBlock(id, &muteAddr, listenerQueue, mute) }
    }
}

// MARK: - Media (now playing)

// MRMediaRemote.framework private SPI. Covers Spotify / Apple Music /
// Podcasts / browser audio — anything that publishes to macOS Now Playing.
// Vendored via dlopen so a missing-or-renamed symbol degrades to null
// rather than crashing the daemon (cf. CGSSetMenuBarVisibility on Sequoia+).

enum MediaRemote {
    // Inner closure must be `@escaping`: the framework dispatches it
    // asynchronously to the queue. Swift auto-bridges to an ObjC block.
    typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    typealias SendCommandFn       = @convention(c) (UInt32, CFDictionary?) -> Bool
    typealias RegisterFn          = @convention(c) (DispatchQueue) -> Void

    static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    }()

    static let getNowPlayingInfo: GetNowPlayingInfoFn? = {
        guard let h = handle, let s = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(s, to: GetNowPlayingInfoFn.self)
    }()

    static let sendCommand: SendCommandFn? = {
        guard let h = handle, let s = dlsym(h, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(s, to: SendCommandFn.self)
    }()

    static let registerForNotifications: RegisterFn? = {
        guard let h = handle, let s = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications") else { return nil }
        return unsafeBitCast(s, to: RegisterFn.self)
    }()

    // MRMediaRemoteCommand enum values (stable across macOS releases).
    static let commands: [String: UInt32] = [
        "play":         0,
        "pause":        1,
        "toggle":       2,   // togglePlayPause
        "stop":         3,
        "next":         4,   // nextTrack
        "previous":     5,   // previousTrack
        "skipForward":  14,
        "skipBackward": 15
    ]
}

enum Media {
    /// Resolves the latest now-playing snapshot. Returns nil if MediaRemote
    /// isn't loadable, or no app is currently broadcasting.
    static func nowPlaying(completion: @escaping ([String: Any]?) -> Void) {
        guard let fn = MediaRemote.getNowPlayingInfo else {
            // Match the success path's queue: MediaRemote's callback fires
            // completion(out) on the global utility queue. Without this hop
            // the bail path would fire inline, which Bridge.respond would
            // immediately re-enter — also a re-entrancy hazard if a stack
            // chains calls. Same shape as the Vision.runRequest fix.
            DispatchQueue.global(qos: .utility).async { completion(nil) }
            return
        }
        fn(.global(qos: .utility)) { info in
            guard !info.isEmpty else { completion(nil); return }
            var out: [String: Any] = [:]
            if let t = info["kMRMediaRemoteNowPlayingInfoTitle"]  as? String { out["title"]  = t }
            if let a = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String { out["artist"] = a }
            if let a = info["kMRMediaRemoteNowPlayingInfoAlbum"]  as? String { out["album"]  = a }
            if let d = info["kMRMediaRemoteNowPlayingInfoDuration"]    as? Double { out["duration"] = d }
            if let e = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double { out["elapsed"]  = e }
            if let r = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double { out["playing"] = r > 0 }
            // Artwork omitted — base64-encoding the CFData on every push is
            // wasteful for a HUD's purposes. Future iteration: serve via a
            // synthetic sd://artwork URL.
            completion(out)
        }
    }

    @discardableResult
    static func command(_ name: String) -> Bool {
        guard let fn = MediaRemote.sendCommand, let cmd = MediaRemote.commands[name] else { return false }
        return fn(cmd, nil)
    }
}

final class MediaObserver: RefCountedObserver {
    static let shared = MediaObserver()
    private override init() { super.init() }

    /// MRMediaRemoteRegisterForNowPlayingNotifications is fire-and-forget —
    /// there is no symmetric unregister. To avoid double-registering across
    /// install/teardown cycles (which the framework reacts to by either
    /// duplicating notifications or silently rejecting), gate it to exactly
    /// once per process via a static-let-once initializer.
    private static let registerOnce: Void = {
        MediaRemote.registerForNotifications?(.main)
    }()

    override func install() -> Token? {
        guard MediaRemote.registerForNotifications != nil else { return nil }
        _ = MediaObserver.registerOnce
        let nc = NotificationCenter.default
        return installNotifications([
            (nc, NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")),
            (nc, NSNotification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")),
            (nc, NSNotification.Name("kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"))
        ])
    }
}

// MARK: - Sound (fire-and-forget playback)

// Fire-and-forget audio playback via NSSound. No completion callback, no
// playback tracking — Hammerspoon's hs.sound is the reference shape.
//
// Lifecycle: NSSound retains itself while playing, so we don't need to hold
// a reference. The instance releases once playback ends naturally.

enum Sound {
    /// NSSound(named:) searches /System/Library/Sounds and ~/Library/Sounds
    /// for `<name>.aiff` (and a handful of other extensions).
    @discardableResult
    static func system(_ name: String) -> Bool {
        guard let s = NSSound(named: name) else { return false }
        return s.play()
    }

    /// byReference: true avoids loading the entire file into memory — fine for
    /// short alerts, and the file path persists for the lifetime of playback.
    @discardableResult
    static func file(_ path: String) -> Bool {
        let p = (path as NSString).expandingTildeInPath
        guard let s = NSSound(contentsOfFile: p, byReference: true) else { return false }
        return s.play()
    }

    static func beep() {
        NSSound.beep()
    }
}
