import Foundation

// Shared dlopen handle for /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight.
//
// SkyLight (the modern WindowServer/CG infrastructure framework) is consumed
// by multiple stackd domains:
//   - Menubar.swift: CGSSetMenuBarVisibility for sd.menubar.suppress
//   - Spaces.swift:  SLSMainConnectionID + SLSCopyManagedDisplaySpaces +
//                    SLSGetActiveSpace + SLSSpaceGetType + SLSCopySpacesForWindows
//   - (future)       hotcorners, per-window-id work, dock peeking, etc.
//
// One file owns the handle. Each consumer declares its own typed symbols via
// `SkyLight.sym("…")` so the symbol surface stays domain-local. dlsym misses
// degrade gracefully (the typed `T?` returns nil; consumers no-op).
//
// Located under Sources/Private/ (sibling to DataSources) to signal "shared
// infrastructure, not a data source." Same pattern would fit a future shared
// MediaRemote.swift / DisplayServices.swift if a second consumer appears.
enum SkyLight {
    static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    /// Type-coerced dlsym. Pattern:
    ///   typealias FooFn = @convention(c) (Int32) -> Void
    ///   static let foo: FooFn? = SkyLight.sym("CGSFoo")
    static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }
}
