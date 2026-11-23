import Foundation
import SonioxClient
import Transcript

/// One JSON file per session in the history folder, named by the session start time.
public enum HistoryFiles {
    static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    public static func save(_ segments: [Segment], sessionStart: Date, to dir: URL) {
        let visible = segments.filter { !$0.isEmpty }
        guard !visible.isEmpty else { return }
        let url = dir.appendingPathComponent("\(formatter.string(from: sessionStart)).json")
        do {
            try Exporters.json(visible).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Trace.log("history", "save failed: \(error.localizedDescription)")
        }
    }
}
