import AppKit
import AudioToolbox
import CoreAudio
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
        guard let fn = MediaRemote.getNowPlayingInfo else { completion(nil); return }
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
