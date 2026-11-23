import XCTest
@testable import SonioxClient

final class SonioxSessionTests: XCTestCase {
    var server: MockSonioxServer!

    override func setUpWithError() throws {
        Trace.fileEnabled = false
        server = MockSonioxServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func chunk() -> Data { Data(repeating: 1, count: 3200) }

    private func collect(_ s: SonioxSession) -> EventLog<SonioxEvent> {
        let log = EventLog<SonioxEvent>()
        Task { for await e in s.events { log.add(e) } }
        return log
    }

    func testSendsBearerHeaderConfigWithoutApiKeyAndAudio() async throws {
        let server = self.server!
        let session = SonioxSession(apiKey: "test-key-123", config: SonioxConfig(model: "stt-rt-v6"), endpoint: server.url)
        let events = collect(session)
        await session.start()
        for _ in 0..<5 { await session.send(chunk()) }

        let gotAudio = await waitUntil { server.connections.first?.binaryCount ?? 0 >= 5 }
        XCTAssertTrue(gotAudio, "server should receive 5 audio frames")
        XCTAssertEqual(server.authHeaders.first, "Bearer test-key-123")
        let config = try XCTUnwrap(server.connections.first?.texts.first)
        XCTAssertTrue(config.contains("\"model\":\"stt-rt-v6\""))
        XCTAssertTrue(config.contains("\"audio_format\":\"pcm_s16le\""))
        XCTAssertFalse(config.contains("api_key"), "api_key in config is deprecated")
        XCTAssertFalse(config.contains("test-key-123"), "key must travel only in the header")

        server.connections[0].sendText(#"{"tokens":[{"text":"Hello","start_ms":0,"end_ms":300,"is_final":true,"speaker":"1"}],"final_audio_proc_ms":300}"#)
        let gotTokens = await waitUntil { events.all.contains { if case .tokens = $0 { true } else { false } } }
        XCTAssertTrue(gotTokens)
        await session.stop()
    }

    func testFatal401StopsWithoutReconnecting() async {
        server.onConnection = { conn in
            conn.onText = { c, _ in c.sendText(#"{"error_code":401,"error_message":"Invalid API key"}"#) }
        }
        let session = SonioxSession(apiKey: "bad", config: SonioxConfig(), endpoint: server.url)
        let events = collect(session)
        await session.start()

        let failed = await waitUntil {
            events.all.contains { if case .state(.failed) = $0 { true } else { false } }
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(events.all.contains { if case let .error(e) = $0 { e.code == 401 && e.isFatal } else { false } })
        try? await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(server.connections.count, 1, "a 401 must not trigger reconnect attempts")
        await session.stop()
    }

    func testReconnectReplaysOnlyUnfinalizedAudioAndShiftsTimestamps() async {
        let server = self.server!
        // Connection #0: after 3 audio frames confirm 200 ms finalized, then drop.
        server.onConnection = { conn in
            if conn.index == 0 {
                conn.onBinary = { c, n in
                    if n == 3 {
                        c.sendText(#"{"tokens":[{"text":"One","start_ms":0,"end_ms":200,"is_final":true}],"final_audio_proc_ms":200}"#)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { c.close() }
                    }
                }
            } else {
                conn.onText = { c, _ in
                    c.sendText(#"{"tokens":[{"text":"Two","start_ms":0,"end_ms":100,"is_final":true}],"final_audio_proc_ms":100}"#)
                }
            }
        }
        let session = SonioxSession(apiKey: "k", config: SonioxConfig(), endpoint: server.url)
        let events = collect(session)
        for _ in 0..<6 { await session.send(chunk()) } // queued before connect
        await session.start()

        let reconnected = await waitUntil(10) { server.connections.count >= 2 && server.connections[1].binaryCount >= 4 }
        XCTAssertTrue(reconnected, "second connection should receive replayed audio")
        // 6 chunks total, 200 ms (= 2 chunks) already finalized → 4 replayed.
        XCTAssertEqual(server.connections[1].binaryCount, 4)

        let shifted = await waitUntil {
            events.all.contains { e in
                if case let .tokens(t) = e, t.first?.text == "Two" { return t.first?.startMs == 200 }
                return false
            }
        }
        XCTAssertTrue(shifted, "timestamps from the new server session are offset by the replay position")
        XCTAssertTrue(events.all.contains { if case .state(.reconnecting) = $0 { true } else { false } })
        await session.stop()
    }

    func testBackoffOn429ThenRecovers() async {
        let server = self.server!
        server.onConnection = { conn in
            if conn.index == 0 { conn.onText = { c, _ in c.sendText(#"{"error_code":429,"error_message":"rate"}"#) } }
        }
        let session = SonioxSession(apiKey: "k", config: SonioxConfig(), endpoint: server.url)
        let events = collect(session)
        await session.start()
        let retried = await waitUntil(15) { server.connections.count >= 2 }
        XCTAssertTrue(retried, "429 is retryable (backoff), not fatal")
        XCTAssertTrue(events.all.contains { if case let .error(e) = $0 { e.code == 429 } else { false } })
        await session.stop()
    }
}
