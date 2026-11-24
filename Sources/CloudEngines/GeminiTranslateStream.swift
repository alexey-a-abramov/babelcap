import Foundation
import SonioxClient

/// Google Gemini Live Translate (gemini-3.5-live-translate-preview): audio in, source and translated transcripts out.
/// Sessions last ~10–15 min; on goAway / disconnect a new session is opened transparently.
public actor GeminiTranslateStream: SpeechStream {
    public nonisolated let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation
    private let apiKey: String
    private let config: SonioxConfig
    private let base: URL
    public static let model = "models/gemini-3.5-live-translate-preview"

    private var ws: URLSessionWebSocketTask?
    private var emitter: Emitter
    private var receiveTask: Task<Void, Never>?
    private var stopping = false
    private var sourceLine = ""
    private var targetLine = ""
    private var reconnects = 0

    public init(apiKey: String, config: SonioxConfig,
                base: URL = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!) {
        self.apiKey = apiKey; self.config = config; self.base = base
        var c: AsyncStream<SonioxEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        emitter = Emitter(continuation: c)
    }

    static func setupMessage(_ config: SonioxConfig) -> [String: Any] {
        let target = config.targetLanguages.first ?? "en"
        var inputTranscription: [String: Any] = [:]
        if let hints = config.languageHints, !hints.isEmpty { inputTranscription["languageCodes"] = hints }
        return ["setup": [
            "model": model,
            "inputAudioTranscription": inputTranscription,
            "outputAudioTranscription": [String: Any](),
            "generationConfig": ["responseModalities": ["AUDIO"],
                                 "translationConfig": ["targetLanguageCode": target, "echoTargetLanguage": false]],
        ]]
    }

    public func start() async {
        continuation.yield(.state(.connecting))
        await connect()
    }

    private func connect() async {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "key", value: apiKey)]
        let task = URLSession.shared.webSocketTask(with: c.url!)
        ws = task
        task.resume()
        try? await task.send(.string(JSON.string(Self.setupMessage(config))))
        receiveTask = Task { await self.receiveLoop(task) }
    }

    public func send(_ chunk: Data) async {
        guard let ws, !stopping else { return }
        let msg: [String: Any] = ["realtimeInput": ["audio": ["data": chunk.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]]
        try? await ws.send(.string(JSON.string(msg)))
    }

    public func finalize() async {
        try? await ws?.send(.string(#"{"realtimeInput":{"audioStreamEnd":true}}"#))
    }

    public func stop() async {
        stopping = true
        if let ws {
            try? await ws.send(.string(#"{"realtimeInput":{"audioStreamEnd":true}}"#))
            try? await Task.sleep(for: .milliseconds(1500))
            ws.cancel(with: .normalClosure, reason: nil)
        }
        receiveTask?.cancel()
        closeLines()
        continuation.yield(.finished)
        continuation.yield(.state(.closed))
        continuation.finish()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            guard let msg = try? await task.receive() else { break }
            guard let obj = JSON.object(msg) else { continue }
            handle(obj)
        }
        // Session ended by the server (time limit / goAway): open a new one unless we are stopping.
        guard !stopping, !Task.isCancelled else { return }
        let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if task.closeCode.rawValue == 1008 || reason.localizedCaseInsensitiveContains("api key") {
            continuation.yield(errorEvent(401, "Gemini: \(reason.isEmpty ? "API key rejected" : reason)"))
            continuation.yield(.state(.failed))
            return
        }
        reconnects += 1
        guard reconnects <= 20 else { continuation.yield(errorEvent(503, "Gemini: too many reconnects")); return }
        closeLines()
        continuation.yield(.state(.reconnecting))
        try? await Task.sleep(for: .milliseconds(300))
        await connect()
    }

    func handle(_ obj: [String: Any]) {
        if obj["setupComplete"] != nil { continuation.yield(.state(.live)); return }
        if obj["goAway"] != nil { ws?.cancel(with: .goingAway, reason: nil); return }
        guard let content = obj["serverContent"] as? [String: Any] else {
            if let err = obj["error"] as? [String: Any] { continuation.yield(errorEvent(500, "Gemini: \(err["message"] as? String ?? "error")")) }
            return
        }
        if let t = (content["inputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty {
            sourceLine += t
            let lang = (content["inputTranscription"] as? [String: Any])?["languageCode"] as? String
            emitter.send(finalOriginal: t, language: lang, endOriginal: Self.endsSentence(sourceLine))
            if Self.endsSentence(sourceLine) { sourceLine = "" }
        }
        if let t = (content["outputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty {
            targetLine += t
            emitter.send(finalTranslation: t, endTranslation: Self.endsSentence(targetLine))
            if Self.endsSentence(targetLine) { targetLine = "" }
        }
        if content["turnComplete"] as? Bool == true { closeLines() }
    }

    /// End of a turn: close whatever line is still open on both tracks.
    private func closeLines() {
        if !sourceLine.isEmpty { emitter.send(endOriginal: true); sourceLine = "" }
        if !targetLine.isEmpty { emitter.send(endTranslation: true); targetLine = "" }
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!…。？！".contains(last)
    }
}
