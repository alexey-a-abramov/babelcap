import Foundation
import SonioxClient

/// OpenAI gpt-realtime-translate: /v1/realtime/translations, base64 PCM16 24 kHz in; source and translated transcript
/// deltas out (append-only, no utterance ids — lines are closed at sentence ends).
public actor OpenAITranslateStream: SpeechStream {
    public nonisolated let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation
    private let apiKey: String
    private let config: SonioxConfig
    private let url: URL
    private var ws: URLSessionWebSocketTask?
    private var emitter: Emitter
    private var receiveTask: Task<Void, Never>?
    private var ended = false
    private var pending = Data()     // 24 kHz bytes not yet sent (sent in 200 ms chunks)

    public init(apiKey: String, config: SonioxConfig,
                url: URL = URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!) {
        self.apiKey = apiKey; self.config = config; self.url = url
        var c: AsyncStream<SonioxEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        emitter = Emitter(continuation: c)
    }

    static func sessionUpdate(_ config: SonioxConfig) -> [String: Any] {
        let target = config.targetLanguages.first ?? "en"
        return ["type": "session.update",
                "session": ["audio": ["output": ["language": target],
                                      "input": ["transcription": ["model": "gpt-live-transcribe"]]]]]
    }

    /// 16 kHz → 24 kHz PCM16 by linear interpolation (speech-band quality is fine for recognition).
    static func upsample(_ chunk: Data) -> Data {
        let n = chunk.count / 2
        guard n > 1 else { return chunk }
        var out = [Int16](repeating: 0, count: n * 3 / 2)
        chunk.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in out.indices {
                let pos = Double(i) * 2.0 / 3.0
                let j = Int(pos), f = pos - Double(j)
                let a = Double(s[min(j, n - 1)]), b = Double(s[min(j + 1, n - 1)])
                out[i] = Int16(max(-32768, min(32767, (a + (b - a) * f).rounded())))
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public func start() async {
        continuation.yield(.state(.connecting))
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        ws = task
        task.resume()
        try? await task.send(.string(JSON.string(Self.sessionUpdate(config))))
        receiveTask = Task { await self.receiveLoop(task) }
    }

    public func send(_ chunk: Data) async {
        guard let ws, !ended else { return }
        pending.append(Self.upsample(chunk))
        while pending.count >= 9600 {   // 200 ms at 24 kHz mono 16-bit
            let piece = pending.prefix(9600)
            pending.removeFirst(9600)
            let msg = ["type": "session.input_audio_buffer.append", "audio": piece.base64EncodedString()]
            try? await ws.send(.string(JSON.string(msg)))
        }
    }

    public func finalize() async {}

    public func stop() async {
        if let ws, !ended {
            try? await ws.send(.string(#"{"type":"session.close"}"#))
            for _ in 0..<60 where !ended { try? await Task.sleep(for: .milliseconds(100)) }
            ws.cancel(with: .normalClosure, reason: nil)
        }
        receiveTask?.cancel()
        continuation.yield(.finished)
        continuation.yield(.state(.closed))
        continuation.finish()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            guard let msg = try? await task.receive() else {
                if !ended { continuation.yield(errorEvent(503, "OpenAI: connection closed (code \(task.closeCode.rawValue))")) }
                break
            }
            guard let obj = JSON.object(msg) else { continue }
            handle(obj)
            if ended { break }
        }
    }

    private var sourceLine = ""
    private var targetLine = ""

    func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String ?? "" {
        case "session.created", "session.updated":
            continuation.yield(.state(.live))
        case "session.input_transcript.delta":
            let d = obj["delta"] as? String ?? ""
            sourceLine += d
            emitter.send(finalOriginal: d, endOriginal: Self.endsSentence(sourceLine))
            if Self.endsSentence(sourceLine) { sourceLine = "" }
        case "session.output_transcript.delta":
            let d = obj["delta"] as? String ?? ""
            targetLine += d
            emitter.send(finalTranslation: d, endTranslation: Self.endsSentence(targetLine))
            if Self.endsSentence(targetLine) { targetLine = "" }
        case "session.closed":
            ended = true
        case "error":
            let e = obj["error"] as? [String: Any] ?? [:]
            let code = (e["code"] as? String) == "invalid_api_key" || (e["type"] as? String) == "authentication_error" ? 401 : 500
            continuation.yield(errorEvent(code, "OpenAI: \(e["message"] as? String ?? "error")"))
            if code == 401 { continuation.yield(.state(.failed)) }
        default:
            break
        }
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!…。？！".contains(last)
    }
}
