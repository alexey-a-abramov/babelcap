import Foundation
import MicrosoftCognitiveServicesSpeech
import SonioxClient

/// Azure AI Speech translation via Microsoft's Speech SDK (the only supported way — the service's WebSocket protocol
/// is not documented). Push-stream audio in; recognizing (draft) and recognized (final) events with translations out.
/// The Keychain item holds "region|key", e.g. "westeurope|abc123".
public final class AzureTranslateStream: SpeechStream, @unchecked Sendable {
    public let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation
    private let credential: String
    private let config: SonioxConfig
    private let lock = NSLock()
    private var recognizer: SPXTranslationRecognizer?
    private var stream: SPXPushAudioInputStream?
    private var stopped = false

    public init(credential: String, config: SonioxConfig) {
        self.credential = credential; self.config = config
        var c: AsyncStream<SonioxEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    /// "region|key" → (region, key). A bare key defaults to West Europe.
    public static func split(_ credential: String) -> (region: String, key: String) {
        let parts = credential.split(separator: "|", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? (parts[0], parts[1]) : ("westeurope", credential)
    }

    /// Azure wants a full locale for recognition.
    static let locales = ["en": "en-US", "ru": "ru-RU", "he": "he-IL", "de": "de-DE", "fr": "fr-FR", "es": "es-ES", "it": "it-IT",
                          "pt": "pt-BR", "uk": "uk-UA", "ar": "ar-SA", "tr": "tr-TR", "pl": "pl-PL", "nl": "nl-NL",
                          "zh": "zh-CN", "ja": "ja-JP", "ko": "ko-KR", "hi": "hi-IN"]

    public func start() async {
        continuation.yield(.state(.connecting))
        let (region, key) = Self.split(credential)
        let source = config.languageHints?.first ?? "en"
        let targets = config.targetLanguages.filter { $0.prefix(2) != source.prefix(2) }
        do {
            let cfg = try SPXSpeechTranslationConfiguration(subscription: key, region: region)
            cfg.speechRecognitionLanguage = Self.locales[String(source.prefix(2))] ?? source
            for t in targets { cfg.addTargetLanguage(t) }
            guard let format = SPXAudioStreamFormat(usingPCMWithSampleRate: 16000, bitsPerSample: 16, channels: 1),
                  let push = SPXPushAudioInputStream(audioFormat: format),
                  let audio = SPXAudioConfiguration(streamInput: push) else { throw AzureError.setup }
            let r = try SPXTranslationRecognizer(speechTranslationConfiguration: cfg, audioConfiguration: audio)
            let lang = source
            let target = targets.first
            r.addRecognizingEventHandler { [weak self] _, e in
                self?.emit(text: e.result.text, translation: target.flatMap { e.result.translations[$0] as? String }, final: false, language: lang)
            }
            r.addRecognizedEventHandler { [weak self] _, e in
                self?.emit(text: e.result.text, translation: target.flatMap { e.result.translations[$0] as? String }, final: true, language: lang)
            }
            r.addCanceledEventHandler { [weak self] _, e in
                guard let self, e.reason == SPXCancellationReason.error else { return }
                let auth = e.errorCode == SPXCancellationErrorCode.authenticationFailure
                self.continuation.yield(.error(SonioxError(code: auth ? 401 : 503, message: "Azure: \(e.errorDetails ?? "cancelled")")))
                if auth { self.continuation.yield(.state(.failed)) }
            }
            try r.startContinuousRecognition()
            lock.withLock { recognizer = r; stream = push }
            continuation.yield(.state(.live))
        } catch {
            continuation.yield(.error(SonioxError(code: 1000, message: "Azure: \(error.localizedDescription)")))
            continuation.yield(.state(.failed))
        }
    }

    // Drafts are replaced on every event; finals close the line on both tracks.
    func emit(text: String?, translation: String?, final: Bool, language: String) {
        let batch = Self.tokens(text: text ?? "", translation: translation ?? "", final: final, language: language)
        if !batch.isEmpty { continuation.yield(.tokens(batch)) }
    }

    static func tokens(text: String, translation: String, final: Bool, language: String) -> [SonioxToken] {
        let t = text.trimmingCharacters(in: .whitespaces), tr = translation.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty || !tr.isEmpty else { return [] }
        if !final {
            var out = [SonioxToken(text: t, isFinal: false, language: language, translationStatus: "original")]
            if !tr.isEmpty { out.append(SonioxToken(text: tr, isFinal: false, translationStatus: "translation")) }
            return out
        }
        var out = [SonioxToken(text: t, isFinal: true, language: language, translationStatus: "original"),
                   SonioxToken(text: "<end>", isFinal: true, translationStatus: "original")]
        if !tr.isEmpty {
            out.append(SonioxToken(text: tr, isFinal: true, translationStatus: "translation"))
            out.append(SonioxToken(text: "<end>", isFinal: true, translationStatus: "translation"))
        }
        return out
    }

    public func send(_ chunk: Data) async {
        let s = lock.withLock { stopped ? nil : stream }
        s?.write(chunk)
    }

    public func finalize() async {}

    public func stop() async {
        let (s, r) = lock.withLock { stopped = true; return (stream, recognizer) }
        s?.close()
        try? r?.stopContinuousRecognition()
        continuation.yield(.finished)
        continuation.yield(.state(.closed))
        continuation.finish()
    }
}

enum AzureError: LocalizedError {
    case setup
    var errorDescription: String? { "Could not set up the Azure audio stream" }
}

extension SonioxConfig {
    var targetLanguages: [String] {
        switch translation {
        case nil: []
        case let .oneWay(t)?: [t]
        case let .twoWay(a, b)?: [a, b]
        }
    }
}
