import Foundation
import SonioxClient

/// Assembles Soniox tokens of ONE stream into segments.
///
/// Rules (from the product spec, "assembling text from tokens"):
///  1. final tokens are appended exactly once;
///  2. non-final tokens of each response replace the previous non-final tokens entirely;
///  3. original and translation are separate tracks — translation arrives later and is not 1:1 aligned, so it fills
///     segments in order via its own cursor;
///  4. a segment closes on speaker change, on an `<end>`/`<fin>` marker, or via `closeOpenSegment()` (idle pause).
public struct TokenAssembler: Sendable {
    public let source: SourceKind
    public private(set) var segments: [Segment] = []

    private let idStride: Int
    private let idOffset: Int
    private var counter = 0
    private var openIndex: Int?
    private var translationIndex = 0
    private var draftOriginal = ""
    private var draftTranslation = ""
    /// If translation cursor falls this many closed segments behind, it skips ahead.
    private let maxTranslationLag = 3

    public init(source: SourceKind, idStride: Int = 4, idOffset: Int = 0) {
        self.source = source; self.idStride = idStride; self.idOffset = idOffset
    }

    private mutating func newSegment(speaker: String?, language: String?, startMs: Int) -> Int {
        counter += 1
        segments.append(Segment(id: counter * idStride + idOffset, source: source, speaker: speaker, language: language, startMs: startMs, endMs: startMs))
        return segments.count - 1
    }

    public mutating func closeOpenSegment() {
        if let i = openIndex { segments[i].isClosed = true }
        openIndex = nil
        pruneEmpty()
    }

    private mutating func pruneEmpty() {
        // Drop closed segments that never received any text (keeps cursors consistent).
        guard let last = segments.indices.last, segments[last].isClosed, segments[last].original.isEmpty,
              segments[last].translation.isEmpty, last >= translationIndex else { return }
        segments.removeLast()
    }

    private mutating func advanceTranslationCursor() {
        if translationIndex < segments.count { translationIndex += 1 }
    }

    /// Feed the tokens of one server response.
    public mutating func handle(_ tokens: [SonioxToken]) {
        draftOriginal = ""
        draftTranslation = ""

        for t in tokens {
            if t.isMarker {
                if t.isTranslation { advanceTranslationCursor() } else { closeOpenSegment() }
                continue
            }
            if t.isTranslation {
                if t.isFinal {
                    if translationIndex >= segments.count {
                        // Translation ahead of original (rare): attach to a fresh empty segment.
                        openIndex = openIndex ?? newSegment(speaker: t.speaker, language: nil, startMs: t.startMs ?? 0)
                        translationIndex = min(translationIndex, segments.count - 1)
                    }
                    segments[translationIndex].translation += t.text
                } else {
                    draftTranslation += t.text
                }
                continue
            }

            // Original track.
            if let i = openIndex, let s = t.speaker, let cur = segments[i].speaker, s != cur, t.isFinal {
                closeOpenSegment()
            }
            if t.isFinal {
                let i = openIndex ?? newSegment(speaker: t.speaker, language: t.language, startMs: t.startMs ?? 0)
                openIndex = i
                if segments[i].speaker == nil { segments[i].speaker = t.speaker }
                if segments[i].language == nil { segments[i].language = t.language }
                segments[i].original += t.text
                if let e = t.endMs { segments[i].endMs = max(segments[i].endMs, e) }
            } else {
                draftOriginal += t.text
                if openIndex == nil {
                    openIndex = newSegment(speaker: t.speaker, language: t.language, startMs: t.startMs ?? 0)
                }
            }
        }

        // Keep the translation cursor from falling too far behind the original.
        let closed = segments.filter(\.isClosed).count
        while closed - translationIndex >= maxTranslationLag, translationIndex < segments.count - 1 { translationIndex += 1 }
    }

    /// Segments with the current drafts folded in.
    public var snapshot: [Segment] {
        var out = segments
        if let i = openIndex, i < out.count { out[i].draftOriginal = draftOriginal }
        if !draftTranslation.isEmpty, !out.isEmpty {
            out[min(translationIndex, out.count - 1)].draftTranslation = draftTranslation
        }
        return out
    }
}
