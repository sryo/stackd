import CoreGraphics
import Foundation
import IOKit

// MARK: - DisplayDDC
//
// External-display brightness via DDC/CI on Apple Silicon. The internal
// display routes through CoreDisplay/DisplayServices (see Display.swift).
// External monitors don't expose that path — instead we have to send
// VESA MCCS commands over I²C using IOAVServiceWriteI2C, a private SPI
// from /System/Library/PrivateFrameworks/IOAVService.framework.
//
// v1 cuts:
//   - Brightness only (VCP 0x10). Contrast (0x12), volume (0x62), input
//     source (0x60) are out of scope. The 6-byte payload shape is the
//     same; future VCP codes just swap byte index 2.
//   - 0..100 percent scale. Some monitors report a larger max via the
//     capabilities string (VCP 0xF1 + reply parsing) — we don't fetch it.
//     Most consumer monitors use 0..100 natively, so this matches the
//     OSD slider 1:1 on the common case.
//   - Arm64 only. The Intel I²C path goes through IOFramebuffer SPI
//     and is shaped differently enough to warrant a separate file when
//     Intel support comes back.
//
// Reference: VESA MCCS spec (public) for the VCP byte layout. The macOS
// IOAVService call shape is documented in MonitorControl's Arm64DDC.swift
// (LGPL-3.0); we clean-room the wire encoding from the VESA spec and
// resolve IOAVService symbols via dlopen — no source copied.
//
// Wire format for a brightness write (VESA MCCS over DDC/CI):
//   IOAVServiceWriteI2C(svc, addr=0x37, subaddr=0x51, buf, 6)
//   buf = [ 0x84, 0x03, 0x10, hi, lo, chk ]
//          │     │     │     │   │   └── XOR checksum mixing dest addr
//          │     │     │     └───┴────── 16-bit value (MSB first)
//          │     │     └──────────────── VCP code (0x10 = brightness)
//          │     └────────────────────── opcode (0x03 = set VCP feature)
//          └──────────────────────────── length (0x80 | 4 = 0x84)
//
//   Checksum = (0x37 << 1) XOR 0x51 XOR every payload byte.
//
// Read reply (11 bytes):
//   [ src=0x6E, len=0x88, op=0x02, result, vcp, type,
//     maxHi, maxLo, curHi, curLo, chk ]
//   We extract `(curHi << 8) | curLo`. Result byte 0 = OK; anything else
//   means the monitor refused the read (e.g. doesn't support VCP-read
//   for this code — fairly common).

enum DisplayDDC {

    // 7-bit I²C destination address for DDC/CI.
    static let i2cAddress: UInt8 = 0x37
    // Subaddress that identifies a host-originated VESA command.
    static let i2cSubAddress: UInt8 = 0x51
    // Source address byte that goes into the checksum (host = 0x51).
    static let hostAddress: UInt8 = 0x51
    // VCP feature code for brightness (luminance).
    static let vcpBrightness: UInt8 = 0x10

    // MARK: - Pure helpers (tested)

    /// VESA-style XOR checksum: destination 8-bit address mixed with every
    /// payload byte. Pure — sole reason it's `internal` rather than
    /// `private` is so DisplayDDCTests can hammer it directly.
    static func checksum(destinationAddress: UInt8, bytes: [UInt8]) -> UInt8 {
        var c: UInt8 = destinationAddress
        for b in bytes { c ^= b }
        return c
    }

    /// Builds the 6-byte payload for a brightness-set VCP command, clamped
    /// to the 0..100 range. The host address (0x51) goes into the checksum
    /// XOR but is NOT included in the returned buffer — it's the IOAV
    /// `subaddr` parameter at the call site.
    static func encodeBrightnessSet(percent: Int) -> [UInt8] {
        let clamped = max(0, min(100, percent))
        let value = UInt16(clamped)
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        let length: UInt8 = 0x84      // 0x80 | 4 data bytes
        let opcode: UInt8 = 0x03      // set VCP feature
        let dataBytes: [UInt8] = [length, opcode, vcpBrightness, hi, lo]
        let dest = i2cAddress << 1    // 7-bit addr promoted to 8-bit destination
        // Checksum mixes (dest XOR host) XOR payload — same as
        // `checksum(dest, [host] + dataBytes)`. Inlined to keep the helper
        // signature minimal.
        let chk = checksum(destinationAddress: dest, bytes: [hostAddress] + dataBytes)
        return dataBytes + [chk]
    }

    /// Builds the 4-byte payload for a brightness-get VCP command.
    /// Layout matches the set path but with opcode 0x01 (get VCP feature),
    /// length 0x82 (0x80 | 2), and no value bytes.
    static func encodeBrightnessRead() -> [UInt8] {
        let length: UInt8 = 0x82
        let opcode: UInt8 = 0x01      // get VCP feature
        let dataBytes: [UInt8] = [length, opcode, vcpBrightness]
        let dest = i2cAddress << 1
        let chk = checksum(destinationAddress: dest, bytes: [hostAddress] + dataBytes)
        return dataBytes + [chk]
    }

    /// Decodes the 16-bit current-value field from an 11-byte VCP-read
    /// reply. Returns nil when the reply is too short, has the wrong
    /// opcode, or has a non-zero result code (monitor refused the read).
    static func parseBrightnessReply(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 11 else { return nil }
        // bytes[0] is source address, bytes[1] is length. We don't verify
        // checksum at byte[10] — some monitors return a slightly malformed
        // tail and the data we care about (8..9) is already through.
        guard bytes[2] == 0x02 else { return nil }   // op must be VCP reply
        guard bytes[3] == 0x00 else { return nil }   // result code 0 = OK
        let curHi = UInt16(bytes[8])
        let curLo = UInt16(bytes[9])
        return Int((curHi << 8) | curLo)
    }

    // MARK: - Live DDC I/O (impure)

    /// Pushes a brightness value to an external display. Returns false
    /// when IOAVService isn't loadable, no AVService matches the display,
    /// or the I²C write fails. The internal display NEVER reaches this
    /// path — Display.setBrightness routes it through DisplayServices.
    @discardableResult
    static func setBrightness(displayID: CGDirectDisplayID, percent: Int) -> Bool {
        guard let svc = serviceMatching(displayID: displayID) else { return false }
        guard let write = IOAVServiceShim.writeI2C else { return false }
        var payload = encodeBrightnessSet(percent: percent)
        // Capture count outside the closure to avoid Swift's exclusive-
        // access ban (the array is `inout`-accessed by withUnsafeMutable
        // pointer, so any other read inside the body is a conflict).
        let n = UInt32(payload.count)
        return payload.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return write(svc, UInt32(i2cAddress), UInt32(i2cSubAddress), base, n) == kIOReturnSuccess
        }
    }

    /// Reads the current brightness back from the monitor. Returns nil on
    /// any failure — DDC reads are fragile (many monitors implement the
    /// write side of VCP but stub the read side) and the JS layer surfaces
    /// nil as `null` so callers can fall back to a cached/optimistic value.
    static func getBrightness(displayID: CGDirectDisplayID) -> Int? {
        guard let svc = serviceMatching(displayID: displayID) else { return nil }
        guard let write = IOAVServiceShim.writeI2C,
              let read  = IOAVServiceShim.readI2C else { return nil }

        var req = encodeBrightnessRead()
        let reqLen = UInt32(req.count)
        let writeOK = req.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return write(svc, UInt32(i2cAddress), UInt32(i2cSubAddress), base, reqLen) == kIOReturnSuccess
        }
        guard writeOK else { return nil }

        // Brief settle delay — most monitors need ~40-50ms before the
        // reply latches into the I²C bus. Synchronous because the JS
        // request path is already off the main thread (Bridge.sync runs
        // on a workqueue).
        Thread.sleep(forTimeInterval: 0.05)

        var reply = [UInt8](repeating: 0, count: 11)
        let replyLen = UInt32(reply.count)
        let readOK = reply.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return read(svc, UInt32(i2cAddress), UInt32(i2cSubAddress), base, replyLen) == kIOReturnSuccess
        }
        guard readOK else { return nil }
        return parseBrightnessReply(reply)
    }

    // MARK: - IOAVService lookup
    //
    // The translation from CGDirectDisplayID → IOAVService is the part
    // that varies most across MonitorControl versions and macOS releases
    // — IOReg layout has shifted between Ventura and Sequoia. v1 takes
    // the pragmatic shortcut: walk the IOReg `IOAVService` class plane
    // and return the first non-builtin entry. Most multi-monitor setups
    // only have one external display, so first-match is correct in
    // practice. Per-display matching (via EDID UUID) is a v2 expansion.

    private static let serviceCache = NSCache<NSNumber, AVServiceBox>()

    private static func serviceMatching(displayID: CGDirectDisplayID) -> IOAVService? {
        // Internal display has no AVService — bail early so the cache
        // doesn't fill with nil entries.
        if CGDisplayIsBuiltin(displayID) != 0 { return nil }

        let key = NSNumber(value: UInt32(displayID))
        if let cached = serviceCache.object(forKey: key) { return cached.svc }

        guard let create = IOAVServiceShim.createWithService else { return nil }

        // Match anything that registers as an IOAVService. The framework
        // is responsible for filtering to entries that actually expose
        // I²C; on M-series the DCP graphics driver registers one per
        // external port.
        let matching = IOServiceMatching("IOAVService")
        var iterator: io_iterator_t = 0
        let r = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard r == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            // Skip the builtin AVService — it serves the laptop's internal
            // panel and doesn't accept brightness over I²C anyway. The
            // "Location" registry property reads back as "Embedded" for the
            // internal panel and "External" for everything else.
            let locProp = IORegistryEntryCreateCFProperty(
                entry, "Location" as CFString, kCFAllocatorDefault, 0)
            if let loc = locProp?.takeRetainedValue() as? String, loc == "Embedded" {
                IOObjectRelease(entry)
                continue
            }
            if let svc = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                IOObjectRelease(entry)
                serviceCache.setObject(AVServiceBox(svc), forKey: key)
                return svc
            }
            IOObjectRelease(entry)
        }
        return nil
    }

    /// NSCache requires a class-typed value. Wrap the opaque IOAVService
    /// (typed as a CF object via dlsym) so we can keep one entry per
    /// CGDirectDisplayID without re-walking IOReg on every brightness
    /// change.
    private final class AVServiceBox {
        let svc: IOAVService
        init(_ s: IOAVService) { svc = s }
    }
}

// MARK: - IOAVService SPI shim
//
// IOAVService lives at /System/Library/PrivateFrameworks/IOAVService.framework
// with no public header. Symbols resolved at process start; missing-symbol
// returns nil getters so external-display brightness gracefully degrades
// to "no-op + false return" instead of crashing the daemon.
//
// Mirrors the dlopen+dlsym pattern from Sources/Private/SkyLight.swift and
// DisplayServicesShim in Display.swift. Kept alongside the consumer (this
// file) rather than under Sources/Private/ because there's exactly one
// consumer; promotes to /Private if a second use site appears.

/// IOAVService is an opaque CoreFoundation-style object handed back by
/// IOAVServiceCreateWithService. We type it as AnyObject so the dlsym
/// signature stays simple; the framework manages its own retain count.
typealias IOAVService = AnyObject

enum IOAVServiceShim {
    typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<IOAVService>?
    typealias WriteI2CFn = @convention(c) (
        IOAVService, UInt32, UInt32,
        UnsafeMutablePointer<UInt8>, UInt32
    ) -> Int32
    typealias ReadI2CFn = @convention(c) (
        IOAVService, UInt32, UInt32,
        UnsafeMutablePointer<UInt8>, UInt32
    ) -> Int32

    static let handle: UnsafeMutableRawPointer? = {
        dlopen(
            "/System/Library/PrivateFrameworks/IOAVService.framework/IOAVService",
            RTLD_LAZY
        )
    }()

    static let createWithService: CreateWithServiceFn? = {
        guard let h = handle, let s = dlsym(h, "IOAVServiceCreateWithService") else { return nil }
        return unsafeBitCast(s, to: CreateWithServiceFn.self)
    }()

    static let writeI2C: WriteI2CFn? = {
        guard let h = handle, let s = dlsym(h, "IOAVServiceWriteI2C") else { return nil }
        return unsafeBitCast(s, to: WriteI2CFn.self)
    }()

    static let readI2C: ReadI2CFn? = {
        guard let h = handle, let s = dlsym(h, "IOAVServiceReadI2C") else { return nil }
        return unsafeBitCast(s, to: ReadI2CFn.self)
    }()
}
