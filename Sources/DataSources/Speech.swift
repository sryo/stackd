import AVFoundation
import Foundation
import Speech

// Text-to-speech via AVSpeechSynthesizer plus speech-to-text via
// SFSpeechRecognizer + AVAudioEngine. TTS is no-TCC public AVFoundation
// (the engine renders to the local audio device); STT triggers TWO TCC
// prompts on first listen():
//   - Microphone           (NSMicrophoneUsageDescription)
//   - Speech Recognition   (NSSpeechRecognitionUsageDescription)
//
// Both prompts are async. Speech.framework's recognizer is async too — the
// task callback fires multiple times with partial results before the final
// transcription. Listener wraps the inputNode tap + recognizer + task and
// pushes each callback through to JS via the Bridge channel.
//
// Single shared synthesizer for the process (TTS); per-call Listener
// instances for STT (each listen() mints one — they can't share an audio
// engine because the recognizer takes exclusive ownership of the tap on
// inputNode for the lifetime of the request).

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

    // ── STT pure helpers (testable in isolation) ────────────────────────────

    /// BCP-47 string → Locale. Empty / nil falls back to the current locale
    /// (matches the Speech.framework default — SFSpeechRecognizer() with no
    /// argument uses Locale.current). Invalid identifiers still construct a
    /// Locale object (Foundation doesn't validate), so the recognizer init
    /// downstream is responsible for returning nil if the identifier doesn't
    /// resolve to a supported locale.
    static func resolveLocale(_ s: String?) -> Locale {
        guard let s = s, !s.isEmpty else { return Locale.current }
        return Locale(identifier: s)
    }

    /// Per-segment dict for the JS payload — substring + character range +
    /// confidence. Extracted as a pure helper so the test harness can
    /// exercise the shape contract without booting the recognizer.
    static func shapeSegment(substring: String, start: Int, length: Int,
                             confidence: Float) -> [String: Any] {
        return [
            "substring":  substring,
            "start":      start,
            "length":     length,
            "confidence": Double(confidence)
        ]
    }

    /// Whole-result envelope sent through the channel:
    ///   { text, isFinal, segments: [{ substring, start, length, confidence }] }
    /// `isFinal: true` is the last push for that listener and signals JS
    /// that the recognizer has stopped on its own.
    static func shapeResult(text: String, isFinal: Bool,
                            segments: [[String: Any]]) -> [String: Any] {
        return [
            "text":     text,
            "isFinal":  isFinal,
            "segments": segments
        ]
    }

    /// Pull all currently-supported recognizer locales as BCP-47 strings.
    /// Returns the set Apple ships with the OS — does NOT filter to locales
    /// that have on-device support (that's a per-instance flag, exposed at
    /// listen() time via the requireOnDevice option).
    static func availableLocales() -> [String] {
        return SFSpeechRecognizer.supportedLocales()
            .map { $0.identifier }
            .sorted()
    }

    // ── STT live listener ───────────────────────────────────────────────────

    /// One listen() call mints one Listener. Owns:
    ///   - SFSpeechRecognizer (locale-pinned)
    ///   - AVAudioEngine + an installed tap on inputNode (bus 0)
    ///   - SFSpeechAudioBufferRecognitionRequest (fed each tap buffer)
    ///   - SFSpeechRecognitionTask (delivers partials + final via callback)
    ///
    /// Lifecycle: init does the heavy lifting (TCC requests, engine start,
    /// task creation) asynchronously; the onResult / onError / onEnded
    /// closures fire as the recognizer reports. stop() tears the whole
    /// thing down — removes the tap, cancels the task, stops the engine.
    /// Safe to call stop() multiple times; only the first does anything.
    final class Listener {
        private let recognizer: SFSpeechRecognizer?
        private let audioEngine = AVAudioEngine()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var task: SFSpeechRecognitionTask?
        private var stopped = false
        private let onResult: ([String: Any]) -> Void
        private let onError:  (String) -> Void

        /// Build a Listener for `locale` (nil → current). `requireOnDevice`
        /// forces local-only recognition (no audio leaves the device); if
        /// the recognizer doesn't support on-device for the picked locale,
        /// init fails fast via onError("…") and stop().
        init(locale: String?,
             requireOnDevice: Bool,
             onResult: @escaping ([String: Any]) -> Void,
             onError:  @escaping (String) -> Void) {
            self.recognizer = SFSpeechRecognizer(locale: Speech.resolveLocale(locale))
            self.onResult = onResult
            self.onError  = onError
        }

        /// Kick off TCC + engine setup. Async — the Speech / mic permission
        /// requests fan out to system prompts. The recognizer task is
        /// created inside the permission callback so we don't open the
        /// audio device before the user has granted both prompts.
        func start(requireOnDevice: Bool) {
            guard let recognizer = recognizer, recognizer.isAvailable else {
                onError("speech recognizer unavailable for locale")
                cleanup()
                return
            }
            if requireOnDevice && !recognizer.supportsOnDeviceRecognition {
                onError("on-device recognition not supported for this locale")
                cleanup()
                return
            }
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                guard let self = self else { return }
                guard status == .authorized else {
                    DispatchQueue.main.async {
                        self.onError("speech recognition authorization denied")
                        self.cleanup()
                    }
                    return
                }
                // Microphone permission rides on AVCaptureDevice.requestAccess —
                // the audio engine itself doesn't trigger the prompt, but the
                // first installTap() on a non-authorized mic returns silent
                // buffers. Preflight here so the user sees the prompt before
                // any recognition happens (and we bail fast on denial).
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] micGranted in
                    guard let self = self else { return }
                    guard micGranted else {
                        DispatchQueue.main.async {
                            self.onError("microphone authorization denied")
                            self.cleanup()
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        self.beginRecognition(requireOnDevice: requireOnDevice)
                    }
                }
            }
        }

        /// Both prompts granted — wire up the request, install the audio
        /// tap, and start the engine. Runs on main. Any failure here is a
        /// one-time error → cleanup, since the engine state is "either
        /// fully running or fully torn down."
        private func beginRecognition(requireOnDevice: Bool) {
            guard let recognizer = recognizer else { return }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if requireOnDevice {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            // 1024 frames at the input device's native rate is the Apple-
            // documented sweet spot — small enough for low-latency partials,
            // large enough to not melt CPU on continuous capture.
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                onError("audio engine start failed: \(error.localizedDescription)")
                cleanup()
                return
            }

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self, !self.stopped else { return }
                if let result = result {
                    let segs = result.bestTranscription.segments.map { seg in
                        Speech.shapeSegment(
                            substring:  seg.substring,
                            start:      seg.substringRange.location,
                            length:     seg.substringRange.length,
                            confidence: seg.confidence
                        )
                    }
                    let env = Speech.shapeResult(
                        text:     result.bestTranscription.formattedString,
                        isFinal:  result.isFinal,
                        segments: segs
                    )
                    DispatchQueue.main.async { self.onResult(env) }
                    if result.isFinal {
                        DispatchQueue.main.async { self.stop() }
                    }
                }
                if let error = error {
                    // Cancel-after-stop fires an error; suppress if we
                    // already initiated teardown.
                    if !self.stopped {
                        DispatchQueue.main.async {
                            self.onError("recognizer error: \(error.localizedDescription)")
                            self.stop()
                        }
                    }
                }
            }
        }

        /// Tear down in the order: cancel the recognizer task → stop the
        /// engine → remove the tap → drop the request. Stopping the engine
        /// first prevents the next buffer arriving at a half-cancelled task;
        /// removing the tap before clearing self.request lets the closure's
        /// strong capture of `request` survive until the audio thread has
        /// definitely stopped calling into it.
        func stop() {
            if stopped { return }
            stopped = true
            task?.cancel()
            task = nil
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.inputNode.removeTap(onBus: 0)
            request?.endAudio()
            request = nil
        }

        /// Bail-out path for init/permission failures — same cleanup as
        /// stop() but without the engine teardown (it never started).
        private func cleanup() {
            stopped = true
            task?.cancel()
            task = nil
            request?.endAudio()
            request = nil
        }

        deinit {
            stop()
        }
    }
}
