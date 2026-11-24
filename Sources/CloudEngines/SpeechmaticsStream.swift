import Foundation
import SonioxClient

/// Speechmatics real-time: StartRecognition (+ translation_config), binary audio, AddTranscript / AddTranslation.
public actor SpeechmaticsStream: SpeechStream {
    public nonisolated let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation
    private let apiKey: String
    private let config: SonioxConfig
    private let url: URL
    private var ws: URLSessionWebSocketTask?
    private var emitter: Emitter
    private var receiveTask: Task<Void, Never>?
    private var sent = 0
    private var ended = false
    private var openLine = false
    private var sourceLanguage = "en"

    public init(apiKey: String, config: SonioxConfig, url: URL = URL(string: "wss://global.rt.speechmatics.com/v2/")!) {
        self.apiKey = apiKey; self.config = config; self.url = url
        var c: AsyncStream<SonioxEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        emitter = Emitter(continuation: c)
    }

    static func startMessage(_ config: SonioxConfig) -> [String: Any] {
        let language = config.firstLanguage ?? "en"
        var transcription: [String: Any] = [
            "language": language, "enable_partials": true, "max_delay": 2, "model": "enhanced",
            "diarization": config.enableSpeakerDiarization ? "speaker" : "none",
        ]
        if let terms = config.context?.terms, !terms.isEmpty { transcription["additional_vocab"] = terms }
        var msg: [String: Any] = [
            "message": "StartRecognition",
            "audio_format": ["type": "raw", "encoding": "pcm_s16le", "sample_rate": 16000],
            "transcription_config": transcription,
        ]
        let targets = config.targetLanguages.filter { $0.prefix(2) != language.prefix(2) }
        if !targets.isEmpty { msg["translation_config"] = ["target_languages": targets, "enable_partials": true] }
        return msg
    }

    public func start() async {
        continuation.yield(.state(.connecting))
        sourceLanguage = config.firstLanguage ?? "en"
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        ws = task
        task.resume()
        try? await task.send(.string(JSON.string(Self.startMessage(config))))
        receiveTask = Task { await self.receiveLoop(task) }
    }

    public func send(_ chunk: Data) async {
        guard let ws, !ended else { return }
        if (try? await ws.send(.data(chunk))) != nil { sent += 1 }
    }

    public func finalize() async {}

    public func stop() async {
        if let ws, !ended {
            try? await ws.send(.string(JSON.string(["message": "EndOfStream", "last_seq_no": sent])))
            for _ in 0..<80 where !ended { try? await Task.sleep(for: .milliseconds(100)) }
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
                if !ended { continuation.yield(errorEvent(503, "Speechmatics: connection closed (code \(task.closeCode.rawValue))")) }
                break
            }
            guard let obj = JSON.object(msg) else { continue }
            handle(obj)
            if ended { break }
        }
    }

    static func speaker(_ results: [[String: Any]]) -> String? {
        for r in results {
            if let alt = (r["alternatives"] as? [[String: Any]])?.first, let s = alt["speaker"] as? String {
                return String(s.filter(\.isNumber)).nilIfEmpty
            }
        }
        return nil
    }

    func handle(_ obj: [String: Any]) {
        let message = obj["message"] as? String ?? ""
        let results = obj["results"] as? [[String: Any]] ?? []
        switch message {
        case "RecognitionStarted":
            continuation.yield(.state(.live))
        case "AddPartialTranscript":
            emitter.draftOriginal = (obj["metadata"] as? [String: Any])?["transcript"] as? String ?? ""
            emitter.draftSpeaker = Self.speaker(results)
            emitter.send()
        case "AddTranscript":
            let text = ((obj["metadata"] as? [String: Any])?["transcript"] as? String ?? "")
            let eos = results.contains { $0["is_eos"] as? Bool == true }
            emitter.draftOriginal = ""
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { openLine = true }
            emitter.send(finalOriginal: text, language: sourceLanguage, speaker: Self.speaker(results), endOriginal: eos && openLine)
            if eos { openLine = false }
        case "AddPartialTranslation":
            emitter.draftTranslation = results.compactMap { $0["content"] as? String }.joined(separator: " ")
            emitter.send()
        case "AddTranslation":
            let text = results.compactMap { $0["content"] as? String }.joined(separator: " ")
            emitter.draftTranslation = ""
            emitter.send(finalTranslation: text, endTranslation: !text.isEmpty)
        case "EndOfTranscript":
            ended = true
        case "Error":
            let type = obj["type"] as? String ?? "error"
            let code = type == "not_authorised" ? 401 : type == "quota_exceeded" ? 429 : 500
            continuation.yield(errorEvent(code, "Speechmatics: \(obj["reason"] as? String ?? type)"))
            if code == 401 { continuation.yield(.state(.failed)) }
            ended = true
        case "Warning":
            if let reason = obj["reason"] as? String { continuation.yield(errorEvent(0, "Speechmatics: \(reason)")) }
        default:
            break
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
