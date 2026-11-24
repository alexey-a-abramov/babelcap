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
/// Whisper is not natively streaming, so audio is cut into utterances at pauses: while someone speaks the current
/// utterance is re-transcribed about once a second (draft), and after a 0.6 s pause it is transcribed once more and
/// committed (final), then translated — into English by Whisper itself, into other languages by Apple Translation.
public actor WhisperKitStream: SpeechStream {
    public nonisolated let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation
    private let config: SonioxConfig
    private let modelFolder: URL
    /// turbo / distil models were not trained for Whisper's translate task — use Apple Translation instead.
    private let whisperTranslates: Bool
    private var lastDraftAt = Date.distantPast

    static let rate = 16_000
    private let silenceThreshold: Float = 0.012
    private let endOfUtteranceSilence = Int(0.6 * Double(rate))
    private let maxUtterance = 20 * rate
    private let draftEvery = rate

    private var pipe: WhisperKit?
    private var samples: [Float] = []
    private var speechSeen = false
    private var silenceRun = 0
    private var sinceDraft = 0
    private var draftBusy = false
    private var queue: [[Float]] = []
    private var processing = false
    private var emitter = TokenEmitter()
    private var started = false
    private var translationWarned = false

    public init(modelFolder: URL, config: SonioxConfig, whisperTranslates: Bool = true) {
        self.modelFolder = modelFolder
        self.config = config
        self.whisperTranslates = whisperTranslates
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
            // Keep only a little leading silence.
            if samples.count > Self.rate / 2 { samples.removeFirst(samples.count - Self.rate / 4) }
            return
        }
        if (silenceRun >= endOfUtteranceSilence && samples.count >= Self.rate * 3 / 4) || samples.count >= maxUtterance {
            commitUtterance()
            return
        }
        // Drafts at most once per second of *wall* time: they are a preview; committed text must keep up first.
        sinceDraft += floats.count
        if sinceDraft >= draftEvery, !draftBusy, !processing, Date().timeIntervalSince(lastDraftAt) >= 1 {
            sinceDraft = 0
            lastDraftAt = Date()
            await draft()
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

    // MARK: Work

    private func commitUtterance() {
        queue.append(samples)
        samples = []
        speechSeen = false
        silenceRun = 0
        sinceDraft = 0
        if !processing { Task { await processQueue() } }
    }

    private func drain() async {
        if !processing, !queue.isEmpty { await processQueue() }
        while processing || !queue.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private var fixedLanguage: String? {
        guard let hints = config.languageHints, hints.count == 1 else { return nil }
        return hints[0]
    }

    private func options(_ task: DecodingTask, language: String?) -> DecodingOptions {
        DecodingOptions(verbose: false, task: task, language: language, temperature: 0, usePrefillPrompt: true,
                        detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: true)
    }

    private func draft() async {
        guard let pipe else { return }
        draftBusy = true
        defer { draftBusy = false }
        let audio = samples
        guard let r = try? await WhisperKitPool.shared.transcribe(pipe, audio: audio, options: options(.transcribe, language: fixedLanguage)) else { return }
        let text = r.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, speechSeen else { return }  // the utterance may have been committed meanwhile
        emitter.draftOriginal = text
        emitter.draftLanguage = r.first?.language
        continuation.yield(.tokens(emitter.batch()))
    }

    private func processQueue() async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        while !queue.isEmpty {
            let audio = queue.removeFirst()
            await transcribeFinal(audio)
        }
    }

    private func transcribeFinal(_ audio: [Float]) async {
        guard let pipe else { return }
        do {
            let r = try await WhisperKitPool.shared.transcribe(pipe, audio: audio, options: options(.transcribe, language: fixedLanguage))
            let text = Self.clean(r.map(\.text).joined(separator: " "))
            let lang = r.first?.language ?? fixedLanguage
            emitter.draftOriginal = ""
            emitter.draftTranslation = ""
            guard !text.isEmpty else { continuation.yield(.tokens(emitter.batch())); return }
            continuation.yield(.tokens(emitter.batch(finalOriginal: text, language: lang, endOriginal: true)))

            guard let target = config.translationTarget(forSource: lang), !sameLanguage(target, lang) else { return }
            var translated: String?
            if sameLanguage(target, "en"), whisperTranslates {
                // Whisper translates into English natively (not the turbo / distil variants).
                let t = try await WhisperKitPool.shared.transcribe(pipe, audio: audio, options: options(.translate, language: lang))
                let out = Self.clean(t.map(\.text).joined(separator: " "))
                if !out.isEmpty, out != text, !Self.hasNonLatinLetters(out) { translated = out }
            }
            if translated == nil, #available(macOS 26.0, *), let src = lang {
                do { translated = try await AppleTranslator.shared.translate(text, from: src, to: target) } catch {
                    if !translationWarned {
                        translationWarned = true
                        continuation.yield(.error(SonioxError(code: 0, message: LocalTranslationHelp.message(source: src, target: target))))
                    }
                }
            }
            if let translated, !translated.isEmpty {
                continuation.yield(.tokens(emitter.batch(finalTranslation: translated, endTranslation: true)))
            }
        } catch {
            Trace.log("whisperkit", "transcribe failed: \(error.localizedDescription)")
        }
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
