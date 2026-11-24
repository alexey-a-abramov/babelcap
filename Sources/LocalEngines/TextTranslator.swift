import Foundation
import SonioxClient

/// Translates finished sentences for local engines. Implementations: Apple Translation, a local MLX LLM.
public protocol TextTranslator: Sendable {
    var name: String { get }
    func translate(_ text: String, from source: String?, to target: String) async throws -> String
    /// A short, user-facing reason when this pair cannot work, or nil when it can.
    func problem(from source: String?, to target: String) async -> String?
}

/// Apple's offline Translation framework (macOS 26).
public struct AppleTextTranslator: TextTranslator {
    public init() {}
    public var name: String { "Apple Translation" }

    public func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        guard #available(macOS 26.0, *), let source else { throw LocalEngineError.needsNewerMacOS(26) }
        return try await AppleTranslator.shared.translate(text, from: source, to: target)
    }

    public func problem(from source: String?, to target: String) async -> String? {
        guard #available(macOS 26.0, *) else { return "Apple Translation needs macOS 26." }
        guard let source else { return nil }
        switch await AppleTranslator.readiness(from: source, to: target) {
        case .installed: return nil
        case .needsDownload, .unsupported: return await LocalTranslationHelp.explain(source: source, target: target)
        }
    }
}

/// Splits text into words and finds sentence ends (for LocalAgreement and per-sentence translation).
enum Words {
    static func split(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Compares words ignoring case and trailing punctuation (Whisper re-punctuates between passes).
    static func same(_ a: String, _ b: String) -> Bool { norm(a) == norm(b) }
    static func norm(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }

    static func commonPrefix(_ a: [String], _ b: [String]) -> Int {
        var n = 0
        while n < a.count, n < b.count, same(a[n], b[n]) { n += 1 }
        return n
    }

    static func endsSentence(_ w: String) -> Bool {
        guard let last = w.last else { return false }
        return ".?!…。？！".contains(last)
    }
}
