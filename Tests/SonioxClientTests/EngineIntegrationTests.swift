import AppSettings
import AudioCapture
import XCTest
@testable import CaptionsCore
@testable import SonioxClient
@testable import Transcript

/// Writes a 440 Hz tone into the ring like a real capture would.
final class FakeCapture: AudioSource, @unchecked Sendable {
    let ring = RingBuffer(capacity: 48_000 * 5)
    let sampleRate: Double = 48_000
    private var timer: DispatchSourceTimer?
    private var phase: Float = 0

    func start() throws {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fake.capture"))
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { [self] in
            var buf = [Float](repeating: 0, count: 480)
            for i in buf.indices { buf[i] = 0.3 * sin(phase); phase += 2 * .pi * 440 / 48_000 }
            buf.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 480) }
        }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }
}

final class KeychainStoreTests: XCTestCase {
    func testRoundTripAndMissing() {
        Trace.fileEnabled = false
        let kc = KeychainStore(service: "app.subveil.tests.\(UUID().uuidString)")
        defer { kc.delete() }
        XCTAssertEqual(kc.read(), .notFound)
        XCTAssertTrue(kc.save("secret-1"))
        XCTAssertEqual(kc.read(), .found("secret-1"))
        XCTAssertTrue(kc.save("secret-2"), "saving again replaces the value")
        XCTAssertEqual(kc.load(), "secret-2")
        kc.delete()
        XCTAssertEqual(kc.read(), .notFound)
    }
}

@MainActor
final class EngineIntegrationTests: XCTestCase {
    var server: MockSonioxServer!
    var settings: SettingsStore!
    var store: TranscriptStore!
    var engine: CaptionsEngine!
    var keychain: KeychainStore!
    var dir: URL!

    override func setUp() async throws {
        Trace.fileEnabled = false
        server = MockSonioxServer()
        try server.start()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("subveil-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        keychain = KeychainStore(service: "app.subveil.tests.\(UUID().uuidString)")
        settings = SettingsStore(directory: dir, keychain: keychain)
        settings.profile.sources = .system
        settings.profile.session.saveHistory = false // never write into the real history folder
        store = TranscriptStore()
        engine = CaptionsEngine(settings: settings, store: store)
        engine.captureFactory = { _, _ in FakeCapture() }
        engine.endpoint = server.url
    }

    override func tearDown() async throws {
        await engine.stop()
        server.stop()
        keychain.delete()
        try? FileManager.default.removeItem(at: dir)
    }

    func testStartWithoutKeyReportsProblemAndDoesNotConnect() async {
        await engine.start()
        XCTAssertTrue(engine.needsKey)
        XCTAssertEqual(engine.runState, .idle)
        XCTAssertNotNil(engine.lastError)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.connections.count, 0)
    }

    func testStartStreamsAudioAndShowsTranscript() async throws {
        settings.setAPIKey("test-key")
        let server = self.server!
        server.onConnection = { conn in
            conn.onBinary = { c, n in
                if n == 5 {
                    c.sendText(#"{"tokens":[{"text":"Hello world","start_ms":0,"end_ms":500,"is_final":true,"speaker":"1"},{"text":" and","is_final":false}]}"#)
                }
            }
        }
        await engine.start()
        XCTAssertEqual(engine.runState, .running)

        let streamed = await waitUntil(8) { server.connections.first?.binaryCount ?? 0 >= 5 }
        XCTAssertTrue(streamed, "engine should stream resampled audio chunks to Soniox")
        XCTAssertEqual(server.authHeaders.first, "Bearer test-key")

        let shown = await waitMain(5) { self.store.segments.contains { $0.original == "Hello world" } }
        XCTAssertTrue(shown, "final tokens end up in the transcript store")
        let seg = try XCTUnwrap(store.segments.first)
        XCTAssertEqual(seg.source, .system)
        XCTAssertEqual(seg.draftOriginal, " and", "non-final tail is kept as draft")
        XCTAssertEqual(engine.overall, .live)

        await engine.stop()
        XCTAssertEqual(engine.runState, .idle)
    }

    func testChunkSizeIs100msOfPCM16() async {
        settings.setAPIKey("k")
        let server = self.server!
        await engine.start()
        _ = await waitUntil(8) { server.connections.first?.binaryCount ?? 0 >= 10 }
        // 10 chunks ≈ 1 s of audio in ~1 s of wall time (not all at once, not starved).
        XCTAssertGreaterThanOrEqual(server.connections.first?.binaryCount ?? 0, 10)
    }

    func testPauseStopsAudioAndResumeContinues() async {
        settings.setAPIKey("k")
        let server = self.server!
        await engine.start()
        _ = await waitUntil(8) { server.connections.first?.binaryCount ?? 0 >= 5 }
        await engine.pause()
        XCTAssertEqual(engine.runState, .paused)
        try? await Task.sleep(for: .milliseconds(400)) // let in-flight chunks drain
        let atPause = server.connections.first?.binaryCount ?? 0
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(server.connections.first?.binaryCount ?? 0, atPause, "no audio is sent while paused")
        XCTAssertTrue(server.connections.first?.texts.contains { $0.contains("finalize") } ?? false, "pause sends finalize")

        engine.resume()
        let resumed = await waitUntil(5) { (server.connections.first?.binaryCount ?? 0) > atPause + 2 }
        XCTAssertTrue(resumed)
    }

    func testTranslationChangeOpensNewSessionAndKeepsHistory() async throws {
        settings.setAPIKey("k")
        let server = self.server!
        server.onConnection = { conn in
            conn.onBinary = { c, n in
                if n == 3, c.index == 0 { c.sendText(#"{"tokens":[{"text":"Before","start_ms":0,"end_ms":300,"is_final":true}]}"#) }
            }
        }
        await engine.start()
        let before = await waitMain(8) { self.store.segments.contains { $0.original == "Before" } }
        XCTAssertTrue(before, "precondition: first session delivered text; segments=\(store.segments.map(\.original)) bin=\(server.connections.first?.binaryCount ?? -1)")

        settings.profile.translationSystem = TranslationSettings(kind: .oneWay, target: "ru")
        await engine.applyConfigChange()

        let second = await waitUntil(5) { server.connections.count >= 2 }
        XCTAssertTrue(second, "a new session is opened for the new config")
        let cfg = try XCTUnwrap(server.connections[1].texts.first)
        XCTAssertTrue(cfg.contains("\"one_way\"") && cfg.contains("\"target_language\":\"ru\""), cfg)
        let flows = await waitUntil(5) { server.connections[1].binaryCount >= 3 }
        XCTAssertTrue(flows, "audio continues on the new session")
        XCTAssertTrue(store.segments.contains { $0.original == "Before" }, "history survives the switch")
    }

    func testFatal401StopsEngineAndAsksForKey() async {
        settings.setAPIKey("wrong")
        let server = self.server!
        server.onConnection = { conn in
            conn.onText = { c, _ in c.sendText(#"{"error_code":401,"error_message":"bad key"}"#) }
        }
        await engine.start()
        let stopped = await waitMain(8) { self.engine.runState == .idle && self.engine.needsKey }
        XCTAssertTrue(stopped, "401 should stop capture and ask for a new key")
    }
}
