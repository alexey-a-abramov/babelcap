import Foundation

/// Which audio stream a piece of text came from.
public enum SourceKind: String, Codable, Sendable, CaseIterable, Hashable {
    case system, mic, mixed
    public var label: String {
        switch self {
        case .system: "Them"
        case .mic: "Me"
        case .mixed: "Mixed"
        }
    }
}

public struct SonioxConfig: Codable, Sendable, Equatable {
    public struct ContextEntry: Codable, Sendable, Equatable {
        public var key: String
        public var value: String
        public init(key: String, value: String) { self.key = key; self.value = value }
    }

    public struct TranslationTerm: Codable, Sendable, Equatable {
        public var source: String
        public var target: String
        public init(source: String, target: String) { self.source = source; self.target = target }
    }

    public struct Context: Codable, Sendable, Equatable {
        public var general: [ContextEntry]?
        public var text: String?
        public var terms: [String]?
        public var translationTerms: [TranslationTerm]?
        public init(general: [ContextEntry]? = nil, text: String? = nil, terms: [String]? = nil,
                    translationTerms: [TranslationTerm]? = nil) {
            self.general = general; self.text = text; self.terms = terms; self.translationTerms = translationTerms
        }
        public var isEmpty: Bool {
            (general ?? []).isEmpty && (text ?? "").isEmpty && (terms ?? []).isEmpty && (translationTerms ?? []).isEmpty
        }
    }

    public enum Translation: Codable, Sendable, Equatable {
        case oneWay(target: String)
        case twoWay(a: String, b: String)

        enum CodingKeys: String, CodingKey { case type, targetLanguage, languageA, languageB }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .oneWay(t):
                try c.encode("one_way", forKey: .type)
                try c.encode(t, forKey: .targetLanguage)
            case let .twoWay(a, b):
                try c.encode("two_way", forKey: .type)
                try c.encode(a, forKey: .languageA)
                try c.encode(b, forKey: .languageB)
            }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if try c.decode(String.self, forKey: .type) == "two_way" {
                self = .twoWay(a: try c.decode(String.self, forKey: .languageA), b: try c.decode(String.self, forKey: .languageB))
            } else {
                self = .oneWay(target: try c.decode(String.self, forKey: .targetLanguage))
            }
        }
    }

    public var model: String
    public var audioFormat: String = "pcm_s16le"
    public var sampleRate: Int = 16_000
    public var numChannels: Int = 1
    public var languageHints: [String]?
    public var languageHintsStrict: Bool?
    public var enableLanguageIdentification: Bool = true
    public var enableSpeakerDiarization: Bool = false
    public var enableEndpointDetection: Bool = true
    public var maxEndpointDelayMs: Int?
    public var context: Context?
    public var translation: Translation?

    public init(model: String = "stt-rt-v6") { self.model = model }

    /// The wire form: snake_case JSON. `api_key` is intentionally absent — auth goes in the header.
    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        return try enc.encode(self)
    }
}

public struct SonioxToken: Codable, Sendable, Equatable {
    public var text: String
    public var startMs: Int?
    public var endMs: Int?
    public var confidence: Double?
    public var isFinal: Bool
    public var speaker: String?
    public var language: String?
    public var translationStatus: String?
    public var sourceLanguage: String?

    public init(text: String, startMs: Int? = nil, endMs: Int? = nil, confidence: Double? = nil, isFinal: Bool,
                speaker: String? = nil, language: String? = nil, translationStatus: String? = nil,
                sourceLanguage: String? = nil) {
        self.text = text; self.startMs = startMs; self.endMs = endMs; self.confidence = confidence
        self.isFinal = isFinal; self.speaker = speaker; self.language = language
        self.translationStatus = translationStatus; self.sourceLanguage = sourceLanguage
    }

    public var isTranslation: Bool { translationStatus == "translation" }
    /// Endpoint / finalize markers emitted inline by the server.
    public var isMarker: Bool { text == "<end>" || text == "<fin>" }

    enum CodingKeys: String, CodingKey {
        case text, startMs, endMs, confidence, isFinal, speaker, language, translationStatus, sourceLanguage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        startMs = try? c.decodeIfPresent(Int.self, forKey: .startMs)
        endMs = try? c.decodeIfPresent(Int.self, forKey: .endMs)
        confidence = try? c.decodeIfPresent(Double.self, forKey: .confidence)
        isFinal = (try? c.decodeIfPresent(Bool.self, forKey: .isFinal)) ?? false
        // `speaker` may be a string or a number depending on server version.
        if let s = try? c.decodeIfPresent(String.self, forKey: .speaker) { speaker = s }
        else if let n = try? c.decodeIfPresent(Int.self, forKey: .speaker) { speaker = String(n) }
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        translationStatus = try? c.decodeIfPresent(String.self, forKey: .translationStatus)
        sourceLanguage = try? c.decodeIfPresent(String.self, forKey: .sourceLanguage)
    }
}

/// One server message. Unknown fields are ignored (tolerant parsing).
public struct SonioxResponse: Decodable, Sendable {
    public var tokens: [SonioxToken]?
    public var finalAudioProcMs: Int?
    public var totalAudioProcMs: Int?
    public var finished: Bool?
    public var errorCode: Int?
    public var errorMessage: String?

    public static func decode(_ data: Data) throws -> SonioxResponse {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(SonioxResponse.self, from: data)
    }
}
