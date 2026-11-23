import AppSettings
import Foundation
import Transcript

/// Decides which lines of a segment are shown.
///
/// `.translation` ("Target language only", the default): with translation on, text in other languages is never shown —
/// only the translation; speech that is already in the target language is shown as-is. With translation off it falls
/// back to the original (otherwise nothing would ever appear).
public enum CaptionContent {
    public struct Lines: Equatable, Sendable {
        public var original: Bool
        public var translation: Bool
        public var isEmpty: Bool { !original && !translation }
    }

    public static func lines(for s: Segment, mode: ContentDisplay, translation tr: TranslationSettings) -> Lines {
        let hasTr = !s.fullTranslation.trimmingCharacters(in: .whitespaces).isEmpty
        switch mode {
        case .original:
            return Lines(original: true, translation: false)
        case .both:
            return Lines(original: true, translation: hasTr)
        case .translation:
            switch tr.kind {
            case .off:
                return Lines(original: true, translation: false)
            case .oneWay:
                if hasTr { return Lines(original: false, translation: true) }
                // No translation is produced for speech already in the target language — show it as-is.
                return Lines(original: isLanguage(s.language, tr.target), translation: false)
            case .twoWay:
                return Lines(original: false, translation: hasTr)
            }
        }
    }

    static func isLanguage(_ lang: String?, _ target: String) -> Bool {
        guard let lang, !lang.isEmpty else { return false }
        return lang.lowercased().hasPrefix(target.lowercased())
    }
}
