import AVFoundation
import Foundation

// Text-to-speech via AVSpeechSynthesizer. Public AVFoundation, no TCC.
//
// STT (SFSpeechRecognizer) is a separate ship — it needs continuous audio
// buffer plumbing through AVAudioEngine, Microphone TCC, and Speech
// Recognition TCC. Adding it later as `sd.speech.listen(opts).subscribe(...)`
// fits the same namespace; the TTS side here is stable and useful alone.
//
// Single shared synthesizer for the process — AVSpeechSynthesizer can queue
// multiple utterances and serialize them across calls, which matches the
// user expectation that two stacks calling `speak()` shouldn't talk over
// each other.

enum Speech {
    private static let synth = AVSpeechSynthesizer()

    /// Speak the given text. `voice` is an Apple voice identifier
    /// (e.g. `com.apple.voice.compact.en-US.Samantha` — list via `voices()`)
    /// or a BCP-47 language code (`en-US`) which picks the system default
    /// voice for that locale. `rate`, `pitch`, `volume` map directly onto
    /// AVSpeechUtterance defaults (rate 0.0..1.0 with 0.5 ≈ natural speech;
    /// pitch 0.5..2.0; volume 0.0..1.0). nil for any of these picks the
    /// AVFoundation default.
    @discardableResult
    static func speak(text: String,
                      voice: String? = nil,
                      rate: Float? = nil,
                      pitch: Float? = nil,
                      volume: Float? = nil) -> Bool {
        guard !text.isEmpty else { return false }
        let utter = AVSpeechUtterance(string: text)
        if let voice = voice {
            if let v = AVSpeechSynthesisVoice(identifier: voice) {
                utter.voice = v
            } else if let v = AVSpeechSynthesisVoice(language: voice) {
                utter.voice = v
            }
        }
        if let rate   = rate   { utter.rate   = max(0, min(1, rate)) }
        if let pitch  = pitch  { utter.pitchMultiplier = max(0.5, min(2.0, pitch)) }
        if let volume = volume { utter.volume = max(0, min(1, volume)) }
        synth.speak(utter)
        return true
    }

    /// Stop any in-progress utterance (and clear the queue). `boundary`
    /// follows AVSpeechBoundary semantics — "immediate" cuts off mid-word,
    /// "word" waits for the current word to finish. Defaults to immediate
    /// because the common case (`sd.speech.stop()` from a UI button) wants
    /// instant silence.
    @discardableResult
    static func stop(boundary: String = "immediate") -> Bool {
        let b: AVSpeechBoundary = (boundary == "word") ? .word : .immediate
        return synth.stopSpeaking(at: b)
    }

    /// Available voices on this Mac. Returns
    ///   [{ identifier, name, language, gender, quality }]
    /// where `quality` is "default" / "enhanced" / "premium" — enhanced and
    /// premium voices give noticeably better prosody but have to be
    /// downloaded in System Settings → Accessibility → Spoken Content.
    static func voices() -> [[String: Any]] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            [
                "identifier": v.identifier,
                "name":       v.name,
                "language":   v.language,
                "gender":     genderName(v.gender),
                "quality":    qualityName(v.quality)
            ]
        }
    }

    private static func genderName(_ g: AVSpeechSynthesisVoiceGender) -> String {
        switch g {
        case .male:    return "male"
        case .female:  return "female"
        case .unspecified: return "unspecified"
        @unknown default:  return "unspecified"
        }
    }

    private static func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .default:  return "default"
        case .enhanced: return "enhanced"
        case .premium:  return "premium"
        @unknown default: return "default"
        }
    }
}
