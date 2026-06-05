import Foundation

/// `sd.nlp.*` primitives — pure NaturalLanguage wrappers. Synchronous,
/// permission-gated by `"nlp"`. Each primitive is a thin call into the
/// `NLP` enum in `Sources/DataSources/NLP.swift`.
///
/// similarity() returns 0 if the embedding model for the detected language
/// isn't downloaded (English ships by default). language() returns null
/// (NSNull) when NLLanguageRecognizer can't decide.
extension Bridge {
    static func nlpPrimitives() -> [Primitive] { [
        .sync("nlp.language", permission: "nlp") { body in
            NLP.language(text: body["text"] as? String ?? "") as Any? ?? NSNull()
        },
        .sync("nlp.tokens", permission: "nlp") { body in
            NLP.tokens(text: body["text"] as? String ?? "", unit: body["unit"] as? String ?? "word")
        },
        .sync("nlp.lemmas", permission: "nlp") { body in
            NLP.lemmas(text: body["text"] as? String ?? "")
        },
        .sync("nlp.similarity", permission: "nlp") { body in
            NLP.similarity(body["a"] as? String ?? "", body["b"] as? String ?? "")
        }
    ] }
}
