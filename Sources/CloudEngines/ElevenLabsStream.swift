import Foundation
import LocalEngines
import SonioxClient

/// ElevenLabs Scribe realtime (recognition only) + a text translator for each committed line — cloud ASR,
/// translation by TranslateGemma / Apple on this Mac.
public actor ElevenLabsStream: SpeechStream {
    public nonisolated let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation
    private let apiKey: String
    private let config: SonioxConfig
    private let url: URL
    private let translator: (any TextTranslator)?
    private var ws: URLSessionWebSocketTask?
    private var emitter: Emitter
    private var receiveTask: Task<Void, Never>?
    private var ended = false
    private var language: String?
    private var warned = false

    public static func url(_ config: SonioxConfig, host: String = "wss://api.elevenlabs.io") -> URL {
        var c = URLComponents(string: host + "/v1/speech-to-text/realtime")!
        var q = [URLQueryItem(name: "model_id", value: "scribe_v3_live"),
                 URLQueryItem(name: "audio_format", value: "pcm_16000"),
                 URLQueryItem(name: "commit_strategy", value: "vad"),
                 URLQueryItem(name: "include_language_detection", value: "true")]
        if let hints = config.languageHints, hints.count == 1 { q.append(URLQueryItem(name: "language_code", value: hints[0])) }
        if config.enableSpeakerDiarization { q.append(URLQueryItem(name: "diarize", value: "true")) }
        c.queryItems = q
        return c.url!
    }

    public init(apiKey: String, config: SonioxConfig, translator: (any TextTranslator)?, url: URL? = nil) {
        self.apiKey = apiKey; self.config = config; self.translator = translator
        self.url = url ?? Self.url(config)
        var c: AsyncStream<SonioxEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        emitter = Emitter(continuation: c)
    }

    public func start() async {
        continuation.yield(.state(.connecting))
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let task = URLSession.shared.webSocketTask(with: req)
        ws = task
        task.resume()
        receiveTask = Task { await self.receiveLoop(task) }
    }

    private func chunkMessage(_ chunk: Data, commit: Bool) -> String {
        JSON.string(["message_type": "input_audio_chunk", "audio_base_64": chunk.base64EncodedString(),
                     "commit": commit, "sample_rate": 16000])
    }

    public func send(_ chunk: Data) async {
        guard let ws, !ended else { return }
        try? await ws.send(.string(chunkMessage(chunk, commit: false)))
    }

    public func finalize() async {
        try? await ws?.send(.string(chunkMessage(Data(count: 3200), commit: true)))
    }

    public func stop() async {
        if let ws, !ended {
            try? await ws.send(.string(chunkMessage(Data(count: 3200), commit: true)))
            try? await Task.sleep(for: .milliseconds(1500))   // let the last committed line (and its translation) arrive
            ended = true
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
                if !ended { continuation.yield(errorEvent(503, "ElevenLabs: connection closed (code \(task.closeCode.rawValue))")) }
                break
            }
            guard let obj = JSON.object(msg) else { continue }
            await handle(obj)
        }
    }

    func handle(_ obj: [String: Any]) async {
        let type = obj["message_type"] as? String ?? ""
        switch type {
        case "session_started":
            continuation.yield(.state(.live))
        case "partial_transcript":
            if let l = obj["language_code"] as? String { language = l }
            emitter.draftOriginal = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            emitter.send()
        case "committed_transcript":
            let text = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            emitter.draftOriginal = ""
            guard !text.isEmpty else { emitter.send(); return }
            let lang = language ?? config.languageHints?.first
            emitter.send(finalOriginal: text, language: lang, endOriginal: true)
            await translate(text, from: lang)
        case "committed_transcript_with_timestamps":
            if let l = obj["language_code"] as? String { language = l }
        default:
            if let err = obj["error"] as? String {
                let code = switch type {
                case "auth_error": 401
                case "quota_exceeded": 402
                case "rate_limited", "resource_exhausted": 429
                default: 500
                }
                continuation.yield(errorEvent(code, "ElevenLabs: \(err)"))
                if code == 401 || code == 402 { continuation.yield(.state(.failed)) }
            }
        }
    }

    private func translate(_ text: String, from source: String?) async {
        guard let target = config.targetLanguages.first(where: { $0.prefix(2) != (source ?? "").prefix(2) }) else { return }
        guard let translator else {
            if !warned { warned = true; continuation.yield(errorEvent(0, "ElevenLabs only transcribes: pick a translator in Models & Providers.")) }
            return
        }
        do {
            let t = try await translator.translate(text, from: source, to: target)
            emitter.send(finalTranslation: t, endTranslation: true)
        } catch {
            if !warned { warned = true; continuation.yield(errorEvent(0, await translator.problem(from: source, to: target) ?? error.localizedDescription)) }
        }
    }
}
