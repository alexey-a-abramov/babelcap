import Foundation

/// The speech engines Subveil knows about — cloud APIs and models that run on this Mac.
///
/// Source: "Real-Time Transcription + Translation: Model Catalog" research snapshot (Nov 2026). Prices are public
/// pay-as-you-go rates and change; every entry links to the provider's own pricing page.
public enum EngineKind: String, Codable, Sendable, CaseIterable {
    case cloud, local
    public var title: String { self == .cloud ? "Cloud (API key)" : "On this Mac" }
}

/// Which built-in adapter runs an entry.
public enum EngineID: Hashable, Sendable {
    case soniox
    case appleSpeech
    case whisperKit(folder: String, translates: Bool)
}

/// Files to fetch from Hugging Face: every file under `path` (or the whole repo when empty), or only `files`.
/// `localDir` puts several specs into one folder (e.g. a Whisper model and its tokenizer).
public struct DownloadSpec: Hashable, Sendable {
    public let repo: String
    public let path: String
    public let files: [String]?
    public let localDir: String?
    public let approxBytes: Int64
    public let role: String
    public init(repo: String, path: String = "", files: [String]? = nil, localDir: String? = nil, approxBytes: Int64, role: String) {
        self.repo = repo; self.path = path; self.files = files; self.localDir = localDir
        self.approxBytes = approxBytes; self.role = role
    }
    public var pageURL: URL { URL(string: "https://huggingface.co/\(repo)" + (path.isEmpty ? "" : "/tree/main/\(path)"))! }
}

public struct CatalogEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let vendor: String
    public let kind: EngineKind
    public let summary: String
    public let outputs: String
    public let languages: String
    public let translation: String
    public let realtime: String
    public let runtime: String
    /// Approximate USD per hour of audio (cloud), for sorting and the cost counter.
    public let pricePerHour: Double?
    public let priceText: String?
    public let keyURL: URL?
    public let pricingURL: URL?
    public let docsURL: URL?
    public let license: String
    public let licenseWarning: String?
    public let downloads: [DownloadSpec]
    public let minRAMGB: Int?
    public let recommendedRAMGB: Int?
    public let minMacOS: Int?
    /// nil = catalog entry only; the adapter is not built yet.
    public let engine: EngineID?
    public let notes: [String]

    public var isReady: Bool { engine != nil }
    public var needsAPIKey: Bool { kind == .cloud }
    public var downloadBytes: Int64 { downloads.reduce(0) { $0 + $1.approxBytes } }
    public var needsDownload: Bool { !downloads.isEmpty }

    init(id: String, name: String, vendor: String, kind: EngineKind, summary: String, outputs: String, languages: String,
         translation: String, realtime: String, runtime: String, pricePerHour: Double? = nil, priceText: String? = nil,
         keyURL: String? = nil, pricingURL: String? = nil, docsURL: String? = nil, license: String,
         licenseWarning: String? = nil, downloads: [DownloadSpec] = [], minRAMGB: Int? = nil, recommendedRAMGB: Int? = nil,
         minMacOS: Int? = nil, engine: EngineID? = nil, notes: [String] = []) {
        self.id = id; self.name = name; self.vendor = vendor; self.kind = kind; self.summary = summary
        self.outputs = outputs; self.languages = languages; self.translation = translation; self.realtime = realtime
        self.runtime = runtime; self.pricePerHour = pricePerHour; self.priceText = priceText
        self.keyURL = keyURL.flatMap(URL.init(string:)); self.pricingURL = pricingURL.flatMap(URL.init(string:))
        self.docsURL = docsURL.flatMap(URL.init(string:)); self.license = license; self.licenseWarning = licenseWarning
        self.downloads = downloads; self.minRAMGB = minRAMGB; self.recommendedRAMGB = recommendedRAMGB
        self.minMacOS = minMacOS; self.engine = engine; self.notes = notes
    }
}

public enum ModelCatalog {
    public static func entry(_ id: String) -> CatalogEntry? { all.first { $0.id == id } }
    public static let defaultProviderID = "soniox"

    private static let mb: Int64 = 1_000_000

    private static func whisperKit(_ id: String, _ name: String, folder: String, mb size: Int64, ram: Int, rec: Int,
                                   tokenizer: String = "openai/whisper-large-v3", translates: Bool = true,
                                   summary: String, english: Bool = false, notes: [String] = []) -> CatalogEntry {
        CatalogEntry(
            id: id, name: name, vendor: "OpenAI Whisper · Argmax WhisperKit", kind: .local, summary: summary,
            outputs: "Transcript" + (english ? "" : translates ? " + built-in translation into English" : " (translation via Apple Translation)"),
            languages: english ? "English only" : "99 languages, auto-detected",
            translation: english ? "Via Apple Translation (macOS 26)"
                : translates ? "Into English built in; other targets via Apple Translation (macOS 26)"
                : "Via Apple Translation (macOS 26) — this variant was not trained to translate",
            realtime: "Near real time: utterances are finalised after a short pause",
            runtime: "Core ML · Neural Engine + GPU", priceText: "Free · runs offline",
            docsURL: "https://github.com/argmaxinc/WhisperKit", license: "MIT",
            downloads: [
                DownloadSpec(repo: "argmaxinc/whisperkit-coreml", path: folder, localDir: "model", approxBytes: size * mb, role: "Speech recognition (Core ML)"),
                // The tokenizer sits next to the model so WhisperKit never reaches out to its own cache.
                DownloadSpec(repo: tokenizer, files: ["tokenizer.json", "tokenizer_config.json"], localDir: "model",
                             approxBytes: 3 * mb, role: "Tokenizer"),
            ],
            minRAMGB: ram, recommendedRAMGB: rec, engine: .whisperKit(folder: folder, translates: translates && !english), notes: notes)
    }

    public static let all: [CatalogEntry] = [
        // MARK: Cloud — ready
        CatalogEntry(
            id: "soniox", name: "Soniox stt-rt-v6", vendor: "Soniox", kind: .cloud,
            summary: "Real-time transcription and translation in one stream. The most accurate option here, and the cheapest cloud one.",
            outputs: "Transcript + translation in one stream, speaker labels, language per token",
            languages: "60+ with automatic language detection", translation: "One-way or two-way (e.g. RU ⇄ EN), 60+ languages",
            realtime: "Yes — words appear in ~200–500 ms", runtime: "WebSocket",
            pricePerHour: 0.18, priceText: "≈ $0.12/h transcription · ≈ $0.18/h with translation",
            keyURL: "https://console.soniox.com", pricingURL: "https://soniox.com/pricing",
            docsURL: "https://soniox.com/docs/stt/rt/real-time-transcription", license: "Proprietary (pay as you go)",
            engine: .soniox, notes: ["Recommended default.", "Billed by session time: auto-pause on silence keeps costs down."]),

        // MARK: Local — ready
        CatalogEntry(
            id: "apple-ondevice", name: "Apple on-device speech", vendor: "Apple (SpeechAnalyzer + Translation)", kind: .local,
            summary: "Built into macOS 26: no API key, no cost, nothing leaves the Mac. macOS downloads the language assets itself.",
            outputs: "Transcript (streaming) + translation through Apple Translation",
            languages: "German, English, Spanish, French, Italian, Japanese, Korean, Portuguese, Chinese — not Russian or Hebrew. One language per session (the first in your profile)",
            translation: "Apple Translation, offline, ~20 languages incl. Russian ⇄ English (not Hebrew); install packs in System Settings → General → Language & Region → Translation Languages",
            realtime: "Yes — streaming partial results", runtime: "System framework · Neural Engine",
            priceText: "Free · runs offline", docsURL: "https://developer.apple.com/documentation/speech/speechanalyzer",
            license: "Part of macOS", minRAMGB: 8, recommendedRAMGB: 8, minMacOS: 26, engine: .appleSpeech,
            notes: ["No automatic language detection: pick the spoken language as the first language hint.",
                    "Hebrew and some other languages may not be supported by Apple's transcriber — the test button tells you."]),
        whisperKit("whisperkit-large-v3-turbo", "Whisper large-v3 turbo", folder: "openai_whisper-large-v3-v20240930_turbo", mb: 1638,
                   ram: 8, rec: 16, translates: false, summary: "Best balance of accuracy and speed for local captions on Apple Silicon.",
                   notes: ["Recommended local model."]),
        whisperKit("whisperkit-large-v3-turbo-q", "Whisper large-v3 turbo (compressed, 632 MB)", folder: "openai_whisper-large-v3-v20240930_turbo_632MB",
                   mb: 646, ram: 8, rec: 8, translates: false, summary: "Same model, quantised: a third of the size, slightly less accurate. Good for 8 GB Macs."),
        whisperKit("whisperkit-large-v3", "Whisper large-v3", folder: "openai_whisper-large-v3", mb: 3090, ram: 16, rec: 32,
                   summary: "The full large model: most accurate Whisper, but heavier and slower than turbo."),
        whisperKit("whisperkit-small", "Whisper small", folder: "openai_whisper-small", mb: 486, ram: 8, rec: 8,
                   tokenizer: "openai/whisper-small",
                   summary: "Fast and light; noticeably less accurate on accents and noise."),
        whisperKit("whisperkit-base", "Whisper base", folder: "openai_whisper-base", mb: 147, ram: 4, rec: 8,
                   tokenizer: "openai/whisper-base",
                   summary: "Very small and fast. For testing or weak machines."),
        whisperKit("whisperkit-tiny", "Whisper tiny", folder: "openai_whisper-tiny", mb: 77, ram: 4, rec: 4,
                   tokenizer: "openai/whisper-tiny",
                   summary: "Smallest model. Only for quick experiments."),
        whisperKit("whisperkit-distil-large-v3-turbo", "Distil-Whisper large-v3 turbo (English)", folder: "distil-whisper_distil-large-v3_turbo",
                   mb: 1527, ram: 8, rec: 16, summary: "Distilled large model: very fast, English speech only.", english: true),

        // MARK: Cloud — catalog (adapters planned)
        CatalogEntry(
            id: "gladia", name: "Gladia Solaria (Live v2)", vendor: "Gladia", kind: .cloud,
            summary: "Real-time transcript + per-utterance translation with speakers and timestamps.",
            outputs: "Transcript + translation per utterance", languages: "100+", translation: "Yes, add-on",
            realtime: "Yes", runtime: "REST to open a session, then WebSocket",
            pricePerHour: 0.23, priceText: "from €0.16/h + €0.05/h translation (real-time may cost more)",
            keyURL: "https://app.gladia.io", pricingURL: "https://www.gladia.io/pricing",
            docsURL: "https://docs.gladia.io/chapters/live-stt/getting-started", license: "Proprietary"),
        CatalogEntry(
            id: "speechmatics", name: "Speechmatics Real-time + Translation", vendor: "Speechmatics", kind: .cloud,
            summary: "Enterprise real-time ASR with up to five simultaneous translation targets.",
            outputs: "Transcript + up to 5 translations", languages: "55+", translation: "Yes, add-on ($0.65/h)",
            realtime: "Yes", runtime: "WebSocket", pricePerHour: 1.2, priceText: "$0.30–0.80/h + $0.65/h translation",
            keyURL: "https://portal.speechmatics.com", pricingURL: "https://www.speechmatics.com/pricing",
            docsURL: "https://docs.speechmatics.com/rt-api-ref", license: "Proprietary"),
        CatalogEntry(
            id: "openai-translate", name: "OpenAI gpt-realtime-translate", vendor: "OpenAI", kind: .cloud,
            summary: "Speech-to-speech translation with transcript deltas.",
            outputs: "Translated speech + transcript", languages: "70+ in, 13 out", translation: "Yes (the point of the model)",
            realtime: "Yes", runtime: "WebSocket / WebRTC", pricePerHour: 2.04, priceText: "≈ $2.04/h ($0.034/min)",
            keyURL: "https://platform.openai.com/api-keys", pricingURL: "https://platform.openai.com/settings/organization/billing",
            docsURL: "https://platform.openai.com/docs/guides/realtime", license: "Proprietary"),
        CatalogEntry(
            id: "gemini-live", name: "Google Gemini Live Translate", vendor: "Google", kind: .cloud,
            summary: "Live speech translation through the Gemini Live API (preview).",
            outputs: "Translated speech / text", languages: "Many", translation: "Yes", realtime: "Yes (preview)",
            runtime: "WebSocket (Live API)", pricePerHour: 2.21, priceText: "≈ $2.21/h (third-party estimate)",
            keyURL: "https://aistudio.google.com/apikey", pricingURL: "https://ai.google.dev/gemini-api/docs/pricing",
            docsURL: "https://ai.google.dev/gemini-api/docs/live", license: "Proprietary"),
        CatalogEntry(
            id: "azure-translate", name: "Azure Speech Translation", vendor: "Microsoft", kind: .cloud,
            summary: "Transcript + translated text (optionally speech) through the Azure Speech SDK.",
            outputs: "Transcript + translation (+ speech)", languages: "100+", translation: "Yes", realtime: "Yes",
            runtime: "Speech SDK", pricePerHour: 2.5, priceText: "$2.50/h",
            keyURL: "https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices",
            pricingURL: "https://azure.microsoft.com/pricing/details/cognitive-services/speech-services/",
            docsURL: "https://learn.microsoft.com/azure/ai-services/speech-service/speech-translation", license: "Proprietary"),
        CatalogEntry(
            id: "azure-interpreter", name: "Azure Live Interpreter", vendor: "Microsoft", kind: .cloud,
            summary: "Speech-to-speech interpretation with text.", outputs: "Translated speech + text", languages: "Many",
            translation: "Yes", realtime: "Yes", runtime: "Speech SDK", pricePerHour: 2.5,
            priceText: "$1/h in + $1.50/h voice out + $10 per 1M characters",
            keyURL: "https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices",
            pricingURL: "https://azure.microsoft.com/pricing/details/cognitive-services/speech-services/",
            docsURL: "https://learn.microsoft.com/azure/ai-services/speech-service/speech-translation", license: "Proprietary"),
        CatalogEntry(
            id: "elevenlabs-scribe", name: "ElevenLabs Scribe v3 Live", vendor: "ElevenLabs", kind: .cloud,
            summary: "Low-latency live transcription (no translation — would need a separate translation step).",
            outputs: "Transcript", languages: "90+", translation: "No", realtime: "Yes", runtime: "WebSocket",
            pricePerHour: 0.22, priceText: "$0.22/h", keyURL: "https://elevenlabs.io/app/settings/api-keys",
            pricingURL: "https://elevenlabs.io/pricing/api", docsURL: "https://elevenlabs.io/docs", license: "Proprietary"),
        CatalogEntry(
            id: "assemblyai", name: "AssemblyAI Streaming", vendor: "AssemblyAI", kind: .cloud,
            summary: "Streaming transcription (no translation).", outputs: "Transcript", languages: "English + others",
            translation: "No", realtime: "Yes", runtime: "WebSocket", pricePerHour: 0.38, priceText: "$0.30–0.45/h",
            keyURL: "https://www.assemblyai.com/dashboard", pricingURL: "https://www.assemblyai.com/pricing",
            docsURL: "https://www.assemblyai.com/docs", license: "Proprietary"),
        CatalogEntry(
            id: "deepgram", name: "Deepgram Nova-3", vendor: "Deepgram", kind: .cloud,
            summary: "Fast streaming transcription (no translation).", outputs: "Transcript", languages: "30+",
            translation: "No", realtime: "Yes", runtime: "WebSocket", priceText: "See Deepgram pricing",
            keyURL: "https://console.deepgram.com", pricingURL: "https://deepgram.com/pricing",
            docsURL: "https://developers.deepgram.com", license: "Proprietary"),

        // MARK: Local — catalog (adapters planned; weights can already be downloaded)
        CatalogEntry(
            id: "local-simulstreaming", name: "SimulStreaming: Whisper large-v3 + EuroLLM-9B", vendor: "Open source cascade", kind: .local,
            summary: "Streaming Whisper transcript, then streaming translation by a local LLM (EuroLLM-9B, 4-bit MLX).",
            outputs: "Streaming transcript + streaming translation", languages: "ASR 99 languages; translation into 35",
            translation: "Yes, any of 35 targets", realtime: "Yes on M-series Pro/Max", runtime: "MLX (Python sidecar planned)",
            priceText: "Free · runs offline", docsURL: "https://github.com/ufal/SimulStreaming", license: "MIT / Apache-2.0",
            downloads: [DownloadSpec(repo: "mlx-community/whisper-large-v3-mlx", approxBytes: 3_100 * mb, role: "Speech recognition (MLX)"),
                        DownloadSpec(repo: "stelterlab/EuroLLM-9B-Instruct-MLX-4bit", approxBytes: 5_200 * mb, role: "Translation LLM (MLX 4-bit)")],
            minRAMGB: 16, recommendedRAMGB: 32),
        CatalogEntry(
            id: "local-voxtral-rt", name: "Mistral Voxtral Mini 4B Realtime", vendor: "Mistral AI", kind: .local,
            summary: "Streaming speech model; translation needs an LLM on top.", outputs: "Streaming transcript", languages: "13",
            translation: "Via an LLM", realtime: "Yes", runtime: "Transformers (MPS) / GGUF (planned)",
            priceText: "Free · runs offline", docsURL: "https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602",
            license: "Apache-2.0", downloads: [DownloadSpec(repo: "mistralai/Voxtral-Mini-4B-Realtime-2602", approxBytes: 8_900 * mb, role: "Speech model (bf16)")],
            minRAMGB: 16, recommendedRAMGB: 32),
        CatalogEntry(
            id: "local-hibiki-zero", name: "Kyutai Hibiki-Zero 3B", vendor: "Kyutai", kind: .local,
            summary: "End-to-end simultaneous translation: speaks and writes the translation as you listen.",
            outputs: "Translated speech + text", languages: "FR / ES / PT / DE → EN", translation: "Into English only",
            realtime: "Yes", runtime: "MLX 4-bit (Python sidecar planned)", priceText: "Free · runs offline",
            docsURL: "https://huggingface.co/kyutai/hibiki-zero-3b-pytorch-bf16", license: "See model card",
            downloads: [DownloadSpec(repo: "aufklarer/Hibiki-Zero-3B-MLX-4bit", approxBytes: 2_200 * mb, role: "Speech-to-speech translation (MLX 4-bit)")],
            minRAMGB: 8, recommendedRAMGB: 16),
        CatalogEntry(
            id: "local-hibiki", name: "Kyutai Hibiki 1B", vendor: "Kyutai", kind: .local,
            summary: "Simultaneous French → English speech translation.", outputs: "Translated speech + timestamped text",
            languages: "FR → EN", translation: "French into English", realtime: "Yes", runtime: "MLX (Python sidecar planned)",
            priceText: "Free · runs offline", docsURL: "https://huggingface.co/kyutai/hibiki-1b-mlx-bf16", license: "CC-BY-4.0",
            downloads: [DownloadSpec(repo: "kyutai/hibiki-1b-mlx-bf16", approxBytes: 2_700 * mb, role: "Speech-to-speech translation (MLX)")],
            minRAMGB: 8, recommendedRAMGB: 16),
        CatalogEntry(
            id: "local-seamless", name: "Meta SeamlessStreaming", vendor: "Meta", kind: .local,
            summary: "Streaming ASR + simultaneous translation for ~100 languages. Heavy; not Metal-native.",
            outputs: "Streaming transcript + translation", languages: "101 in · text out 96 · speech out 36",
            translation: "Yes", realtime: "Slow on Mac (PyTorch on MPS)", runtime: "PyTorch MPS (Python sidecar planned)",
            priceText: "Free · runs offline", docsURL: "https://huggingface.co/facebook/seamless-streaming",
            license: "CC-BY-NC-4.0", licenseWarning: "Non-commercial use only.",
            downloads: [DownloadSpec(repo: "facebook/seamless-streaming", approxBytes: 10_000 * mb, role: "Streaming translation model")],
            minRAMGB: 16, recommendedRAMGB: 32),
    ]
}
