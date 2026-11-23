import Foundation
import SonioxClient

public struct Segment: Identifiable, Sendable, Codable, Equatable {
    public var id: Int
    public var source: SourceKind
    public var speaker: String?
    public var language: String?
    public var startMs: Int
    public var endMs: Int
    /// Finalized original / translated text.
    public var original: String
    public var translation: String
    /// Non-final (draft) tails — replaced wholesale on every server response.
    public var draftOriginal: String
    public var draftTranslation: String
    public var isClosed: Bool
    public var createdAt: Date
    /// Set by the echo deduper: a mic phrase that duplicates the system stream.
    public var hidden: Bool

    public var fullOriginal: String { original + draftOriginal }
    public var fullTranslation: String { translation + draftTranslation }
    public var isEmpty: Bool { fullOriginal.trimmingCharacters(in: .whitespaces).isEmpty && fullTranslation.trimmingCharacters(in: .whitespaces).isEmpty }

    public init(id: Int, source: SourceKind, speaker: String? = nil, language: String? = nil, startMs: Int = 0, endMs: Int = 0,
                original: String = "", translation: String = "", draftOriginal: String = "", draftTranslation: String = "",
                isClosed: Bool = false, createdAt: Date = Date(), hidden: Bool = false) {
        self.id = id; self.source = source; self.speaker = speaker; self.language = language
        self.startMs = startMs; self.endMs = endMs; self.original = original; self.translation = translation
        self.draftOriginal = draftOriginal; self.draftTranslation = draftTranslation
        self.isClosed = isClosed; self.createdAt = createdAt; self.hidden = hidden
    }
}
