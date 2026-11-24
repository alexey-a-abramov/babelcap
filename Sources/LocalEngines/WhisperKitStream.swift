import CoreML
import Foundation
import SonioxClient
@preconcurrency import WhisperKit

/// FIFO async mutex: actors are re-entrant across `await`, so they cannot serialise long async work by themselves.
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Keeps one Whisper model loaded (loading takes seconds; a second model would double the memory), and runs
/// inference one call at a time — in Both mode the System and Mic streams share the model.
public actor WhisperKitPool {
    private let gate = AsyncLock()
    /// GPU by default: the Neural Engine needs a one-time compile per model that can take minutes on first load.
    nonisolated(unsafe) public static var useNeuralEngine = ProcessInfo.processInfo.environment["SUBVEIL_WHISPER_ANE"] != nil

    /// Serialised inference on the shared model.
    public func transcribe(_ pipe: WhisperKit, audio: [Float], options: DecodingOptions) async throws -> [TranscriptionResult] {
        await gate.lock()
        do {
            let r = try await pipe.transcribe(audioArray: audio, decodeOptions: options)
            await gate.unlock()
            return r
        } catch {
            await gate.unlock()
            throw error
        }
    }

    public static let shared = WhisperKitPool()
    private var loaded: (path: String, pipe: WhisperKit)?

    private var loading: (path: String, task: Task<WhisperKit, Error>)?

    public func pipe(modelFolder: URL) async throws -> WhisperKit {
        if let l = loaded, l.path == modelFolder.path { return l.pipe }
        // Both streams of a session start together: share one load instead of loading the model twice.
        if let l = loading, l.path == modelFolder.path { return try await l.task.value }
        if let l = loaded { await l.pipe.unloadModels(); loaded = nil }
        guard FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("config.json").path) else {
            throw LocalEngineError.modelMissing("The Whisper model is not downloaded yet. Open Models & Providers and download it.")
        }
        let path = modelFolder.path
        let task = Task<WhisperKit, Error> {
            let started = Date()
            let units: MLComputeUnits = WhisperKitPool.useNeuralEngine ? .cpuAndNeuralEngine : .cpuAndGPU
            let compute = ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: units, textDecoderCompute: units)
            let config = WhisperKitConfig(modelFolder: path, computeOptions: compute, verbose: false, logLevel: .none,
                                          prewarm: false, load: true, download: false)
            let pipe = try await WhisperKit(config)
            Trace.log("whisperkit", "loaded \(modelFolder.lastPathComponent) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            return pipe
        }
        loading = (path, task)
        defer { loading = nil }
        let pipe = try await task.value
        loaded = (path, pipe)
        return pipe
    }

    public func unload() async {
        if let l = loaded { await l.pipe.unloadModels() }
        loaded = nil
    }
}

/// Whisper (Core ML via WhisperKit) as a live stream.
///
/// Whisper is not natively streaming. The current utterance (audio since the last pause) is re-transcribed about every
/// 0.7 s; words that two consecutive passes agree on are committed right away (LocalAgreement-2), the rest is shown as
/// a draft. A committed sentence (ending in . ? !) becomes its own line and is translated immediately by the text
/// translator (Apple Translation or a local LLM). After a 0.6 s pause the utterance is transcribed once more and closed.
/// Without a text translator, Whisper's own audio translation into English is used per utterance.
public actor WhisperKitStream: SpeechStream {
    public nonisolated let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation
    private let config: SonioxConfig
    private let modelFolder: URL
    /// turbo / distil models were not trained for Whisper's translate task.
    private let whisperTranslates: Bool
    private let translator: (any TextTranslator)?

    static let rate = 16_000
    private let silenceThreshold: Float = 0.012
    private let endOfUtteranceSilence = Int(0.6 * Double(rate))
    private let maxUtterance = 20 * rate
    private let passEvery: TimeInterval = 0.7

    private var pipe: WhisperKit?
    private var samples: [Float] = []
    private var speechSeen = false
    private var silenceRun = 0
    private var lastPassAt = Date.distantPast
    private var passBusy = false
    private var started = false
    private var warned = false

    // Utterance state (LocalAgreement)
    private var utteranceID = 0
    private var previousHypothesis: [String] = []
    private var committedWords = 0              // words of this utterance already emitted as final
    private var openSentence: [String] = []     // committed words not yet closed as a line
    private var language: String?

    // Committed utterances waiting for their final pass, processed in order.
    private struct Pending { let audio: [Float]; let committed: Int; let openSentence: [String]; let language: String? }
    private var queue: [Pending] = []
    private var processing = false
    private var emitter = TokenEmitter()

    public init(modelFolder: URL, config: SonioxConfig, whisperTranslates: Bool = true, translator: (any TextTranslator)? = nil) {
        self.modelFolder = modelFolder
        self.config = config
        self.whisperTranslates = whisperTranslates
        self.translator = translator
        var c: AsyncStream<SonioxEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public func start() async {
        guard !started else { return }
        started = true
        continuation.yield(.state(.connecting))
        do {
            pipe = try await WhisperKitPool.shared.pipe(modelFolder: modelFolder)
            continuation.yield(.state(.live))
        } catch {
            Trace.log("whisperkit", "load failed: \(error.localizedDescription)")
            continuation.yield(.error(SonioxError(code: 1000, message: error.localizedDescription)))
            continuation.yield(.state(.failed))
        }
    }

    public func send(_ chunk: Data) async {
        guard pipe != nil else { return }
        var floats = [Float](repeating: 0, count: chunk.count / 2)
        chunk.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in floats.indices { floats[i] = Float(s[i]) / 32768 }
        }
        var sum: Float = 0
        for v in floats { sum += v * v }
        let rms = (sum / Float(max(1, floats.count))).squareRoot()

        samples.append(contentsOf: floats)
        if rms > silenceThreshold { speechSeen = true; silenceRun = 0 } else { silenceRun += floats.count }

        if !speechSeen {
            if samples.count > Self.rate / 2 { samples.removeFirst(samples.count - Self.rate / 4) }
            return
        }
        if (silenceRun >= endOfUtteranceSilence && samples.count >= Self.rate * 3 / 4) || samples.count >= maxUtterance {
            commitUtterance()
            return
        }
        // Agreement passes at most every 0.7 s of wall time; committing finished utterances comes first.
        if !passBusy, !processing, Date().timeIntervalSince(lastPassAt) >= passEvery, samples.count >= Self.rate / 2 {
            lastPassAt = Date()
            await agreementPass()
        }
    }

    public func finalize() async {
        if speechSeen { commitUtterance() }
        await drain()
    }

    public func stop() async {
        if speechSeen { commitUtterance() }
        await drain()
        continuation.yield(.finished)
        continuation.yield(.state(.closed))
        continuation.finish()
    }

    // MARK: Streaming

    private var fixedLanguage: String? {
        guard let hints = config.languageHints, hints.count == 1 else { return nil }
        return hints[0]
    }

    private func options(_ task: DecodingTask, language: String?) -> DecodingOptions {
        DecodingOptions(verbose: false, task: task, language: language, temperature: 0, usePrefillPrompt: true,
                        detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: true)
    }

    /// Text translation is used when a translator is set (and needed); otherwise Whisper translates audio per utterance.
    private var translatesText: Bool { translator != nil && config.translation != nil }

    private func agreementPass() async {
        guard let pipe else { return }
        passBusy = true
        defer { passBusy = false }
        let id = utteranceID
        let audio = samples
        guard let r = try? await WhisperKitPool.shared.transcribe(pipe, audio: audio, options: options(.transcribe, language: language ?? fixedLanguage)),
              id == utteranceID else { return }   // the utterance was committed meanwhile
        let hyp = Words.split(Self.clean(r.map(\.text).joined(separator: " ")))
        Trace.log("whisperkit", "pass lang=\(language ?? fixedLanguage ?? "auto") detected=\(r.first?.language ?? "-") words=\(hyp.count) committed=\(committedWords)")
        // With a fixed language WhisperKit reports "en" as the result language — never trust it then.
        if language == nil, !hyp.isEmpty { language = fixedLanguage ?? r.first?.language }

        // Words both passes agree on (beyond what is already committed) become final now.
        let agreed = Words.commonPrefix(previousHypothesis, hyp)
        previousHypothesis = hyp
        if agreed > committedWords {
            let fresh = Array(hyp[committedWords..<agreed])
            committedWords = agreed
            await commit(words: fresh)
        }
        emitter.draftOriginal = hyp.count > committedWords ? (committedWords > 0 ? " " : "") + hyp[committedWords...].joined(separator: " ") : ""
        emitter.draftLanguage = language
        continuation.yield(.tokens(emitter.batch()))
    }

    /// Emits committed words; a finished sentence closes its line and is translated right away (text translator only).
    private func commit(words: [String]) async {
        for w in words {
            let text = (openSentence.isEmpty ? "" : " ") + w
            openSentence.append(w)
            continuation.yield(.tokens(emitter.batch(finalOriginal: text, language: language)))
            if translatesText, Words.endsSentence(w) {
                let sentence = openSentence.joined(separator: " ")
                openSentence = []
                continuation.yield(.tokens(emitter.batch(endOriginal: true)))
                await translateLine(sentence, audio: nil)
            }
        }
    }

    // MARK: Utterance end

    private func commitUtterance() {
        queue.append(Pending(audio: samples, committed: committedWords, openSentence: openSentence, language: language))
        samples = []
        speechSeen = false
        silenceRun = 0
        utteranceID += 1
        previousHypothesis = []
        committedWords = 0
        openSentence = []
        language = nil
        if !processing { Task { await processQueue() } }
    }

    private func drain() async {
        if !processing, !queue.isEmpty { await processQueue() }
        while processing || !queue.isEmpty || passBusy { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func processQueue() async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        while !queue.isEmpty { await finish(queue.removeFirst()) }
    }

    /// Final pass over the whole utterance: emit the words not committed yet, close the line, translate.
    private func finish(_ u: Pending) async {
        guard let pipe else { return }
        do {
            let r = try await WhisperKitPool.shared.transcribe(pipe, audio: u.audio, options: options(.transcribe, language: u.language ?? fixedLanguage))
            let words = Words.split(Self.clean(r.map(\.text).joined(separator: " ")))
            let lang = fixedLanguage ?? u.language ?? r.first?.language
            emitter.draftOriginal = ""
            emitter.draftTranslation = ""

            var line = u.openSentence
            if words.count > u.committed {
                let rest = words[u.committed...]
                let text = (line.isEmpty ? "" : " ") + rest.joined(separator: " ")
                line += rest
                continuation.yield(.tokens(emitter.batch(finalOriginal: text, language: lang)))
            }
            // Everything was already closed sentence by sentence: just clear the draft.
            if line.isEmpty { continuation.yield(.tokens(emitter.batch())); return }
            continuation.yield(.tokens(emitter.batch(endOriginal: true)))
            // Without text translation the whole utterance is one line, translated from its audio.
            await translateLine(line.joined(separator: " "), audio: translatesText ? nil : u.audio, language: lang)
        } catch {
            Trace.log("whisperkit", "final pass failed: \(error.localizedDescription)")
        }
    }

    private func translateLine(_ text: String, audio: [Float]?, language lang: String? = nil) async {
        let source = lang ?? language
        guard let target = config.translationTarget(forSource: source), !sameLanguage(target, source) else { return }
        var translated: String?
        if let translator, translatesText {
            do { translated = try await translator.translate(text, from: source, to: target) } catch {
                await warn(translator.problem(from: source, to: target) ?? error.localizedDescription)
            }
        } else if let audio, let pipe, sameLanguage(target, "en"), whisperTranslates {
            if let t = try? await WhisperKitPool.shared.transcribe(pipe, audio: audio, options: options(.translate, language: source)) {
                let out = Self.clean(t.map(\.text).joined(separator: " "))
                if !out.isEmpty, out != text, !Self.hasNonLatinLetters(out) { translated = out }
            }
        } else {
            await warn("No translator for \(source ?? "?") → \(target): choose Apple Translation or a local translation model in Models & Providers.")
        }
        if let translated, !translated.isEmpty {
            continuation.yield(.tokens(emitter.batch(finalTranslation: translated, endTranslation: true)))
        }
    }

    private func warn(_ message: String) async {
        guard !warned else { return }
        warned = true
        continuation.yield(.error(SonioxError(code: 0, message: message)))
    }

    static func hasNonLatinLetters(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x024F }
    }

    /// Drops Whisper's silence hallucinations and special-token leftovers.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let junk = ["[BLANK_AUDIO]", "[Music]", "(music)", "[MUSIC]", "Thank you.", "Thanks for watching!"]
        if junk.contains(t) { t = "" }
        return t
    }
}

/// Direct single-call access for diagnostics (subveil-bench raw).
public enum WhisperKitDiagnostics {
    public static func run(folder: URL, audio: [Float], translate: Bool, language: String?, prefill: Bool = true) async throws -> String {
        let pipe = try await WhisperKitPool.shared.pipe(modelFolder: folder)
        let o = DecodingOptions(verbose: false, task: translate ? .translate : .transcribe, language: language, temperature: 0,
                                usePrefillPrompt: prefill, detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: true)
        let r = try await WhisperKitPool.shared.transcribe(pipe, audio: audio, options: o)
        return r.map(\.text).joined(separator: " ") + "   (detected \(r.first?.language ?? "-"))"
    }
}
