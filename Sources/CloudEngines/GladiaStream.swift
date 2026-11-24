import Foundation
import SonioxClient

/// Gladia Solaria Live v2: POST /v2/live (x-gladia-key) → WebSocket URL; binary PCM in; transcript + translation out.
public actor GladiaStream: SpeechStream {
    public nonisolated let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation
    private let apiKey: String
    private let config: SonioxConfig
    private let base: URL
    private let session: URLSession
    private var ws: URLSessionWebSocketTask?
    private var emitter: Emitter
    private var receiveTask: Task<Void, Never>?
    private var ended = false

    public init(apiKey: String, config: SonioxConfig, base: URL = URL(string: "https://api.gladia.io")!, session: URLSession = .shared) {
        self.apiKey = apiKey; self.config = config; self.base = base; self.session = session
        var c: AsyncStream<SonioxEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        emitter = Emitter(continuation: c)
    }

    /// The init body (exposed for tests).
    static func initBody(_ config: SonioxConfig) -> [String: Any] {
        var body: [String: Any] = [
            "encoding": "wav/pcm", "bit_depth": 16, "sample_rate": 16000, "channels": 1,
            "endpointing": 0.3,
            "language_config": ["languages": config.languageHints ?? [], "code_switching": (config.languageHints?.count ?? 0) != 1],
            "messages_config": ["receive_partial_transcripts": true, "receive_final_transcripts": true,
                                "receive_realtime_processing_events": true],
        ]
        if !config.targetLanguages.isEmpty {
            body["realtime_processing"] = ["translation": true, "translation_config": ["target_languages": config.targetLanguages]]
        }
        return body
    }

    public func start() async {
        continuation.yield(.state(.connecting))
        do {
            var req = URLRequest(url: base.appendingPathComponent("v2/live"))
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: Self.initBody(config))
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), let obj = JSON.object(data), let s = obj["url"] as? String, let url = URL(string: s) else {
                let msg = JSON.object(data)?["message"] as? String ?? "HTTP \(code)"
                continuation.yield(errorEvent(code == 401 ? 401 : code == 402 ? 402 : max(code, 500), "Gladia: \(msg)"))
                continuation.yield(.state(.failed))
                return
            }
            let task = session.webSocketTask(with: url)
            ws = task
            task.resume()
            continuation.yield(.state(.live))
            receiveTask = Task { await self.receiveLoop(task) }
        } catch {
            continuation.yield(errorEvent(503, "Gladia: \(error.localizedDescription)"))
            continuation.yield(.state(.failed))
        }
    }

    public func send(_ chunk: Data) async { try? await ws?.send(.data(chunk)) }

    public func finalize() async {}

    public func stop() async {
        if let ws {
            try? await ws.send(.string(#"{"type":"stop_recording"}"#))
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
            guard let msg = try? await task.receive() else { break }
            guard let obj = JSON.object(msg) else { continue }
            handle(obj)
            if ended { break }
        }
    }

    func handle(_ obj: [String: Any]) {
        let type = obj["type"] as? String ?? ""
        let data = obj["data"] as? [String: Any] ?? [:]
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String {
            continuation.yield(errorEvent(Int("\(err["status_code"] ?? 500)") ?? 500, "Gladia: \(m)"))
        }
        switch type {
        case "transcript":
            let u = data["utterance"] as? [String: Any] ?? [:]
            let text = (u["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let lang = u["language"] as? String
            if data["is_final"] as? Bool == true {
                emitter.draftOriginal = ""
                emitter.send(finalOriginal: text, language: lang, endOriginal: !text.isEmpty)
            } else {
                emitter.draftOriginal = text
                emitter.send()
            }
        case "translation":
            let tu = data["translated_utterance"] as? [String: Any] ?? [:]
            let target = data["target_language"] as? String
            let original = data["original_language"] as? String
            // Two-way asks for both languages; skip the "translation" into the language that was spoken.
            if let target, let original, target.prefix(2) == original.prefix(2) { return }
            let text = (tu["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            emitter.send(finalTranslation: text, endTranslation: !text.isEmpty)
        case "end_session":
            ended = true
        default:
            break
        }
    }
}
