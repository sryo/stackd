import Foundation

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

final class MediaObserver {
    static let shared = MediaObserver()
    private var subs: [() -> Void] = []
    private var registered = false

    private init() {
        guard let register = MediaRemote.registerForNotifications else { return }
        register(.main)
        registered = true
        for name in [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"
        ] {
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name),
                object: nil, queue: .main
            ) { [weak self] _ in self?.fire() }
        }
    }

    func subscribe(_ cb: @escaping () -> Void) { subs.append(cb) }
    func unsubscribeAll() { subs.removeAll() }
    private func fire() { for cb in subs { cb() } }
}
