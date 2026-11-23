import Foundation

/// Hides a mic phrase that (almost) duplicates a system-stream phrase heard in the last few seconds.
public enum EchoDeduper {
    public static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
    }

    public static func isEcho(mic: Segment, system: [Segment], window: TimeInterval = 3, threshold: Double = 0.6) -> Bool {
        let text = mic.fullOriginal
        guard words(text).count >= 3 else { return false }
        return system.contains { s in
            abs(s.createdAt.timeIntervalSince(mic.createdAt)) <= window + 4 // a segment spans several seconds
                && similarity(text, s.fullOriginal) >= threshold
        }
    }
}
