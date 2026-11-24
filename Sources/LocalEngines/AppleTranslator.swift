import Foundation
import SonioxClient
@preconcurrency import Translation

/// Offline text translation with Apple's Translation framework (macOS 26). Languages must be installed in
/// System Settings → General → Language & Region → Translation Languages.
@available(macOS 26.0, *)
public actor AppleTranslator {
    public static let shared = AppleTranslator()
    private var sessions: [String: TranslationSession] = [:]

    public enum Readiness: Sendable, Equatable { case installed, needsDownload, unsupported }

    public static func readiness(from source: String, to target: String) async -> Readiness {
        switch await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) {
        case .installed: .installed
        case .supported: .needsDownload
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    public func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let key = "\(source)>\(target)"
        let session: TranslationSession
        if let s = sessions[key] { session = s } else {
            session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
            sessions[key] = session
        }
        return try await session.translate(text).targetText
    }
}

public enum LocalTranslationHelp {
    public static func message(source: String, target: String) -> String {
        "Apple Translation \(source.uppercased()) → \(target.uppercased()) is not installed. Add both languages in System Settings → General → Language & Region → Translation Languages."
    }

    /// Precise message: not installed vs not supported at all.
    @available(macOS 26.0, *)
    public static func explain(source: String, target: String) async -> String {
        switch await AppleTranslator.readiness(from: source, to: target) {
        case .unsupported:
            let name = { (c: String) in Locale(identifier: "en").localizedString(forLanguageCode: c) ?? c.uppercased() }
            return "Apple Translation does not support \(name(source)) → \(name(target)). Use Soniox, or Whisper's own translation into English (tiny / base / small / large-v3)."
        case .needsDownload, .installed:
            return message(source: source, target: target)
        }
    }
}
