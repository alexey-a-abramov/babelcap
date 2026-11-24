import AppKit
import Foundation
import SonioxClient
import SwiftUI

public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    public init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
    public static let white = RGBA(1, 1, 1)
}

public struct TextStyle: Codable, Hashable, Sendable {
    public var fontName: String = ""          // "" = system font
    public var size: Double = 28
    public var bold: Bool = false
    public var lineSpacing: Double = 4
    public var tracking: Double = 0
    public var uppercase: Bool = false

    public init(size: Double = 28) { self.size = size }

    public var font: Font {
        let f: Font = fontName.isEmpty ? .system(size: size) : .custom(fontName, size: size)
        return bold ? f.weight(.semibold) : f
    }
}

public enum OverlayMode: String, Codable, CaseIterable, Sendable { case captions, feed, dual, split
    public var title: String { rawValue.capitalized }
    /// `.split` is legacy — splitting by source is now `LayoutSettings.separateSources`.
    public static var selectable: [OverlayMode] { [.captions, .feed, .dual] }
}
public enum ContentDisplay: String, Codable, CaseIterable, Sendable { case original, translation, both
    public var title: String {
        switch self { case .original: "Original"; case .translation: "Target language"; case .both: "Original + translation" }
    }
}
public enum SourceMode: String, Codable, CaseIterable, Sendable { case system, mic, both
    public var title: String { self == .both ? "Both" : self == .system ? "System" : "Mic" }
}
public enum WindowLevelOption: String, Codable, CaseIterable, Sendable { case statusBar, popUp, screenSaver
    public var title: String { switch self { case .statusBar: "Status bar"; case .popUp: "Pop-up menu"; case .screenSaver: "Screen saver (highest)" } }
}
public enum CaptionAlignment: String, Codable, CaseIterable, Sendable { case leading, center, trailing }

public enum ColorMode: String, Codable, CaseIterable, Sendable {
    case speaker, source, single
    public var title: String {
        switch self { case .speaker: "By speaker"; case .source: "By source (System / Mic)"; case .single: "One colour" }
    }
}

public struct AppearanceSettings: Codable, Hashable, Sendable {
    public var original = TextStyle(size: 28)
    public var translation = TextStyle(size: 24)
    public var textColor = RGBA.white
    public var translationColor = RGBA(0.75, 0.9, 1)
    public var draftColor = RGBA(1, 1, 1, 0.55)
    public var themColor = RGBA(1, 1, 1)
    public var meColor = RGBA(0.6, 1, 0.7)
    public var backgroundColor = RGBA(0, 0, 0, 0.62)
    public var useBlur = false
    public var cornerRadius: Double = 14
    public var padding: Double = 14
    public var shadow = true
    public var outline = false
    /// Legacy flag (pre-colour-modes); kept so old settings decode. Use `colorMode`.
    public var speakerColors = true
    public var colorMode: ColorMode = .speaker
    /// One colour per diarised speaker (cycled).
    public var speakerPalette: [RGBA] = [
        RGBA(1, 1, 1), RGBA(1.0, 0.82, 0.4), RGBA(0.55, 0.85, 1.0), RGBA(1.0, 0.6, 0.75), RGBA(0.7, 1.0, 0.6), RGBA(0.8, 0.7, 1.0),
    ]
    public init() {}

    enum CodingKeys: String, CodingKey {
        case original, translation, textColor, translationColor, draftColor, themColor, meColor, backgroundColor, useBlur,
             cornerRadius, padding, shadow, outline, speakerColors, colorMode, speakerPalette
    }

    /// Tolerant: settings saved by older versions lack newer keys.
    public init(from d: Decoder) throws {
        self.init()
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? cur }
        original = try v(.original, original); translation = try v(.translation, translation)
        textColor = try v(.textColor, textColor); translationColor = try v(.translationColor, translationColor)
        draftColor = try v(.draftColor, draftColor); themColor = try v(.themColor, themColor); meColor = try v(.meColor, meColor)
        backgroundColor = try v(.backgroundColor, backgroundColor); useBlur = try v(.useBlur, useBlur)
        cornerRadius = try v(.cornerRadius, cornerRadius); padding = try v(.padding, padding)
        shadow = try v(.shadow, shadow); outline = try v(.outline, outline); speakerColors = try v(.speakerColors, speakerColors)
        speakerPalette = try v(.speakerPalette, speakerPalette)
        if let m = try c.decodeIfPresent(ColorMode.self, forKey: .colorMode) { colorMode = m } else { colorMode = speakerColors ? .speaker : .single }
        if speakerPalette.isEmpty { speakerPalette = AppearanceSettings().speakerPalette }
    }

    /// Colour of a line: by diarised speaker, by source, or one colour. `isMic` = the user's own microphone stream.
    public func color(isMic: Bool, speaker: String?) -> RGBA {
        switch colorMode {
        case .single: return textColor
        case .source: return isMic ? meColor : themColor
        case .speaker:
            guard let speaker, let n = Int(speaker.filter(\.isNumber)), n > 0 else { return isMic ? meColor : themColor }
            return speakerPalette[(n - 1) % speakerPalette.count]
        }
    }
}

public struct LayoutSettings: Codable, Hashable, Sendable {
    public var mode: OverlayMode = .captions
    public var lines = 3
    public var width: Double = 900
    public var alignment: CaptionAlignment = .center
    public var level: WindowLevelOption = .statusBar
    public var autoHideSeconds: Double = 0     // 0 = never
    public var hideFromSharing = false
    public var showSubtitles = true
    /// false (default): the subtitle panel can be dragged / resized; true: mouse clicks pass through it.
    public var clickThrough = false
    /// In Both mode, show "System" and "Mic" in two separate panels (default) instead of one combined panel.
    public var separateSources = true
    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, lines, width, alignment, level, autoHideSeconds, hideFromSharing, showSubtitles, clickThrough, separateSources
    }

    /// Tolerant decoding: profiles saved by older versions lack newer keys.
    public init(from d: Decoder) throws {
        self.init()
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(OverlayMode.self, forKey: .mode) ?? mode
        lines = try c.decodeIfPresent(Int.self, forKey: .lines) ?? lines
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? width
        alignment = try c.decodeIfPresent(CaptionAlignment.self, forKey: .alignment) ?? alignment
        level = try c.decodeIfPresent(WindowLevelOption.self, forKey: .level) ?? level
        autoHideSeconds = try c.decodeIfPresent(Double.self, forKey: .autoHideSeconds) ?? autoHideSeconds
        hideFromSharing = try c.decodeIfPresent(Bool.self, forKey: .hideFromSharing) ?? hideFromSharing
        showSubtitles = try c.decodeIfPresent(Bool.self, forKey: .showSubtitles) ?? showSubtitles
        clickThrough = try c.decodeIfPresent(Bool.self, forKey: .clickThrough) ?? clickThrough
        separateSources = try c.decodeIfPresent(Bool.self, forKey: .separateSources) ?? separateSources
        if mode == .split { mode = .captions; separateSources = true }   // legacy split mode
    }
}

public struct ContentSettings: Codable, Hashable, Sendable {
    /// Default: show only the target language (no foreign-language text when translation is on).
    public var mode: ContentDisplay = .translation
    /// "System" / "Mic" prefix. Off by default — turn on when you want to see who is speaking.
    public var showSourceLabel = false
    public var showSpeaker = false
    public var showLanguage = false
    public var showTimestamp = false
    public init() {}
}

public struct TranslationSettings: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case off, oneWay, twoWay
        public var title: String { switch self { case .off: "Off"; case .oneWay: "One-way"; case .twoWay: "Two-way" } }
    }
    public var kind: Kind = .off
    public var target = "ru"
    public var languageA = "ru"
    public var languageB = "en"
    public init(kind: Kind = .off, target: String = "ru", a: String = "ru", b: String = "en") {
        self.kind = kind; self.target = target; languageA = a; languageB = b
    }
    public var soniox: SonioxConfig.Translation? {
        switch kind {
        case .off: nil
        case .oneWay: .oneWay(target: target)
        case .twoWay: .twoWay(a: languageA, b: languageB)
        }
    }
}

public struct GlossaryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var source: String
    public var target: String
    public init(source: String, target: String) { self.source = source; self.target = target }
}

public struct RecognitionSettings: Codable, Hashable, Sendable {
    public var languageHints: [String] = ["en", "ru"]
    public var strictHints = false
    public var diarizationSystem = true
    public var diarizationMic = false
    public var endpointDelayMs = 1000
    public var domain = ""
    public var contextText = ""
    public var terms: [String] = []
    public var glossary: [GlossaryEntry] = []
    public var voiceProcessing = true
    public var micDeviceUID: String?
    public var appBundleIDs: [String] = []     // empty = all system audio
    public init() {}
}

public struct SessionSettings: Codable, Hashable, Sendable {
    public var autoPauseMinutes = 5            // 0 = off
    /// Off by default: every session starts from zero and nothing is kept on disk.
    public var saveHistory = false
    public var exportFormat = "markdown"
    public var exportFolder: String?
    public var mixIntoOne = false
    public var dedupeEchoes = true
    /// Read translations of other people's speech aloud (System stream).
    public var speakTranslations = false
    public var speechRate: Double = 0.52
    public init() {}

    enum CodingKeys: String, CodingKey {
        case autoPauseMinutes, saveHistory, exportFormat, exportFolder, mixIntoOne, dedupeEchoes, speakTranslations, speechRate
    }

    public init(from d: Decoder) throws {
        self.init()
        let c = try d.container(keyedBy: CodingKeys.self)
        autoPauseMinutes = try c.decodeIfPresent(Int.self, forKey: .autoPauseMinutes) ?? autoPauseMinutes
        saveHistory = try c.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? saveHistory
        exportFormat = try c.decodeIfPresent(String.self, forKey: .exportFormat) ?? exportFormat
        exportFolder = try c.decodeIfPresent(String.self, forKey: .exportFolder)
        mixIntoOne = try c.decodeIfPresent(Bool.self, forKey: .mixIntoOne) ?? mixIntoOne
        dedupeEchoes = try c.decodeIfPresent(Bool.self, forKey: .dedupeEchoes) ?? dedupeEchoes
        speakTranslations = try c.decodeIfPresent(Bool.self, forKey: .speakTranslations) ?? speakTranslations
        speechRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? speechRate
    }
}

public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var sources: SourceMode = .system
    public var appearance = AppearanceSettings()
    public var layout = LayoutSettings()
    public var content = ContentSettings()
    public var recognition = RecognitionSettings()
    public var translationSystem = TranslationSettings(kind: .oneWay, target: "en")
    public var translationMic = TranslationSettings(kind: .oneWay, target: "en")
    public var session = SessionSettings()

    public init(name: String) { self.name = name }

    public func translation(for s: SourceKind) -> TranslationSettings { s == .mic ? translationMic : translationSystem }

    /// Two subtitle panels ("System" / "Mic") are shown only when both sources run as separate streams.
    public var showsSeparatePanels: Bool { sources == .both && !session.mixIntoOne && layout.separateSources }

    public static var presets: [Profile] {
        var call = Profile(name: "Call RU↔EN")
        call.content.showSourceLabel = true
        call.sources = .both
        call.recognition.languageHints = ["en", "ru"]
        call.translationSystem = .init(kind: .oneWay, target: "ru")
        call.translationMic = .init(kind: .oneWay, target: "en")
        call.content.mode = .both

        var meetup = Profile(name: "Meetup HE→EN")
        meetup.sources = .mic
        meetup.recognition.languageHints = ["he", "en"]
        meetup.recognition.diarizationMic = true
        meetup.recognition.voiceProcessing = false
        meetup.translationMic = .init(kind: .oneWay, target: "en")

        var video = Profile(name: "Video EN→RU")
        video.sources = .system
        video.recognition.languageHints = ["en"]
        video.translationSystem = .init(kind: .oneWay, target: "ru")
        var def = Profile(name: "Default (→ English)")
        def.recognition.languageHints = ["en", "ru", "he"]
        return [def, call, meetup, video]
    }
}

public enum Languages {
    public static let all: [(code: String, name: String)] = [
        ("en", "English"), ("ru", "Russian"), ("he", "Hebrew"), ("fr", "French"), ("de", "German"), ("es", "Spanish"),
        ("it", "Italian"), ("pt", "Portuguese"), ("uk", "Ukrainian"), ("ar", "Arabic"), ("tr", "Turkish"), ("pl", "Polish"),
        ("nl", "Dutch"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"), ("hi", "Hindi"),
    ]
    public static func name(_ code: String) -> String { all.first { $0.code == code }?.name ?? code.uppercased() }
}
