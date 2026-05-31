import Foundation
import IOKit
import IOKit.usb

enum USB {
    /// Snapshot of currently-attached USB devices. Walks the IORegistry every
    /// call — cheap (<1ms even with a dozen devices) and avoids stale caches
    /// when the observer hasn't fired yet (initial Bridge replay).
    static func snapshot() -> [[String: Any]] {
        // kIOUSBDeviceClassName ("IOUSBDevice") is the legacy class — modern
        // macOS (10.11+) publishes devices under "IOUSBHostDevice" instead.
        // IOServiceMatching on the new name covers built-in + plugged devices;
        // the legacy name only finds nothing on Apple Silicon hardware.
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }
        var out: [[String: Any]] = []
        while case let dev = IOIteratorNext(iter), dev != 0 {
            if let entry = USB.describe(device: dev) { out.append(entry) }
            IOObjectRelease(dev)
        }
        return out
    }

    /// Read the standard USB property bag off a single io_object_t.
    /// Vendor/product names + serial are optional — USB hubs and many
    /// internal devices ship without them.
    fileprivate static func describe(device: io_object_t) -> [String: Any]? {
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        guard let vid = prop("idVendor")  as? Int,
              let pid = prop("idProduct") as? Int else { return nil }
        var entry: [String: Any] = [
            "vendorID":  vid,
            "productID": pid
        ]
        if let loc = prop("locationID") as? Int { entry["locationID"] = loc }
        if let n = prop("USB Vendor Name")  as? String, !n.isEmpty { entry["vendorName"]   = n }
        if let n = prop("USB Product Name") as? String, !n.isEmpty { entry["productName"]  = n }
        if let s = prop("USB Serial Number") as? String, !s.isEmpty { entry["serialNumber"] = s }
        return entry
    }
}

final class USBObserver: RefCountedObserver {
    static let shared = USBObserver()
    private override init() { super.init() }

    override func install() -> Token? {
        // IONotificationPort owns the runloop source that delivers add/remove
        // callbacks. One port handles both iterators (publish + terminate).
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            FileHandle.standardError.write(Data("stackd: USBObserver — IONotificationPortCreate failed\n".utf8))
            return nil
        }
        guard let src = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            IONotificationPortDestroy(port)
            FileHandle.standardError.write(Data("stackd: USBObserver — runloop source unavailable\n".utf8))
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        // The matching dict is consumed by IOServiceAddMatchingNotification —
        // we need a fresh one per call. CF retain counts handle the rest.
        let matchPublish = IOServiceMatching("IOUSBHostDevice")
        let matchTerm    = IOServiceMatching("IOUSBHostDevice")

        let cb: IOServiceMatchingCallback = { ptr, iterator in
            guard let ptr = ptr else { return }
            let me = Unmanaged<USBObserver>.fromOpaque(ptr).takeUnretainedValue()
            // Drain the iterator — if we don't pull every io_object_t, IOKit
            // stops delivering further notifications on this iterator (the
            // arming model is "I've shown you everything new; come back when
            // you've consumed it"). Release each object after drain.
            while case let obj = IOIteratorNext(iterator), obj != 0 {
                IOObjectRelease(obj)
            }
            me.fire()
        }

        var publishIter: io_iterator_t = 0
        var termIter:    io_iterator_t = 0
        let kr1 = IOServiceAddMatchingNotification(port, kIOPublishNotification,
                                                   matchPublish, cb, ctx, &publishIter)
        let kr2 = IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                                   matchTerm, cb, ctx, &termIter)
        guard kr1 == KERN_SUCCESS, kr2 == KERN_SUCCESS else {
            if publishIter != 0 { IOObjectRelease(publishIter) }
            if termIter    != 0 { IOObjectRelease(termIter) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            IONotificationPortDestroy(port)
            FileHandle.standardError.write(Data("stackd: USBObserver — IOServiceAddMatchingNotification failed\n".utf8))
            return nil
        }
        // Initial drain arms both iterators. Without this they never fire.
        while case let obj = IOIteratorNext(publishIter), obj != 0 { IOObjectRelease(obj) }
        while case let obj = IOIteratorNext(termIter),    obj != 0 { IOObjectRelease(obj) }

        return Token {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            IOObjectRelease(publishIter)
            IOObjectRelease(termIter)
            IONotificationPortDestroy(port)
        }
    }
}
