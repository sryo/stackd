import Foundation

// Tests for the pure helpers behind sd.speech.listen. The
// SFSpeechRecognizer + AVAudioEngine plumbing can't run in isolation
// (mic TCC + audio device, asynchronous task callbacks) — same shape as
// CalendarTests covering describe() helpers while leaving the EventKit
// query untouched.
//
// Surface tested here:
//   Speech.resolveLocale(_:)        — string → Locale w/ fallback
//   Speech.shapeSegment(...)        — per-segment dict for the JS payload
//   Speech.shapeResult(...)         — whole-result envelope sent to JS

func registerSpeechSTTTests() {
    test("resolveLocale nil falls back to current locale") {
        let l = Speech.resolveLocale(nil)
        try expectEqual(l.identifier, Locale.current.identifier)
    }

    test("resolveLocale empty string falls back to current locale") {
        let l = Speech.resolveLocale("")
        try expectEqual(l.identifier, Locale.current.identifier)
    }

    test("resolveLocale valid BCP-47 returns matching Locale") {
        let l = Speech.resolveLocale("en-US")
        try expectEqual(l.identifier, "en-US")
    }

    test("resolveLocale non-English BCP-47 round-trips identifier") {
        let l = Speech.resolveLocale("fr-FR")
        try expectEqual(l.identifier, "fr-FR")
    }

    test("shapeSegment exposes substring/range/confidence in JS shape") {
        let seg = Speech.shapeSegment(substring: "hello", start: 0, length: 5, confidence: 0.92)
        try expectEqual(seg["substring"] as? String, "hello")
        try expectEqual(seg["start"]     as? Int,    0)
        try expectEqual(seg["length"]    as? Int,    5)
        // Float → Double on the JSON-able side; compare with a tolerance.
        let conf = seg["confidence"] as? Double ?? 0
        try expect(abs(conf - 0.92) < 0.001)
    }

    test("shapeResult builds {text, isFinal, segments} envelope") {
        let segs = [
            Speech.shapeSegment(substring: "hello", start: 0, length: 5, confidence: 0.9),
            Speech.shapeSegment(substring: "world", start: 6, length: 5, confidence: 0.8)
        ]
        let env = Speech.shapeResult(text: "hello world", isFinal: true, segments: segs)
        try expectEqual(env["text"]    as? String, "hello world")
        try expectEqual(env["isFinal"] as? Bool,   true)
        let outSegs = env["segments"] as? [[String: Any]] ?? []
        try expectEqual(outSegs.count, 2)
        try expectEqual(outSegs[0]["substring"] as? String, "hello")
        try expectEqual(outSegs[1]["substring"] as? String, "world")
    }

    test("shapeResult partial result carries isFinal=false") {
        let env = Speech.shapeResult(text: "hel", isFinal: false, segments: [])
        try expectEqual(env["isFinal"] as? Bool, false)
        try expectEqual(env["text"]    as? String, "hel")
    }
}
