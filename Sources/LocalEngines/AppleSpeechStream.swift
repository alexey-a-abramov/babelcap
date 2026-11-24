@preconcurrency import AVFoundation
import Foundation
import Speech
import SonioxClient

/// Apple's on-device recogniser (SpeechAnalyzer + SpeechTranscriber, macOS 26) with Apple Translation on top.
/// No key, no cost, no audio leaves the Mac. One spoken language per session: the first language hint.
@available(macOS 26.0, *)
public actor AppleSpeechStream: SpeechStream {
    public nonisolated let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation
    private let config: SonioxConfig

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var resultsTask: Task<Void, Never>?
    private var emitter = TokenEmitter()
    private var language = "en"
    private var target: String?
    private var sentence = ""            // finalised text waiting for a sentence end
    private var lastFinalAt = Date()
    private var draftTranslateTask: Task<Void, Never>?
    private var lastDraftTranslation = Date.distantPast
    private var translationWarned = false
    private var started = false

    public init(config: SonioxConfig) {
        self.config = config
        var c: AsyncStream<SonioxEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public func start() async {
        guard !started else { return }
        started = true
        continuation.yield(.state(.connecting))
        do {
            let wanted = config.languageHints?.first ?? "en"
            let supported = await SpeechTranscriber.supportedLocales
            let code = String(wanted.prefix(2)).lowercased()
            guard supported.contains(where: { $0.language.languageCode?.identifier == code }),
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: wanted)) else {
                let names = Set(supported.compactMap { $0.language.languageCode?.identifier }).sorted()
                    .compactMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }.joined(separator: ", ")
                throw LocalEngineError.unsupportedLanguage("Apple's on-device recogniser has no model for \(Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code). It supports: \(names). Use Whisper or Soniox for this language.")
            }
            language = locale.language.languageCode?.identifier ?? wanted
            target = config.translationTarget(forSource: language)
            if sameLanguage(target, language) { target = nil }

            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            transcriber = t
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                Trace.log("apple-speech", "installing speech assets for \(locale.identifier)")
                try await request.downloadAndInstall()
            }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) ?? sourceFormat
            analyzerFormat = format
            if format != sourceFormat { converter = AVAudioConverter(from: sourceFormat, to: format) }

            let (stream, c) = AsyncStream<AnalyzerInput>.makeStream()
            input = c
            let a = SpeechAnalyzer(modules: [t])
            analyzer = a
            try await a.start(inputSequence: stream)
            resultsTask = Task { [weak self] in
                do {
                    for try await r in t.results { await self?.handle(text: String(r.text.characters), isFinal: r.isFinal) }
                } catch {
                    await self?.fail(error)
                }
            }
            if let target, await AppleTranslator.readiness(from: language, to: target) != .installed {
                warnTranslation(target)
            }
            Trace.log("apple-speech", "live: \(locale.identifier), translate → \(target ?? "off"), format \(format.sampleRate) Hz")
            continuation.yield(.state(.live))
        } catch {
            fail(error)
        }
    }

    public func send(_ chunk: Data) async {
        guard let input, let analyzerFormat else { return }
        let frames = AVAudioFrameCount(chunk.count / 2)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { return }
        buf.frameLength = frames
        chunk.withUnsafeBytes { raw in
            buf.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        if let converter {
            let cap = AVAudioFrameCount(Double(frames) * analyzerFormat.sampleRate / 16_000) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: cap) else { return }
            nonisolated(unsafe) var supplied = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buf
            }
            if err == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
        } else {
            input.yield(AnalyzerInput(buffer: buf))
        }
        // A long pause also closes a sentence that never got punctuation.
        if !sentence.isEmpty, Date().timeIntervalSince(lastFinalAt) > 2.0 { await closeSentence() }
    }

    public func finalize() async {
        try? await analyzer?.finalize(through: nil)
        await closeSentence()
    }

    public func stop() async {
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await resultsTask?.value
        await closeSentence()
        continuation.yield(.finished)
        continuation.yield(.state(.closed))
        continuation.finish()
    }

    // MARK: Results

    private func handle(text: String, isFinal: Bool) async {
        if isFinal {
            emitter.draftOriginal = ""
            emitter.draftTranslation = ""
            let piece = text.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { return }
            sentence += (sentence.isEmpty ? "" : " ") + piece
            lastFinalAt = Date()
            continuation.yield(.tokens(emitter.batch(finalOriginal: (sentence == piece ? "" : " ") + piece, language: language)))
            if let last = piece.last, ".?!…。".contains(last) { await closeSentence() }
        } else {
            emitter.draftOriginal = text
            emitter.draftLanguage = language
            continuation.yield(.tokens(emitter.batch()))
            translateDraftThrottled(text)
        }
    }

    /// Ends the current segment and attaches its translation.
    private func closeSentence() async {
        let text = sentence
        sentence = ""
        guard !text.isEmpty else { return }
        continuation.yield(.tokens(emitter.batch(endOriginal: true)))
        guard let target else { return }
        do {
            let tr = try await AppleTranslator.shared.translate(text, from: language, to: target)
            emitter.draftTranslation = ""
            continuation.yield(.tokens(emitter.batch(finalTranslation: tr, endTranslation: true)))
        } catch {
            warnTranslation(target)
        }
    }

    private func translateDraftThrottled(_ text: String) {
        guard let target, Date().timeIntervalSince(lastDraftTranslation) > 0.8, draftTranslateTask == nil else { return }
        lastDraftTranslation = Date()
        let source = language, current = sentence.isEmpty ? text : sentence + " " + text
        draftTranslateTask = Task { [weak self] in
            let tr = try? await AppleTranslator.shared.translate(current, from: source, to: target)
            await self?.setDraftTranslation(tr)
        }
    }

    private func setDraftTranslation(_ tr: String?) {
        draftTranslateTask = nil
        guard let tr, !emitter.draftOriginal.isEmpty else { return }
        emitter.draftTranslation = tr
        continuation.yield(.tokens(emitter.batch()))
    }

    private func warnTranslation(_ target: String) {
        guard !translationWarned else { return }
        translationWarned = true
        let source = language
        Task { [continuation] in
            continuation.yield(.error(SonioxError(code: 0, message: await LocalTranslationHelp.explain(source: source, target: target))))
        }
    }

    private func fail(_ error: Error) {
        Trace.log("apple-speech", "failed: \(error.localizedDescription)")
        continuation.yield(.error(SonioxError(code: 1000, message: error.localizedDescription)))
        continuation.yield(.state(.failed))
    }
}

public enum LocalEngineError: LocalizedError {
    case unsupportedLanguage(String)
    case modelMissing(String)
    case needsNewerMacOS(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedLanguage(m): m
        case let .modelMissing(m): m
        case let .needsNewerMacOS(v): "This engine needs macOS \(v) or newer."
        }
    }
}
