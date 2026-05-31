import DiskArbitration
import Foundation

// Mount / unmount lifecycle + a one-shot snapshot of currently-mounted
// volumes. DiskArbitration is the public-but-rarely-used framework: it
// surfaces "USB drive plugged in," "disk image mounted," "network share
// appeared," "volume ejected" as callbacks scheduled on the main runloop.
//
// Bangs (declared in a stack's `handles` array — no permission needed to
// receive them; the bang fires for every loaded stack that opts in):
//   sd.disk.mounted   — { name, mountPoint, fs?, removable?, ejectable?, size? }
//   sd.disk.unmounted — { mountPoint }  (volume name is gone by the time the
//                                        callback fires; mount point is the
//                                        only stable identifier)
//
// Read primitive:
//   sd.disks.list()   — synchronous snapshot of currently-mounted volumes
//                       in the same shape as the `mounted` bang.

enum Disks {
    /// Snapshot of currently-mounted volumes. Cheap — FileManager walks the
    /// VFS table, no IORegistry traversal needed.
    static func list() -> [[String: Any]] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeTotalCapacityKey, .volumeIsInternalKey,
            .volumeIsBrowsableKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return urls.compactMap { describe(mountPoint: $0) }
    }

    /// Build the dict shape stacks see. Used by both snapshot enumeration and
    /// the DA disk-appeared callback.
    fileprivate static func describe(mountPoint: URL) -> [String: Any]? {
        let vals = try? mountPoint.resourceValues(forKeys: [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeTotalCapacityKey, .volumeIsInternalKey
        ])
        var out: [String: Any] = ["mountPoint": mountPoint.path]
        if let name = vals?.volumeName, !name.isEmpty { out["name"] = name }
        if let fs   = vals?.volumeLocalizedFormatDescription { out["fs"] = fs }
        if let rem  = vals?.volumeIsRemovable { out["removable"] = rem }
        if let ej   = vals?.volumeIsEjectable { out["ejectable"] = ej }
        if let sz   = vals?.volumeTotalCapacity { out["size"] = sz }
        if let intl = vals?.volumeIsInternal  { out["internal"] = intl }
        return out
    }
}

// MARK: - Lifecycle bangs
//
// Install once at startup from AppDelegate. Same lifetime pattern as
// WindowEvents / DisplayHotplug — the DA session lives for the process; the
// host.bang fan-out is a no-op when no stack handles the bang.
//
// DA exposes a `matching` dict on each register call. We pass nil to match
// every disk; consumers filter in JS by reading `mountPoint` / `removable`.

enum DisksHotplug {
    private static var session: DASession?

    static func install() {
        guard session == nil else { return }
        guard let s = DASessionCreate(kCFAllocatorDefault) else {
            log("disks: DASessionCreate failed")
            return
        }
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        DARegisterDiskAppearedCallback(s, nil, diskAppeared, nil)
        DARegisterDiskDisappearedCallback(s, nil, diskDisappeared, nil)
        session = s
    }
}

private let diskAppeared: DADiskAppearedCallback = { disk, _ in
    // DA fires this for every mounted volume on session start too, not just
    // future mounts. That's the right shape — stacks loaded after a USB drive
    // is already plugged in still see it appear. Volumes without a mount
    // point (raw block devices, unmounted partitions) get filtered here.
    guard let desc = DADiskCopyDescription(disk) as? [CFString: Any],
          let url  = desc[kDADiskDescriptionVolumePathKey] as? URL
    else { return }
    DispatchQueue.main.async {
        guard let host = AppDelegate.shared?.host,
              let detail = Disks.describe(mountPoint: url) else { return }
        host.bang(name: "sd.disk.mounted", detail: detail)
    }
}

private let diskDisappeared: DADiskDisappearedCallback = { disk, _ in
    // By the time the callback fires the volume is unmounted — resource-value
    // queries fail, the volume name CFDictionary entry is often missing.
    // mountPoint is the only stable identifier consumers can match on.
    guard let desc = DADiskCopyDescription(disk) as? [CFString: Any],
          let url  = desc[kDADiskDescriptionVolumePathKey] as? URL
    else { return }
    DispatchQueue.main.async {
        AppDelegate.shared?.host?.bang(
            name: "sd.disk.unmounted",
            detail: ["mountPoint": url.path]
        )
    }
}
