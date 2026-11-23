import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case markdown, srt, json
    public var fileExtension: String { self == .markdown ? "md" : rawValue }
    public var title: String { self == .markdown ? "Markdown" : rawValue.uppercased() }
}

public enum Exporters {
    public static func export(_ segments: [Segment], format: ExportFormat, start: Date) -> String {
        let visible = segments.filter { !$0.hidden && !$0.isEmpty }
        switch format {
        case .markdown: return markdown(visible, start: start)
        case .srt: return srt(visible, start: start)
        case .json: return json(visible)
        }
    }

    static func offset(_ s: Segment, _ start: Date) -> Int { max(0, Int(s.createdAt.timeIntervalSince(start) * 1000)) }

    public static func markdown(_ segs: [Segment], start: Date) -> String {
        var out = "# Transcript — \(start.formatted(date: .abbreviated, time: .shortened))\n\n"
        for s in segs {
            let t = clock(offset(s, start))
            let who = s.speaker.map { "\(s.source.label) · \($0)" } ?? s.source.label
            out += "**[\(t)] \(who):** \(s.fullOriginal.trimmingCharacters(in: .whitespaces))\n"
            if !s.fullTranslation.isEmpty { out += "> \(s.fullTranslation.trimmingCharacters(in: .whitespaces))\n" }
            out += "\n"
        }
        return out
    }

    public static func srt(_ segs: [Segment], start: Date) -> String {
        var out = ""
        for (i, s) in segs.enumerated() {
            let a = offset(s, start)
            let b = a + max(1500, s.endMs - s.startMs)
            out += "\(i + 1)\n\(stamp(a)) --> \(stamp(b))\n"
            out += "[\(s.source.label)] \(s.fullOriginal.trimmingCharacters(in: .whitespaces))\n"
            if !s.fullTranslation.isEmpty { out += s.fullTranslation.trimmingCharacters(in: .whitespaces) + "\n" }
            out += "\n"
        }
        return out
    }

    public static func json(_ segs: [Segment]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return (try? String(decoding: enc.encode(segs), as: UTF8.self)) ?? "[]"
    }

    static func clock(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    static func stamp(_ ms: Int) -> String {
        String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
