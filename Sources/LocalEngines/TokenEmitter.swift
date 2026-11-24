import Foundation
import SonioxClient

/// Builds Soniox-style token batches for local engines. Every batch repeats the current drafts, because the
/// assembler replaces all non-final text with each batch (a batch without drafts would make them flicker away).
struct TokenEmitter {
    var draftOriginal = ""
    var draftTranslation = ""
    var draftLanguage: String?

    func batch(finalOriginal: String? = nil, language: String? = nil, endOriginal: Bool = false,
               finalTranslation: String? = nil, endTranslation: Bool = false) -> [SonioxToken] {
        var t: [SonioxToken] = []
        if let o = finalOriginal?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            t.append(SonioxToken(text: o, isFinal: true, language: language, translationStatus: "original"))
        }
        if endOriginal { t.append(SonioxToken(text: "<end>", isFinal: true, translationStatus: "original")) }
        if let tr = finalTranslation?.trimmingCharacters(in: .whitespacesAndNewlines), !tr.isEmpty {
            t.append(SonioxToken(text: tr, isFinal: true, translationStatus: "translation"))
        }
        if endTranslation { t.append(SonioxToken(text: "<end>", isFinal: true, translationStatus: "translation")) }
        if !draftOriginal.isEmpty {
            t.append(SonioxToken(text: draftOriginal, isFinal: false, language: draftLanguage, translationStatus: "original"))
        }
        if !draftTranslation.isEmpty {
            t.append(SonioxToken(text: draftTranslation, isFinal: false, translationStatus: "translation"))
        }
        return t
    }
}

extension SonioxConfig {
    /// The one-way target, or for two-way the language that is not `source`.
    func translationTarget(forSource source: String?) -> String? {
        switch translation {
        case nil: return nil
        case let .oneWay(target)?: return target
        case let .twoWay(a, b)?:
            guard let s = source?.prefix(2) else { return b }
            return s == a.prefix(2) ? b : a
        }
    }
}

func sameLanguage(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return a.lowercased().prefix(2) == b.lowercased().prefix(2)
}
