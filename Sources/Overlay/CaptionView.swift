import AppSettings
import SonioxClient
import SwiftUI
import Transcript

@MainActor @Observable
public final class OverlayState {
    public var isEditing = false
    public init() {}
}

func isRTL(_ s: String) -> Bool {
    for u in s.unicodeScalars {
        switch u.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
        default: if CharacterSet.letters.contains(u) { return false }
        }
    }
    return false
}

public struct CaptionView: View {
    let store: TranscriptStore
    let settings: SettingsStore
    var state: OverlayState
    var filter: SourceKind?
    var sample: [Segment]?

    @State private var lastActivity = Date()
    @State private var faded = false

    public init(store: TranscriptStore, settings: SettingsStore, state: OverlayState, filter: SourceKind? = nil, sample: [Segment]? = nil) {
        self.store = store; self.settings = settings; self.state = state; self.filter = filter; self.sample = sample
    }

    private var p: Profile { settings.profile }
    private var segments: [Segment] {
        (sample ?? store.segments).filter { !$0.hidden && (filter == nil || $0.source == filter || ($0.source == .mixed && filter == .system)) }
    }
    private var contentMode: ContentDisplay { p.layout.mode == .dual ? .both : p.content.mode }

    public var body: some View {
        let segs = segments
        Group {
            switch p.layout.mode {
            case .feed: feed(segs)
            default: captions(segs)
            }
        }
        .padding(p.appearance.padding)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .background(background)
        .overlay {
            if state.isEditing {
                RoundedRectangle(cornerRadius: p.appearance.cornerRadius)
                    .strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .opacity(visible(segs) ? 1 : 0)
        .animation(.easeInOut(duration: 0.4), value: visible(segs))
        .onChange(of: signature(segs)) { lastActivity = Date(); faded = false }
        .task(id: p.layout.autoHideSeconds) { await autoHideLoop() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func signature(_ s: [Segment]) -> Int { (s.last?.fullOriginal.count ?? 0) &+ (s.last?.fullTranslation.count ?? 0) &+ s.count }

    private func visible(_ s: [Segment]) -> Bool {
        if state.isEditing || sample != nil { return true }
        return !s.isEmpty && !faded
    }

    private func autoHideLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let n = p.layout.autoHideSeconds
            faded = n > 0 && Date().timeIntervalSince(lastActivity) > n
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: p.appearance.cornerRadius, style: .continuous)
        if p.appearance.useBlur {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(p.appearance.backgroundColor.color))
        } else {
            shape.fill(p.appearance.backgroundColor.color)
        }
    }

    // MARK: Modes

    private func captions(_ segs: [Segment]) -> some View {
        let tail = Array(segs.suffix(max(1, p.layout.lines)))
        let st = p.appearance.original
        let per = (st.size * 1.25 + st.lineSpacing) * (contentMode == .both ? 2 : 1)
        return VStack(spacing: 6) {
            ForEach(tail) { row($0) }
        }
        .frame(maxWidth: .infinity, minHeight: per, maxHeight: per * Double(max(1, p.layout.lines)) + 8, alignment: .bottom)
        .clipped()
        .animation(.spring(duration: 0.3), value: tail.map(\.id))
    }

    private func feed(_ segs: [Segment]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(segs) { row($0).id($0.id) }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: signature(segs)) {
                if let last = segs.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: Row

    private func row(_ s: Segment) -> some View {
        let a = p.appearance
        let tr = s.fullTranslation.trimmingCharacters(in: .whitespaces)
        let showTr = contentMode != .original && !tr.isEmpty
        let showOr = contentMode != .translation || tr.isEmpty
        let rtl = isRTL(showOr ? s.fullOriginal : tr)
        let align: Alignment = switch p.layout.alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
        let textAlign: TextAlignment = switch p.layout.alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }

        return VStack(alignment: .center, spacing: 2) {
            if showOr {
                Text(originalText(s))
                    .font(a.original.font).tracking(a.original.tracking).lineSpacing(a.original.lineSpacing)
                    .multilineTextAlignment(textAlign)
                    .frame(maxWidth: .infinity, alignment: align)
            }
            if showTr {
                Text(translationText(s))
                    .font(a.translation.font).tracking(a.translation.tracking).lineSpacing(a.translation.lineSpacing)
                    .multilineTextAlignment(textAlign)
                    .frame(maxWidth: .infinity, alignment: align)
            }
        }
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .modifier(TextEffects(shadow: a.shadow, outline: a.outline))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func sourceColor(_ s: Segment) -> Color {
        guard p.appearance.speakerColors else { return p.appearance.textColor.color }
        return s.source == .mic ? p.appearance.meColor.color : p.appearance.themColor.color
    }

    private func originalText(_ s: Segment) -> AttributedString {
        let a = p.appearance
        var out = AttributedString()
        var meta: [String] = []
        if p.content.showTimestamp { meta.append(s.createdAt.formatted(date: .omitted, time: .standard)) }
        if p.content.showSourceLabel, filter == nil || p.layout.mode == .split { meta.append(s.source.label) }
        if p.content.showSpeaker, let sp = s.speaker { meta.append("#\(sp)") }
        if p.content.showLanguage, let l = s.language { meta.append(l.uppercased()) }
        if !meta.isEmpty {
            var m = AttributedString(meta.joined(separator: " · ") + "  ")
            m.foregroundColor = sourceColor(s).opacity(0.7)
            m.font = .system(size: a.original.size * 0.55, weight: .semibold)
            out += m
        }
        func fmt(_ t: String) -> String { a.original.uppercase ? t.uppercased() : t }
        var fin = AttributedString(fmt(s.original)); fin.foregroundColor = sourceColor(s)
        var dr = AttributedString(fmt(s.draftOriginal)); dr.foregroundColor = a.draftColor.color
        return out + fin + dr
    }

    private func translationText(_ s: Segment) -> AttributedString {
        let a = p.appearance
        var fin = AttributedString(a.translation.uppercase ? s.translation.uppercased() : s.translation)
        fin.foregroundColor = a.translationColor.color
        var dr = AttributedString(a.translation.uppercase ? s.draftTranslation.uppercased() : s.draftTranslation)
        dr.foregroundColor = a.translationColor.color.opacity(0.55)
        return fin + dr
    }
}

private struct TextEffects: ViewModifier {
    let shadow: Bool
    let outline: Bool
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(shadow ? 0.8 : 0), radius: 3, x: 0, y: 1)
            .shadow(color: .black.opacity(outline ? 1 : 0), radius: 0, x: 1, y: 1)
            .shadow(color: .black.opacity(outline ? 1 : 0), radius: 0, x: -1, y: -1)
    }
}

public enum CaptionSamples {
    public static let segments: [Segment] = [
        Segment(id: 1, source: .system, speaker: "1", language: "en", original: "Let's go over the release plan for next week.", translation: "Давайте обсудим план релиза на следующую неделю.", isClosed: true),
        Segment(id: 2, source: .mic, language: "ru", original: "Хорошо, я подготовил список изменений.", translation: "Okay, I prepared the list of changes.", isClosed: true),
        Segment(id: 3, source: .system, speaker: "1", language: "en", original: "Great. The main risk is the", translation: "", draftOriginal: " migration", draftTranslation: "Отлично. Главный риск —"),
    ]
}
