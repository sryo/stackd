import Foundation
import AVFoundation

// Tests for the text-to-speech surface of Speech.swift.
//
// Out of scope by design:
//   - speak(text: "hello", ...) — would actually vocalize through the
//     user's speakers. The clamp logic (rate 0..1, pitch 0.5..2.0,
//     volume 0..1) and voice-identifier resolution both live INSIDE
//     speak(), so they can't be exercised through the public API
//     without producing audio. Left uncovered intentionally.
//   - genderName / qualityName — private switches; covered indirectly
//     through voices() dict shape.
//
// In scope:
//   - speak() empty-text guard returns false BEFORE the synth is
//     touched (no audio leaks into the test run).
//   - stop(boundary:) — AVSpeechBoundary string mapping. Safe to call
//     with no utterance queued (returns false, but exercises the
//     "immediate" / "word" / default branches).
//   - voices() — dict shape contract that JS consumers depend on:
//     key presence, value types, gender ∈ {male, female, unspecified},
//     quality ∈ {default, enhanced, premium}. Magnitudes vary per Mac
//     (downloaded voices etc) so we never assert specific identifiers
//     or counts beyond non-empty.

func registerSpeechTTSTests() {
    // MARK: - speak() empty-text guard

    test("speak empty text returns false without invoking synth") {
        try expectEqual(Speech.speak(text: ""), false)
    }

    // MARK: - stop() boundary string mapping

    test("stop default boundary is callable and returns Bool") {
        // No utterance queued — return value is whatever AVSpeechSynthesizer
        // reports for "nothing to stop" (false). Asserting only that the
        // call doesn't trap and the boundary string parses.
        let _ = Speech.stop()
    }

    test("stop with boundary=word is callable") {
        let _ = Speech.stop(boundary: "word")
    }

    test("stop with boundary=immediate is callable") {
        let _ = Speech.stop(boundary: "immediate")
    }

    test("stop with unknown boundary falls back to immediate") {
        // Any non-"word" string maps to .immediate per the impl —
        // doesn't trap, doesn't error.
        let _ = Speech.stop(boundary: "garbage-string")
    }

    // MARK: - voices() dict shape contract

    test("voices returns non-empty list on macOS") {
        let vs = Speech.voices()
        try expect(!vs.isEmpty, "expected at least one system voice")
    }

    test("voices each entry has identifier/name/language/gender/quality keys") {
        let vs = Speech.voices()
        guard let first = vs.first else { return }
        try expect(first["identifier"] is String)
        try expect(first["name"]       is String)
        try expect(first["language"]   is String)
        try expect(first["gender"]     is String)
        try expect(first["quality"]    is String)
    }

    test("voices identifier and language are non-empty strings") {
        let vs = Speech.voices()
        guard let first = vs.first else { return }
        let id   = first["identifier"] as? String ?? ""
        let lang = first["language"]   as? String ?? ""
        try expect(!id.isEmpty,   "identifier should be non-empty")
        try expect(!lang.isEmpty, "language should be non-empty")
    }

    test("voices gender values are male/female/unspecified") {
        let allowed: Set<String> = ["male", "female", "unspecified"]
        for v in Speech.voices() {
            let g = v["gender"] as? String ?? ""
            try expect(allowed.contains(g), "unexpected gender: \(g)")
        }
    }

    test("voices quality values are default/enhanced/premium") {
        let allowed: Set<String> = ["default", "enhanced", "premium"]
        for v in Speech.voices() {
            let q = v["quality"] as? String ?? ""
            try expect(allowed.contains(q), "unexpected quality: \(q)")
        }
    }
}
