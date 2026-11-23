import Foundation
import os

/// Diagnostic trace → `~/Library/Logs/Subveil/trace.log` (+ unified logging, subsystem `app.subveil`).
/// Rule: NEVER log the API key or transcript text — only counts, states, status codes, timings.
public enum Trace {
    public static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Subveil", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trace.log")
    }()

    private static let queue = DispatchQueue(label: "subveil.trace")
    private static let logger = Logger(subsystem: "app.subveil", category: "trace")
    nonisolated(unsafe) private static var formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    /// Tests can disable file output.
    nonisolated(unsafe) public static var fileEnabled = true

    public static func log(_ category: String, _ message: @autoclosure () -> String) {
        let msg = message()
        logger.info("[\(category, privacy: .public)] \(msg, privacy: .public)")
        guard fileEnabled else { return }
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) [\(category)] \(msg)\n"
            rotateIfNeeded()
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    private static func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attrs?[.size] as? Int, size > 2_000_000 {
            let old = fileURL.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: fileURL, to: old)
        }
    }
}
