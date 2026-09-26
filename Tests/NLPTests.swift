import Foundation

// Tests for NLP.swift — a thin wrapper over Apple's NaturalLanguage
// framework (language ID, tokenization, lemmas, sentence similarity).
// Unlike Speech/Calendar, NL tagger calls are pure compute: no TCC, no
// asynchronous callbacks, no device state. Safe to exercise end-to-end
// on tiny strings.
//
// Embedding caveat (see NLP.swift header): NLEmbedding.sentenceEmbedding
// is only guaranteed for English on a default install. similarity() tests
// stick to English and tolerate the model-missing path by asserting on
// the documented contract (0..1, clamped) rather than exact values.

func registerNLPTests() {
    // MARK: language(text:)

    test("language identifies plain English text as 'en'") {
        // Needs enough signal — NL classifier is unreliable on 1-2 words.
        try expectEqual(NLP.language(text: "The quick brown fox jumps over the lazy dog."), "en")
    }

    test("language returns nil for empty string") {
        try expect(NLP.language(text: "") == nil)
    }

    // MARK: tokens(text:unit:)

    test("tokens default unit splits into words, dropping spaces") {
        let toks = NLP.tokens(text: "hello world")
        try expectEqual(toks, ["hello", "world"])
    }

    test("tokens unit=sentence yields one chunk per sentence") {
        let toks = NLP.tokens(text: "First one. Second one.", unit: "sentence")
        try expectEqual(toks.count, 2)
        try expect(toks[0].contains("First"))
        try expect(toks[1].contains("Second"))
    }

    test("tokens unknown unit string falls back to word") {
        // Switch's default branch — guards against typos like "words".
        let toks = NLP.tokens(text: "alpha beta", unit: "bogus")
        try expectEqual(toks, ["alpha", "beta"])
    }

    // MARK: lemmas(text:)

    test("lemmas omit whitespace/punctuation and expose token+range") {
        let out = NLP.lemmas(text: "Cats run.")
        // Two content tokens; "." and spaces dropped per .omitPunctuation/.omitWhitespace.
        try expectEqual(out.count, 2)

        let first = out[0]
        try expectEqual(first["token"] as? String, "Cats")
        // NLTagger may or may not produce a lemma tag on every build; the
        // wrapper falls back to the surface token, so just assert it's a
        // non-empty string rather than pinning the exact morphological form.
        let lemma = first["lemma"] as? String ?? ""
        try expect(!lemma.isEmpty)

        let range = first["range"] as? [String: Int] ?? [:]
        try expectEqual(range["location"], 0)
        try expectEqual(range["length"], 4)
    }

    // MARK: similarity(_:_:)

    test("similarity of identical strings is 1 (or 0 if model missing)") {
        let s = NLP.similarity("hello world", "hello world")
        // Identical inputs → cosine distance 0 → mapped to 1.0. If the
        // English sentence-embedding model isn't on-device the wrapper
        // returns 0. Either is a valid contract outcome; anything else
        // means the 0..1 clamp drifted.
        try expect(s == 1.0 || s == 0.0)
    }

    test("similarity ranks a paraphrase above an unrelated sentence, within [0, 1]") {
        // Full sentences so language ID confidently picks English — short
        // phrases can be misidentified, and similarity() then looks up the
        // wrong (often missing) embedding model.
        let base  = "The weather is sunny and warm today."
        let close = NLP.similarity(base, "It is a bright and hot day outside.")
        let far   = NLP.similarity(base, "The quarterly tax filing deadline is next week.")
        try expect(close >= 0.0 && close <= 1.0, "similarity out of [0, 1]: \(close)")
        try expect(far   >= 0.0 && far   <= 1.0, "similarity out of [0, 1]: \(far)")
        // Without the on-device English model both collapse to 0 — nothing to rank.
        guard NLP.similarity("hello world", "hello world") == 1.0 else { return }
        try expect(close > far, "paraphrase (\(close)) should outrank unrelated text (\(far))")
    }
}
