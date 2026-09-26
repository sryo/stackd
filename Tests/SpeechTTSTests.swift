import Foundation
import AVFoundation

// Tests for the text-to-speech surface of Speech.swift.
//
// Out of scope by design:
//   - speak() with real text — would vocalize through the user's speakers.
//     The rate/pitch/volume clamps and voice-identifier resolution live
//     inside speak(), so they stay untested.
//   - stop(boundary:) — the "word" / "immediate" mapping is only observable
//     while an utterance is playing.
//
// In scope:
//   - speak() empty-text guard returns false before the synth is touched.
//   - voices() dict shape that JS consumers depend on. The voice list varies
//     per Mac (downloaded voices), so no identifiers or counts are pinned.

func registerSpeechTTSTests() {
    test("speak empty text returns false without invoking synth") {
        try expectEqual(Speech.speak(text: ""), false)
    }

    test("voices returns non-empty list on macOS") {
        try expect(!Speech.voices().isEmpty, "expected at least one system voice")
    }

    test("voices entries carry non-empty identifier/language, a name, and known gender/quality") {
        let genders: Set<String>   = ["male", "female", "unspecified"]
        let qualities: Set<String> = ["default", "enhanced", "premium"]
        for v in Speech.voices() {
            let id = v["identifier"] as? String ?? ""
            try expect(!id.isEmpty, "identifier should be a non-empty String")
            try expect(!(v["language"] as? String ?? "").isEmpty, "language should be non-empty for \(id)")
            try expect(v["name"] is String, "name should be a String for \(id)")
            let g = v["gender"] as? String ?? ""
            try expect(genders.contains(g), "unexpected gender '\(g)' for \(id)")
            let q = v["quality"] as? String ?? ""
            try expect(qualities.contains(q), "unexpected quality '\(q)' for \(id)")
        }
    }
}
