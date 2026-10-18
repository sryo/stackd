import Foundation
import AudioToolbox
import CoreAudio

// Tests for the default-device observers in Audio.swift. A recording
// AudioListenerHost stands in for CoreAudio so the add/remove pairing —
// CoreAudio compares listener blocks by identity, so every remove must hand
// back the exact block its add registered — is checked without touching real
// devices or listener registrations.

/// A Swift closure value's identity is its (function pointer, context) pair.
/// It cannot tell apart two closures with identical bodies created in the same
/// scope (the volume and mute blocks), but it does catch a remove that hands
/// CoreAudio a different closure than the add registered.
private struct BlockIdentity: Equatable {
    let function: UnsafeRawPointer?
    let context: UnsafeRawPointer?

    init(_ block: @escaping AudioObjectPropertyListenerBlock) {
        (function, context) = unsafeBitCast(block, to: (UnsafeRawPointer?, UnsafeRawPointer?).self)
    }
}

private final class RecordingHost {
    struct Call {
        let isAdd: Bool
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
        var identity: BlockIdentity { BlockIdentity(block) }
    }

    var calls: [Call] = []
    var defaults: [Audio.Scope: AudioDeviceID] = [:]

    var host: AudioListenerHost {
        AudioListenerHost(
            defaultDevice: { [unowned self] scope in self.defaults[scope] },
            add: { [unowned self] object, address, _, block in
                self.calls.append(Call(isAdd: true, object: object, address: address, block: block))
            },
            remove: { [unowned self] object, address, _, block in
                self.calls.append(Call(isAdd: false, object: object, address: address, block: block))
            }
        )
    }

    var adds:    [Call] { calls.filter { $0.isAdd } }
    var removes: [Call] { calls.filter { !$0.isAdd } }

    /// Invoke the most recent block registered on `object` for `selector`,
    /// the way CoreAudio's listener queue would.
    func fireListener(on object: AudioObjectID, selector: AudioObjectPropertySelector) {
        guard let call = adds.last(where: { $0.object == object && $0.address.mSelector == selector }) else { return }
        var addr = call.address
        call.block(object, &addr)
    }
}

private let systemObject = AudioObjectID(kAudioObjectSystemObject)

private func sameRegistration(_ a: RecordingHost.Call, _ b: RecordingHost.Call) -> Bool {
    a.object == b.object
        && a.address.mSelector == b.address.mSelector
        && a.address.mScope == b.address.mScope
        && a.address.mElement == b.address.mElement
        && a.identity == b.identity
}

private func spinMain(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

func registerAudioObserverTests() {
    test("AudioObserver: install listens for default-device changes plus volume and mute on the current device, per scope") {
        for scope in [Audio.Scope.output, .input] {
            let rec = RecordingHost()
            rec.defaults[scope] = 42
            let obs = AudioObserver(scope: scope, host: rec.host)
            let token = obs.install()!
            defer { withExtendedLifetime(obs) { token.cancel() } }

            try expectEqual(rec.adds.count, 3, "\(scope): device-change + volume + mute")
            let dev = rec.adds[0]
            try expectEqual(dev.object, systemObject)
            try expectEqual(dev.address.mSelector, scope.defaultDeviceSelector)
            try expectEqual(dev.address.mScope, kAudioObjectPropertyScopeGlobal)
            try expectEqual(dev.address.mElement, kAudioObjectPropertyElementMain)

            let vol = rec.adds[1], mute = rec.adds[2]
            try expectEqual(vol.object, 42)
            try expectEqual(vol.address.mSelector, Audio.volumeAddress(scope: scope).mSelector)
            try expectEqual(vol.address.mScope, scope.coreAudioScope)
            try expectEqual(mute.object, 42)
            try expectEqual(mute.address.mSelector, Audio.muteAddress(scope: scope).mSelector)
            try expectEqual(mute.address.mScope, scope.coreAudioScope)
        }
    }

    test("AudioObserver: with no default device only the device-change listener is registered") {
        let rec = RecordingHost()
        let obs = AudioObserver(scope: .input, host: rec.host)
        let token = obs.install()!
        defer { withExtendedLifetime(obs) { token.cancel() } }

        try expectEqual(rec.adds.count, 1)
        try expectEqual(rec.adds[0].object, systemObject)
        try expectEqual(rec.adds[0].address.mSelector, kAudioHardwarePropertyDefaultInputDevice)
    }

    test("AudioObserver: cancel removes every registration with the exact block it was added with") {
        let rec = RecordingHost()
        rec.defaults[.output] = 7
        let obs = AudioObserver(scope: .output, host: rec.host)
        let token = obs.install()!
        withExtendedLifetime(obs) { token.cancel() }

        try expectEqual(rec.removes.count, rec.adds.count, "every add is balanced by a remove")
        for add in rec.adds {
            try expect(rec.removes.contains { sameRegistration($0, add) },
                       "no remove carries the same block + address as the add for selector \(add.address.mSelector)")
        }
    }

    test("AudioObserver: a default-device change drops the old device's listeners by block identity and binds the new device") {
        let rec = RecordingHost()
        rec.defaults[.output] = 11
        let obs = AudioObserver(scope: .output, host: rec.host)
        let token = obs.install()!
        defer { withExtendedLifetime(obs) { token.cancel() } }

        let boundToOld = rec.adds.filter { $0.object == 11 }
        try expectEqual(boundToOld.count, 2)

        rec.defaults[.output] = 12
        rec.fireListener(on: systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice)

        let oldRemoved = rec.removes.filter { $0.object == 11 }
        try expectEqual(oldRemoved.count, 2)
        for add in boundToOld {
            try expect(oldRemoved.contains { sameRegistration($0, add) },
                       "old device's remove must reuse the add's block")
        }
        try expectEqual(rec.adds.filter { $0.object == 12 }.count, 2, "volume + mute bound to the new device")
    }

    test("AudioObserver: volume and mute listener callbacks notify subscribers on the main queue") {
        let rec = RecordingHost()
        rec.defaults[.input] = 9
        let obs = AudioObserver(scope: .input, host: rec.host)
        var fires = 0
        let token = obs.subscribe { fires += 1 }
        defer { token.cancel() }
        try expectEqual(fires, 1, "subscribe primes immediately")

        rec.fireListener(on: 9, selector: Audio.volumeAddress(scope: .input).mSelector)
        spinMain(0.05)
        try expectEqual(fires, 2)

        rec.fireListener(on: 9, selector: Audio.muteAddress(scope: .input).mSelector)
        spinMain(0.05)
        try expectEqual(fires, 3)
    }

    test("AudioObserver: shared instances are bound to their direction") {
        try expectEqual(AudioObserver.shared.scope, .output)
        try expectEqual(AudioInputObserver.shared.scope, .input)
        try expect(AudioObserver.shared !== AudioInputObserver.shared, "input and output keep independent listener state")
    }
}
