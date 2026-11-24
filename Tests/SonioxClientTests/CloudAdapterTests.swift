import Foundation
import XCTest
@testable import CloudEngines
@testable import LocalEngines
@testable import SonioxClient
@testable import Transcript

/// Builds segments from a stream's events, like the app does.
final class Assembled: @unchecked Sendable {
    private let lock = NSLock()
    private var a = TokenAssembler(source: .system)
    private(set) var states: [SonioxConnectionState] = []
    private(set) var errors: [SonioxError] = []
    func add(_ e: SonioxEvent) {
        lock.lock(); defer { lock.unlock() }
        switch e {
        case let .tokens(t): a.handle(t)
        case let .state(s): states.append(s)
        case let .error(err): errors.append(err)
        case .finished: break
        }
    }
    var segments: [Segment] { lock.lock(); defer { lock.unlock() }; return a.snapshot }
}

private func collect(_ s: some SpeechStream) -> Assembled {
    let out = Assembled()
    Task { for await e in s.events { out.add(e) } }
    return out
}

final class SpeechmaticsAdapterTests: XCTestCase {
    func testProtocolMapping() async throws {
        Trace.fileEnabled = false
        let server = MockSonioxServer()
        try server.start()
        defer { server.stop() }
        server.onConnection = { conn in
            conn.onText = { c, text in
                if text.contains("StartRecognition") {
                    c.sendText(#"{"message":"RecognitionStarted","id":"x"}"#)
                    c.sendText(#"{"message":"AddPartialTranscript","metadata":{"transcript":"Добрый"},"results":[]}"#)
                    c.sendText(#"{"message":"AddTranscript","metadata":{"transcript":"Добрый день."},"results":[{"type":"word","alternatives":[{"content":"Добрый","speaker":"S2"}]},{"type":"punctuation","is_eos":true,"alternatives":[{"content":"."}]}]}"#)
                    c.sendText(#"{"message":"AddTranslation","language":"en","results":[{"content":"Good afternoon.","speaker":"S2"}]}"#)
                }
                if text.contains("EndOfStream") { c.sendText(#"{"message":"EndOfTranscript"}"#) }
            }
        }
        var cfg = SonioxConfig(); cfg.languageHints = ["ru"]; cfg.translation = .oneWay(target: "en"); cfg.enableSpeakerDiarization = true
        let stream = SpeechmaticsStream(apiKey: "sm-key", config: cfg, url: server.url)
        let got = collect(stream)
        await stream.start()
        for _ in 0..<3 { await stream.send(Data(count: 3200)) }
        let done = await waitUntil(5) { got.segments.first?.translation == "Good afternoon." }
        XCTAssertTrue(done, "segments: \(got.segments)")
        let seg = try XCTUnwrap(got.segments.first)
        XCTAssertEqual(seg.original, "Добрый день.")
        XCTAssertEqual(seg.speaker, "2", "S2 → speaker 2")
        XCTAssertTrue(seg.isClosed, "is_eos closes the line")
        await stream.stop()

        XCTAssertEqual(server.authHeaders.first, "Bearer sm-key")
        let start = try XCTUnwrap(server.connections.first?.texts.first.flatMap { JSON.object(Data($0.utf8)) })
        let tc = try XCTUnwrap(start["transcription_config"] as? [String: Any])
        XCTAssertEqual(tc["language"] as? String, "ru")
        XCTAssertEqual(tc["diarization"] as? String, "speaker")
        XCTAssertEqual((start["translation_config"] as? [String: Any])?["target_languages"] as? [String], ["en"])
        XCTAssertEqual((start["audio_format"] as? [String: Any])?["encoding"] as? String, "pcm_s16le")
        let eos = try XCTUnwrap(server.connections.first?.texts.first { $0.contains("EndOfStream") }.flatMap { JSON.object(Data($0.utf8)) })
        XCTAssertEqual(eos["last_seq_no"] as? Int, 3, "last_seq_no = number of audio chunks sent")
    }
}

final class OpenAIAdapterTests: XCTestCase {
    func testTranslationSessionAndAudioFormat() async throws {
        Trace.fileEnabled = false
        let server = MockSonioxServer()
        try server.start()
        defer { server.stop() }
        server.onConnection = { conn in
            conn.onText = { c, text in
                if text.contains("session.update") {
                    c.sendText(#"{"type":"session.created","session":{"id":"s"}}"#)
                    c.sendText(#"{"type":"session.input_transcript.delta","delta":"Привет, "}"#)
                    c.sendText(#"{"type":"session.input_transcript.delta","delta":"мир."}"#)
                    c.sendText(#"{"type":"session.output_transcript.delta","delta":"Hello, "}"#)
                    c.sendText(#"{"type":"session.output_transcript.delta","delta":"world."}"#)
                }
                if text.contains("session.close") { c.sendText(#"{"type":"session.closed"}"#) }
            }
        }
        var cfg = SonioxConfig(); cfg.translation = .oneWay(target: "en")
        let stream = OpenAITranslateStream(apiKey: "sk-test", config: cfg, url: server.url)
        let got = collect(stream)
        await stream.start()
        for _ in 0..<4 { await stream.send(Data(count: 3200)) }   // 400 ms of audio → two 200 ms appends at 24 kHz
        let done = await waitUntil(5) { got.segments.first?.translation == "Hello, world." }
        XCTAssertTrue(done, "segments: \(got.segments)")
        XCTAssertEqual(got.segments.first?.original, "Привет, мир.")
        await stream.stop()

        XCTAssertEqual(server.authHeaders.first, "Bearer sk-test")
        let texts = server.connections.first?.texts ?? []
        let update = try XCTUnwrap(texts.first.flatMap { JSON.object(Data($0.utf8)) })
        let lang = ((update["session"] as? [String: Any])?["audio"] as? [String: Any])?["output"] as? [String: Any]
        XCTAssertEqual(lang?["language"] as? String, "en")
        let appends = texts.compactMap { JSON.object(Data($0.utf8)) }.filter { $0["type"] as? String == "session.input_audio_buffer.append" }
        XCTAssertEqual(appends.count, 2)
        XCTAssertEqual(Data(base64Encoded: appends[0]["audio"] as? String ?? "")?.count, 9600, "200 ms of 24 kHz PCM16")
    }

    func testUpsampleKeepsShape() {
        let src = [Int16](arrayLiteral: 0, 300, 600, 900).withUnsafeBufferPointer { Data(buffer: $0) }
        let out = OpenAITranslateStream.upsample(src)
        XCTAssertEqual(out.count, src.count * 3 / 2)
        let v = out.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(v.first, 0)
        XCTAssertTrue(zip(v, v.dropFirst()).allSatisfy { $0 <= $1 }, "a ramp stays a ramp")
    }
}

/// Answers Gladia's POST /v2/live with a WebSocket URL pointing at the mock server.
final class GladiaInitStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var wsURL = ""
    nonisolated(unsafe) static var lastBody: [String: Any]?
    nonisolated(unsafe) static var lastKey: String?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.path == "/v2/live" && request.httpMethod == "POST" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastKey = request.value(forHTTPHeaderField: "x-gladia-key")
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            Self.lastBody = JSON.object(data)
        } else if let b = request.httpBody { Self.lastBody = JSON.object(b) }
        let body = Data(#"{"id":"abc","url":"\#(Self.wsURL)"}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GladiaAdapterTests: XCTestCase {
    func testInitThenTranscriptAndTranslation() async throws {
        Trace.fileEnabled = false
        let server = MockSonioxServer()
        try server.start()
        defer { server.stop() }
        GladiaInitStub.wsURL = server.url.absoluteString
        server.onConnection = { conn in
            conn.onBinary = { c, n in
                guard n == 1 else { return }
                c.sendText(#"{"type":"transcript","data":{"id":"u1","is_final":false,"utterance":{"text":"Шалом","language":"he"}}}"#)
                c.sendText(#"{"type":"transcript","data":{"id":"u1","is_final":true,"utterance":{"text":"שלום לכולם","language":"he"}}}"#)
                c.sendText(#"{"type":"translation","data":{"utterance_id":"u1","original_language":"he","target_language":"he","translated_utterance":{"text":"שלום לכולם"}}}"#)
                c.sendText(#"{"type":"translation","data":{"utterance_id":"u1","original_language":"he","target_language":"en","translated_utterance":{"text":"Hello everyone"}}}"#)
            }
            conn.onText = { c, text in if text.contains("stop_recording") { c.sendText(#"{"type":"end_session"}"#) } }
        }
        let cfgSession = URLSessionConfiguration.default
        cfgSession.protocolClasses = [GladiaInitStub.self]
        var cfg = SonioxConfig(); cfg.languageHints = ["he", "en"]; cfg.translation = .twoWay(a: "he", b: "en")
        let stream = GladiaStream(apiKey: "gl-key", config: cfg, base: URL(string: "http://gladia.test")!, session: URLSession(configuration: cfgSession))
        let got = collect(stream)
        await stream.start()
        await stream.send(Data(count: 3200))
        let done = await waitUntil(5) { got.segments.first?.translation == "Hello everyone" }
        XCTAssertTrue(done, "segments: \(got.segments) errors: \(got.errors)")
        XCTAssertEqual(got.segments.first?.original, "שלום לכולם")
        XCTAssertEqual(got.segments.count, 1, "the same-language 'translation' of two-way mode is ignored")
        await stream.stop()

        XCTAssertEqual(GladiaInitStub.lastKey, "gl-key")
        let body = try XCTUnwrap(GladiaInitStub.lastBody)
        XCTAssertEqual(body["encoding"] as? String, "wav/pcm")
        XCTAssertEqual(body["sample_rate"] as? Int, 16000)
        let rp = try XCTUnwrap(body["realtime_processing"] as? [String: Any])
        XCTAssertEqual(rp["translation"] as? Bool, true)
        XCTAssertEqual((rp["translation_config"] as? [String: Any])?["target_languages"] as? [String], ["he", "en"])
    }

    func testInvalidKeyIsFatal() async {
        final class Deny: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"statusCode":401,"message":"gladia key not found"}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let c = URLSessionConfiguration.default
        c.protocolClasses = [Deny.self]
        let stream = GladiaStream(apiKey: "bad", config: SonioxConfig(), base: URL(string: "http://gladia.test")!, session: URLSession(configuration: c))
        let got = collect(stream)
        await stream.start()
        let failed = await waitUntil(3) { got.states.contains(.failed) }
        XCTAssertTrue(failed)
        XCTAssertTrue(got.errors.contains { $0.code == 401 && $0.isFatal })
    }
}

final class ElevenLabsAdapterTests: XCTestCase {
    struct UpperTranslator: TextTranslator {
        var name: String { "test" }
        func translate(_ text: String, from source: String?, to target: String) async throws -> String { "[\(target)] " + text.uppercased() }
        func problem(from source: String?, to target: String) async -> String? { nil }
    }

    func testScribeLinesAreTranslatedLocally() async throws {
        Trace.fileEnabled = false
        let server = MockSonioxServer()
        try server.start()
        defer { server.stop() }
        server.onConnection = { conn in
            conn.onText = { c, text in
                guard text.contains("input_audio_chunk"), (c.texts.count == 1) else { return }
                c.sendText(#"{"message_type":"session_started","session_id":"s1","config":{}}"#)
                c.sendText(#"{"message_type":"partial_transcript","text":"buenos","language_code":"es"}"#)
                c.sendText(#"{"message_type":"committed_transcript","text":"buenos días"}"#)
            }
        }
        var cfg = SonioxConfig(); cfg.translation = .oneWay(target: "en")
        var u = URLComponents(url: server.url, resolvingAgainstBaseURL: false)!
        u.queryItems = ElevenLabsStream.url(cfg).query.map { _ in URLComponents(url: ElevenLabsStream.url(cfg), resolvingAgainstBaseURL: false)!.queryItems! }
        let stream = ElevenLabsStream(apiKey: "xi-key", config: cfg, translator: UpperTranslator(), url: u.url!)
        let got = collect(stream)
        await stream.start()
        await stream.send(Data(count: 3200))
        let done = await waitUntil(5) { got.segments.first?.translation == "[en] BUENOS DÍAS" }
        XCTAssertTrue(done, "segments: \(got.segments)")
        XCTAssertEqual(got.segments.first?.original, "buenos días")
        XCTAssertEqual(got.segments.first?.language, "es", "language from partial_transcript")
        await stream.stop()
        XCTAssertEqual(server.authHeaders.first, "", "auth is the xi-api-key header, not Authorization")
        let chunk = try XCTUnwrap(server.connections.first?.texts.first.flatMap { JSON.object(Data($0.utf8)) })
        XCTAssertEqual(chunk["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(chunk["sample_rate"] as? Int, 16000)
        XCTAssertEqual(chunk["commit"] as? Bool, false)
        let q = URLComponents(url: ElevenLabsStream.url(cfg), resolvingAgainstBaseURL: false)!.queryItems ?? []
        XCTAssertTrue(q.contains(URLQueryItem(name: "model_id", value: "scribe_v3_live")))
        XCTAssertTrue(q.contains(URLQueryItem(name: "audio_format", value: "pcm_16000")))
    }
}

final class GeminiAdapterTests: XCTestCase {
    func testSetupAudioAndTranscripts() async throws {
        Trace.fileEnabled = false
        let server = MockSonioxServer()
        try server.start()
        defer { server.stop() }
        server.onConnection = { conn in
            conn.onText = { c, text in
                if text.contains("\"setup\"") {
                    c.sendText(#"{"setupComplete":{}}"#)
                    c.sendText(#"{"serverContent":{"inputTranscription":{"text":"Hola, ","languageCode":"es"}}}"#)
                    c.sendText(#"{"serverContent":{"inputTranscription":{"text":"amigos."}}}"#)
                    c.sendText(#"{"serverContent":{"outputTranscription":{"text":"Hello, friends."}}}"#)
                    c.sendText(#"{"serverContent":{"turnComplete":true}}"#)
                }
            }
        }
        var cfg = SonioxConfig(); cfg.languageHints = ["es"]; cfg.translation = .oneWay(target: "en")
        let stream = GeminiTranslateStream(apiKey: "AIza-test", config: cfg, base: server.url)
        let got = collect(stream)
        await stream.start()
        await stream.send(Data(count: 3200))
        let done = await waitUntil(5) { got.segments.first?.translation == "Hello, friends." }
        XCTAssertTrue(done, "segments: \(got.segments)")
        XCTAssertEqual(got.segments.first?.original, "Hola, amigos.")
        XCTAssertTrue(got.states.contains(.live))
        await stream.stop()

        let texts = server.connections.first?.texts ?? []
        let setup = try XCTUnwrap(texts.first.flatMap { JSON.object(Data($0.utf8)) }?["setup"] as? [String: Any])
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-live-translate-preview")
        let gen = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        XCTAssertEqual((gen["translationConfig"] as? [String: Any])?["targetLanguageCode"] as? String, "en")
        let audio = try XCTUnwrap(texts.compactMap { JSON.object(Data($0.utf8)) }.first { $0["realtimeInput"] != nil })
        let a = try XCTUnwrap((audio["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any])
        XCTAssertEqual(a["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(Data(base64Encoded: a["data"] as? String ?? "")?.count, 3200)
    }

    func testReconnectsWhenTheServerEndsTheSession() async throws {
        Trace.fileEnabled = false
        let server = MockSonioxServer()
        try server.start()
        defer { server.stop() }
        server.onConnection = { conn in
            conn.onText = { c, text in
                guard text.contains("\"setup\"") else { return }
                c.sendText(#"{"setupComplete":{}}"#)
                if c.index == 0 { c.sendText(#"{"goAway":{"timeLeft":"1s"}}"#) }
            }
        }
        var cfg = SonioxConfig(); cfg.translation = .oneWay(target: "en")
        let stream = GeminiTranslateStream(apiKey: "k", config: cfg, base: server.url)
        let got = collect(stream)
        await stream.start()
        let renewed = await waitUntil(5) { server.connections.count >= 2 }
        XCTAssertTrue(renewed, "a new session is opened after goAway")
        XCTAssertTrue(got.states.contains(.reconnecting))
        await stream.stop()
    }
}
