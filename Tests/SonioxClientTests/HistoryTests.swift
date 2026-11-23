import XCTest
@testable import AppSettings
@testable import CaptionsCore
@testable import SonioxClient
@testable import Transcript

@MainActor
final class HistoryTests: XCTestCase {
    func testHistoryIsOffByDefaultAndEachSessionStartsClean() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsStore(directory: dir, keychain: KeychainStore(service: "app.subveil.tests.\(UUID().uuidString)"))
        XCTAssertFalse(settings.profile.session.saveHistory, "no transcript history by default")

        let store = TranscriptStore()
        let engine = CaptionsEngine(settings: settings, store: store)
        engine.historyDirectory = dir
        store.apply([SonioxToken(text: "Hello", isFinal: true, language: "en")], from: .system)
        try await Task.sleep(for: .milliseconds(50))
        engine.saveHistory()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") && $0 != "settings.json" }
        XCTAssertTrue(files.isEmpty, "nothing is written when history is off")

        // Start clears the previous session's text.
        settings.setAPIKey("k")
        settings.profile.sources = .system
        engine.captureFactory = { _, _ in FakeCapture() }
        engine.endpoint = URL(string: "ws://127.0.0.1:9/unreachable")!
        await engine.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.segments.isEmpty, "every session starts from zero")
        await engine.stop()
        settings.keychain.delete()
    }

    func testOptionalHistoryWritesASessionFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        HistoryFiles.save([Segment(id: 1, source: .system, original: "kept")], sessionStart: Date(), to: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
    }
}
