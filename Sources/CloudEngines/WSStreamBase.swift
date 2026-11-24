import Foundation
import SonioxClient

/// Shared plumbing for cloud adapters: event stream, token batches with drafts, JSON helpers.
struct Emitter: Sendable {
    let continuation: AsyncStream<SonioxEvent>.Continuation
    var draftOriginal = ""
    var draftTranslation = ""
    var draftSpeaker: String?

    func send(finalOriginal: String? = nil, language: String? = nil, speaker: String? = nil, endOriginal: Bool = false,
              finalTranslation: String? = nil, endTranslation: Bool = false) {
        var t: [SonioxToken] = []
        if let o = finalOriginal, !o.isEmpty {
            t.append(SonioxToken(text: o, isFinal: true, speaker: speaker, language: language, translationStatus: "original"))
        }
        if endOriginal { t.append(SonioxToken(text: "<end>", isFinal: true, translationStatus: "original")) }
        if let tr = finalTranslation, !tr.isEmpty { t.append(SonioxToken(text: tr, isFinal: true, translationStatus: "translation")) }
        if endTranslation { t.append(SonioxToken(text: "<end>", isFinal: true, translationStatus: "translation")) }
        if !draftOriginal.isEmpty {
            t.append(SonioxToken(text: draftOriginal, isFinal: false, speaker: draftSpeaker, translationStatus: "original"))
        }
        if !draftTranslation.isEmpty { t.append(SonioxToken(text: draftTranslation, isFinal: false, translationStatus: "translation")) }
        if !t.isEmpty { continuation.yield(.tokens(t)) }
    }
}

enum JSON {
    static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    static func object(_ msg: URLSessionWebSocketTask.Message) -> [String: Any]? {
        switch msg {
        case let .string(s): object(Data(s.utf8))
        case let .data(d): object(d)
        @unknown default: nil
        }
    }
    static func string(_ obj: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), as: UTF8.self)
    }
}

extension SonioxConfig {
    var firstLanguage: String? { languageHints?.first }
    /// Target languages to request from a provider (two-way asks for both; the source-language one is ignored later).
    var targetLanguages: [String] {
        switch translation {
        case nil: []
        case let .oneWay(t)?: [t]
        case let .twoWay(a, b)?: [a, b]
        }
    }
}

func errorEvent(_ code: Int, _ message: String) -> SonioxEvent { .error(SonioxError(code: code, message: message)) }
