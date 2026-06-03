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
    /// Resolves the latest now-playing snapshot. Returns nil if no source
    /// is currently broadcasting (MediaRemote silent AND no per-app fallback
    /// has data).
    ///
    /// Spotify on macOS 26 (Tahoe) frequently doesn't register with
    /// MediaRemote — title/artist come up empty even mid-playback. When
    /// MediaRemote returns an EMPTY info dict, we fall back to a one-shot
    /// osascript against any broadcast-broken app that's currently running.
    /// A non-empty info dict is treated as authoritative even if we extract
    /// no keys — overriding it would misrepresent the user's active player.
    static func nowPlaying(completion: @escaping ([String: Any]?) -> Void) {
        guard let fn = MediaRemote.getNowPlayingInfo else {
            // Match the success path's queue: MediaRemote's callback fires
            // completion(out) on the global utility queue. Without this hop
            // the bail path would fire inline, which Bridge.respond would
            // immediately re-enter — also a re-entrancy hazard if a stack
            // chains calls. Same shape as the Vision.runRequest fix.
            DispatchQueue.global(qos: .utility).async { completion(scriptedFallback()) }
            return
        }
        fn(.global(qos: .utility)) { info in
            // info.isEmpty is the structural "no broadcaster" signal — only
            // then do we try the per-app fallback. Otherwise MediaRemote is
            // authoritative about WHO the active player is, even if we don't
            // extract any of the keys it ships (ads, livestreams, podcasts
            // with only Timestamp/MediaType/UniqueIdentifier fields).
            if info.isEmpty {
                completion(scriptedFallback())
                return
            }
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
            completion(out.isEmpty ? nil : out)
        }
    }

    @discardableResult
    static func command(_ name: String) -> Bool {
        // Map our command names to Spotify's distinct AppleScript verbs so
        // play/pause aren't flattened into a toggle. MediaRemote routes the
        // same intents through a single sendCommand call; Spotify's
        // AppleScript dictionary keeps them separate.
        let spotifyVerb: String? = {
            switch name {
            case "toggle":   return "playpause"
            case "play":     return "play"
            case "pause":    return "pause"
            case "next":     return "next track"
            case "previous": return "previous track"
            default:         return nil
            }
        }()
        // Prefer osascript when Spotify is the only relevant broadcaster.
        // MRMediaRemoteSendCommand reports "framework accepted the dispatch",
        // not "player responded" — on Tahoe it accepts-and-drops Spotify
        // commands silently, so trusting its true return would defeat the
        // whole fallback. When Music IS running we let MediaRemote decide
        // (Music registers correctly).
        if let verb = spotifyVerb, isAppRunning("com.spotify.client"), !isAppRunning("com.apple.Music") {
            return runSpotifyCommand(verb)
        }
        if let fn = MediaRemote.sendCommand, let cmd = MediaRemote.commands[name] {
            if fn(cmd, nil) { return true }
        }
        // MediaRemote rejected (or unloadable). Last-resort fallback to
        // Spotify if it's running and we have a verb mapping.
        if let verb = spotifyVerb, isAppRunning("com.spotify.client") {
            return runSpotifyCommand(verb)
        }
        return false
    }

    private static func runSpotifyCommand(_ verb: String) -> Bool {
        // Inline `is running` check closes the TOCTOU between
        // NSWorkspace.runningApplications and Process.run — bare
        // `tell application id "X"` would launch X if it quit in the gap.
        // Returning the literal "ok" lets us distinguish success from
        // "Spotify quit between checks" without trusting termination status
        // (osascript exits 0 even when the inner `tell` did nothing).
        let script = """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client" to \(verb)
            return "ok"
        end if
        return ""
        """
        let r = runOsascript(script)
        return r.success && r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    // MARK: - per-app osascript fallback (Spotify, etc.)

    /// Per-app osascript producers, tried in order. First running app wins.
    /// Add to this list when we discover another broadcaster that doesn't
    /// register with MediaRemote on a given macOS release.
    ///
    /// Wire format (one tab-separated row): title \t artist \t album \t
    /// duration \t elapsed \t playState. parseScriptedResult tolerates fewer
    /// fields and unknown trailing fields.
    private static let scriptedSources: [(bundleId: String, script: String)] = [
        ("com.spotify.client", """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client"
                if player state is not stopped then
                    set t to name of current track
                    set a to artist of current track
                    set b to album of current track
                    set d to duration of current track
                    set p to player position
                    set s to (player state as string)
                    return t & "\t" & a & "\t" & b & "\t" & d & "\t" & p & "\t" & s
                end if
            end tell
        end if
        return ""
        """),
    ]

    // Coalesce rapid fallback invocations. Spotify state-change notifications
    // can fire 2-3 times in <500ms (ad transitions); without a short-TTL
    // cache each would spawn its own blocking osascript on the utility queue.
    // 300ms collapses bursts into a single exec while still surfacing real
    // state changes within one media-channel push tick.
    private static let scriptQueue = DispatchQueue(label: "stackd.media.script", qos: .utility)
    private static var cachedFallback: (timestamp: TimeInterval, value: [String: Any]?) = (0, nil)
    private static let cacheTTL: TimeInterval = 0.3

    private static func scriptedFallback() -> [String: Any]? {
        return scriptQueue.sync {
            let now = ProcessInfo.processInfo.systemUptime
            if now - cachedFallback.timestamp < cacheTTL { return cachedFallback.value }
            var result: [String: Any]?
            for source in scriptedSources {
                guard isAppRunning(source.bundleId) else { continue }
                let r = runOsascript(source.script)
                guard r.success else { continue }
                if let parsed = parseScriptedResult(r.output, bundleId: source.bundleId) {
                    result = parsed
                    break
                }
            }
            cachedFallback = (now, result)
            return result
        }
    }

    /// Pure parser for the tab-separated osascript result. Internal so
    /// AudioTests can exercise it without spawning osascript or assuming
    /// any specific app is running.
    internal static func parseScriptedResult(_ raw: String, bundleId: String) -> [String: Any]? {
        // Trim only newlines (not all whitespace) so a leading tab — which
        // signals "blank title" — survives into the split. Tabs ARE in
        // .whitespacesAndNewlines, so trimming with that set would collapse
        // "\tArtist\t..." into "Artist\t..." and silently promote Artist
        // into the title position.
        let trimmed = raw.trimmingCharacters(in: .newlines)
        if trimmed.isEmpty { return nil }
        let parts = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        // Reject leading-empty (or whitespace-only) title — happens when
        // Spotify returned a row but the title field was blank, e.g.
        // "\tArtist\tAlbum\t...". Otherwise we'd emit a track with no name.
        guard !parts.isEmpty, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var out: [String: Any] = ["title": parts[0]]
        // Per-field trim catches the whitespace-only metadata case ("   "
        // for blank artist/album) that the bar's `m.artist ? "X · " + m.artist
        // : "X"` ternary would otherwise render as "Song ·    ·    ".
        if parts.count > 1, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty { out["artist"] = parts[1] }
        if parts.count > 2, !parts[2].trimmingCharacters(in: .whitespaces).isEmpty { out["album"]  = parts[2] }
        // Spotify's duration is in milliseconds, position in seconds. Other
        // apps may differ; normalize as we add them.
        if bundleId == "com.spotify.client" {
            if parts.count > 3, let d = Double(parts[3]) { out["duration"] = d / 1000.0 }
            if parts.count > 4, let p = Double(parts[4]) { out["elapsed"]  = p }
        }
        // Optional player state — present when the script emits a 6th field.
        // Without it, default to playing=true (the legacy script only emitted
        // when player state was "playing", so any output meant playing).
        if parts.count > 5 {
            let s = parts[5].trimmingCharacters(in: .whitespaces).lowercased()
            out["playing"] = (s == "playing")
        } else {
            out["playing"] = true
        }
        return out
    }

    private static func isAppRunning(_ bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    /// Spawns osascript with stderr routed to /dev/null and stdout drained
    /// after waitUntilExit. Returns (stdout, success). stderr must NOT be
    /// a Pipe() — an undrained pipe whose ~16-64KB kernel buffer fills (TCC
    /// denial messages, AppleScript syntax errors, deprecation warnings)
    /// blocks osascript on write and hangs waitUntilExit forever. Classic
    /// Process footgun.
    private static func runOsascript(_ script: String) -> (output: String, success: Bool) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output, task.terminationStatus == 0)
        } catch {
            return ("", false)
        }
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
        _ = MediaObserver.registerOnce
        let nc = NotificationCenter.default
        let dn = DistributedNotificationCenter.default()
        // The Spotify DN is registered with object: "com.spotify.client" so
        // unrelated local processes can't spoof the notification name and
        // trigger osascript fork-storms. Goes through a direct dn.addObserver
        // call (not installNotifications) because the helper hardcodes
        // object: nil.
        let mrToken = installNotifications([
            (nc, NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")),
            (nc, NSNotification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")),
            (nc, NSNotification.Name("kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"))
        ])
        let dnToken = dn.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: "com.spotify.client",
            queue: .main
        ) { [weak self] _ in self?.fire() }
        return Token {
            mrToken.cancel()
            dn.removeObserver(dnToken)
        }
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
