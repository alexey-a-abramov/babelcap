import Foundation
import LocalEngines
import SonioxClient

// MARK: Engine factory

public enum EngineFactory {
    /// Why an entry cannot run right now, or nil when it can.
    @MainActor
    public static func problem(for entry: CatalogEntry, apiKey: String?) -> String? {
        guard let engine = entry.engine else { return "This engine is in the catalog, but its adapter is not built yet." }
        if let v = entry.minMacOS, MachineInfo.macOSMajor < v { return "Needs macOS \(v) or newer." }
        if let r = entry.minRAMGB, MachineInfo.ramGB < r { return "Needs at least \(r) GB of memory (this Mac has \(MachineInfo.ramGB) GB)." }
        switch engine {
        case .soniox: if (apiKey ?? "").isEmpty { return "Add your API key first." }
        case .appleSpeech: break
        case .whisperKit: if !ModelDownloads.shared.isInstalled(entry.id) { return "Download the model first." }
        }
        return nil
    }

    public static func modelFolder(for entry: CatalogEntry) -> URL {
        ModelStorage.folder(for: entry.id).appendingPathComponent("model", isDirectory: true)
    }

    public static func makeStream(for entry: CatalogEntry, config: SonioxConfig, apiKey: String?,
                                  endpoint: URL = SonioxSession.endpoint) throws -> any SpeechStream {
        switch entry.engine {
        case .soniox?:
            return SonioxSession(apiKey: apiKey ?? "", config: config, endpoint: endpoint)
        case .appleSpeech?:
            guard #available(macOS 26.0, *) else { throw LocalEngineError.needsNewerMacOS(26) }
            return AppleSpeechStream(config: config)
        case let .whisperKit(_, translates)?:
            return WhisperKitStream(modelFolder: modelFolder(for: entry), config: config, whisperTranslates: translates)
        case nil:
            throw LocalEngineError.modelMissing("\(entry.name) has no adapter yet.")
        }
    }
}

// MARK: Clips

public struct BenchmarkClip: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let language: String
    public let title: String
    public let file: String
    public let text: String
    public let english: String
    public let seconds: Double
}

public enum BenchmarkClips {
    nonisolated(unsafe) public static var directoryOverride: URL?

    /// App bundle (Contents/Resources/Benchmark) or the repo's Resources/Benchmark when run from source.
    public static var directory: URL? {
        if let d = directoryOverride { return d }
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("Benchmark")) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/Benchmark"))
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Benchmark").standardized)
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("clips.json").path) }
    }

    public static func all() -> [BenchmarkClip] {
        guard let dir = directory, let d = try? Data(contentsOf: dir.appendingPathComponent("clips.json")) else { return [] }
        return (try? JSONDecoder().decode([BenchmarkClip].self, from: d)) ?? []
    }

    /// 16 kHz mono pcm_s16le samples of the clip (WAV "data" chunk).
    public static func pcm(_ clip: BenchmarkClip) throws -> Data {
        guard let dir = directory else { throw CocoaError(.fileNoSuchFile) }
        let wav = try Data(contentsOf: dir.appendingPathComponent(clip.file))
        var i = 12
        while i + 8 <= wav.count {
            let id = String(decoding: wav[i..<i + 4], as: UTF8.self)
            let size = Int(wav[i + 4]) | Int(wav[i + 5]) << 8 | Int(wav[i + 6]) << 16 | Int(wav[i + 7]) << 24
            if id == "data" { return wav.subdata(in: (i + 8)..<min(wav.count, i + 8 + size)) }
            i += 8 + size + (size & 1)
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}

// MARK: Scoring

public enum WER {
    public static func words(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Word error rate: (substitutions + deletions + insertions) / reference words.
    public static func rate(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        if r.isEmpty { return h.isEmpty ? 0 : 1 }
        if h.isEmpty { return 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + [Int](repeating: 0, count: h.count)
            for j in 1...h.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}

// MARK: Runner

public struct BenchmarkResult: Identifiable, Sendable {
    public enum Verdict: Sendable {
        case excellent, good, borderline, tooSlow, inaccurate, failed
        public var title: String {
            switch self {
            case .excellent: "Excellent for live captions"
            case .good: "Good for live captions"
            case .borderline: "Borderline — may lag behind"
            case .tooSlow: "Too slow for live captions"
            case .inaccurate: "Not usable — too many recognition errors"
            case .failed: "Did not work"
            }
        }
        public var symbol: String {
            switch self {
            case .excellent: "checkmark.seal.fill"
            case .good: "checkmark.circle.fill"
            case .borderline: "exclamationmark.triangle.fill"
            case .tooSlow, .inaccurate, .failed: "xmark.octagon.fill"
            }
        }
    }

    public let id = UUID()
    public let entryID: String
    public let clipID: String
    public var transcript = ""
    public var translation = ""
    public var targetLanguage: String?
    public var wer: Double?
    public var audioSeconds: Double = 0
    public var setupSeconds: Double = 0
    public var processingSeconds: Double = 0
    public var firstTextAfter: Double?
    public var finalLatency: Double?
    public var error: String?
    /// Non-fatal problem worth showing (e.g. a translation language pack is missing).
    public var warning: String?
    public var isCloud = false

    /// Processing time ÷ audio duration (local engines). < 1 means faster than real time.
    public var rtf: Double? { isCloud || audioSeconds == 0 ? nil : processingSeconds / audioSeconds }
    public var speedText: String {
        if let rtf { return rtf > 0 ? String(format: "%.1f× faster than real time", 1 / rtf) : "—" }
        if let l = finalLatency { return String(format: "final text %.1f s after the speaker stops", l) }
        return "—"
    }

    public var verdict: Verdict {
        if error != nil || transcript.isEmpty { return .failed }
        if let wer, wer > 0.5 { return .inaccurate }
        let speed = speedVerdict
        // Noticeable errors cap the verdict even when the engine is fast.
        if let wer, wer > 0.2, speed == .excellent || speed == .good { return .borderline }
        return speed
    }

    private var speedVerdict: Verdict {
        if let rtf {
            switch rtf { case ..<0.25: return .excellent; case ..<0.6: return .good; case ..<1.0: return .borderline; default: return .tooSlow }
        }
        switch finalLatency ?? 99 { case ..<1.5: return .excellent; case ..<3: return .good; case ..<6: return .borderline; default: return .tooSlow }
    }
}

public enum BenchmarkRunner {
    /// Runs one clip through one engine. Local engines get the audio as fast as they accept it (measures speed);
    /// cloud engines get it in real time (measures latency).
    public static func run(entry: CatalogEntry, clip: BenchmarkClip, target: String?, apiKey: String?,
                           progress: (@Sendable (String) -> Void)? = nil) async -> BenchmarkResult {
        var result = BenchmarkResult(entryID: entry.id, clipID: clip.id)
        result.isCloud = entry.kind == .cloud
        result.audioSeconds = clip.seconds
        let tgt = (target.map { $0.prefix(2) == clip.language.prefix(2) } ?? true) ? nil : target
        result.targetLanguage = tgt

        var config = SonioxConfig()
        config.languageHints = [clip.language]
        config.translation = tgt.map { .oneWay(target: $0) }
        config.maxEndpointDelayMs = 1000

        let pcm: Data
        let stream: any SpeechStream
        do {
            pcm = try BenchmarkClips.pcm(clip)
            stream = try EngineFactory.makeStream(for: entry, config: config, apiKey: apiKey)
        } catch {
            result.error = error.localizedDescription
            return result
        }

        // Local engines: one untimed warm-up pass, so the model is loaded and GPU kernels are compiled before timing
        // (otherwise the first inference after a load dominates a short clip).
        if entry.kind == .local {
            progress?("Warming up \(entry.name)…")
            let warmStart = Date()
            if let warm = try? EngineFactory.makeStream(for: entry, config: config, apiKey: apiKey) {
                let drain = Task { for await _ in warm.events {} }
                await warm.start()
                await warm.send(pcm.prefix(min(pcm.count, 32_000 * 3)))
                await warm.send(Data(count: 32_000))
                await warm.stop()
                _ = await drain.value
            }
            result.setupSeconds = Date().timeIntervalSince(warmStart)
        }

        let collector = Collector(joinWithSpaces: entry.kind == .local)
        let eventsTask = Task { for await e in stream.events { collector.add(e) } }

        progress?("Starting \(entry.name)…")
        let setupStart = Date()
        await stream.start()
        // Wait until live (model load / connection) or failed.
        var lastNote = Date.distantPast
        while !collector.isLive && !collector.failed && Date().timeIntervalSince(setupStart) < 600 {
            try? await Task.sleep(for: .milliseconds(20))
            if Date().timeIntervalSince(lastNote) >= 1 {
                lastNote = Date()
                let s = Int(Date().timeIntervalSince(setupStart))
                progress?(entry.kind == .cloud ? "Connecting to \(entry.vendor)… \(s) s"
                          : "Loading the model… \(s) s" + (s > 20 ? " (the first load prepares the model for this Mac and can take a while)" : ""))
            }
        }
        result.setupSeconds += Date().timeIntervalSince(setupStart)
        guard collector.isLive else {
            result.error = collector.errorText ?? "The engine did not start."
            eventsTask.cancel()
            return result
        }

        progress?("Transcribing \(clip.title)…")
        let start = Date()
        collector.start = start
        var offset = 0
        while offset < pcm.count {
            let end = min(pcm.count, offset + 3200)
            await stream.send(pcm.subdata(in: offset..<end))
            offset = end
            if result.isCloud { try? await Task.sleep(for: .milliseconds(100)) }
        }
        // Trailing silence lets endpointing / pause detection close the last sentence naturally.
        for _ in 0..<10 {
            await stream.send(Data(count: 3200))
            if result.isCloud { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let audioEnd = Date()
        await stream.stop()
        _ = await eventsTask.value
        let done = Date()

        result.processingSeconds = done.timeIntervalSince(start)
        result.finalLatency = done.timeIntervalSince(audioEnd)
        result.firstTextAfter = collector.firstText.map { $0.timeIntervalSince(start) }
        result.transcript = collector.original.trimmingCharacters(in: .whitespacesAndNewlines)
        result.translation = collector.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        result.error = collector.fatal ? collector.errorText : nil
        if !collector.fatal { result.warning = collector.errorText }
        if !result.transcript.isEmpty { result.wer = WER.rate(reference: clip.text, hypothesis: result.transcript) }
        if result.transcript.isEmpty, result.error == nil { result.error = collector.errorText ?? "No text was recognised." }
        Trace.log("bench", "\(entry.id) \(clip.id): wer \(result.wer.map { String(format: "%.2f", $0) } ?? "-") \(result.speedText) setup \(String(format: "%.1f", result.setupSeconds)) s")
        return result
    }

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private let spaces: Bool
        private var _original = ""
        private var _translation = ""
        private var _live = false
        private var _failed = false
        private var _fatal = false
        private var _error: String?
        private var _first: Date?
        var start: Date?

        init(joinWithSpaces: Bool) { spaces = joinWithSpaces }

        var original: String { lock.lock(); defer { lock.unlock() }; return _original }
        var translation: String { lock.lock(); defer { lock.unlock() }; return _translation }
        var isLive: Bool { lock.lock(); defer { lock.unlock() }; return _live }
        var failed: Bool { lock.lock(); defer { lock.unlock() }; return _failed }
        var fatal: Bool { lock.lock(); defer { lock.unlock() }; return _fatal }
        var errorText: String? { lock.lock(); defer { lock.unlock() }; return _error }
        var firstText: Date? { lock.lock(); defer { lock.unlock() }; return _first }

        func add(_ e: SonioxEvent) {
            lock.lock(); defer { lock.unlock() }
            switch e {
            case let .state(s):
                if s == .live { _live = true }
                if s == .failed { _failed = true; _fatal = true }
            case let .error(err):
                _error = err.localizedDescription
                if err.isFatal || err.code >= 1000 { _fatal = true }
            case let .tokens(tokens):
                for t in tokens {
                    if _first == nil, start != nil, !t.isMarker, !t.text.trimmingCharacters(in: .whitespaces).isEmpty { _first = Date() }
                    guard t.isFinal, !t.isMarker else { continue }
                    if t.isTranslation { append(&_translation, t.text) } else { append(&_original, t.text) }
                }
            case .finished: break
            }
        }

        private func append(_ s: inout String, _ piece: String) {
            if spaces, !s.isEmpty, !s.hasSuffix(" "), !piece.hasPrefix(" ") { s += " " }
            s += piece
        }
    }
}
