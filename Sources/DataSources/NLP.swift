import Foundation
import NaturalLanguage

// Apple's NaturalLanguage framework — language ID, tokenization, lemmas,
// sentence similarity. Synchronous, fire-and-forget shape (no observers).
// Port-inspired by asmagill's hs._asm.nlp, trimmed to the four surfaces
// that actually serve stackd consumers (Palette ranking, smart-paste).
//
// Embedding caveat: NLEmbedding.sentenceEmbedding(for:) returns nil for
// languages whose on-device model hasn't been downloaded. English ships
// by default; other languages download on demand. similarity() returns 0
// rather than throwing so callers can gracefully fall back to string match.

enum NLP {
    /// BCP-47 dominant language code. Returns nil if NL can't classify.
    static func language(text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage?.rawValue
    }

    /// Tokenize at the requested unit. Defaults to word.
    static func tokens(text: String, unit: String = "word") -> [String] {
        let nlUnit: NLTokenUnit = {
            switch unit {
            case "sentence":  return .sentence
            case "paragraph": return .paragraph
            case "document":  return .document
            default:          return .word
            }
        }()
        let tok = NLTokenizer(unit: nlUnit)
        tok.string = text
        var out: [String] = []
        tok.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            out.append(String(text[range]))
            return true
        }
        return out
    }

    /// Per-token lemmas with NSRange location/length so JS callers (palette /
    /// search) can paint highlight overlays on the source string without
    /// re-finding it.
    static func lemmas(text: String) -> [[String: Any]] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var out: [[String: Any]] = []
        tagger.enumerateTags(
            in: text.startIndex ..< text.endIndex,
            unit: .word, scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let token = String(text[range])
            let nsr = NSRange(range, in: text)
            out.append([
                "token": token,
                "lemma": tag?.rawValue ?? token,
                "range": ["location": nsr.location, "length": nsr.length]
            ])
            return true
        }
        return out
    }

    /// Cosine similarity 0–1 between two strings via NLEmbedding sentence
    /// space. Returns 0 if the embedding model for the detected language
    /// isn't on-device.
    static func similarity(_ a: String, _ b: String) -> Double {
        let lang = NLLanguageRecognizer.dominantLanguage(for: a)
            ?? NLLanguageRecognizer.dominantLanguage(for: b)
            ?? .english
        guard let emb = NLEmbedding.sentenceEmbedding(for: lang) else { return 0 }
        // NLEmbedding.distance(distanceType:.cosine) returns 0..2 where 0 is
        // identical. Map back to a 0..1 similarity (1 identical, 0 orthogonal).
        let d = emb.distance(between: a, and: b, distanceType: .cosine)
        return max(0, min(1, 1 - d / 2))
    }
}
