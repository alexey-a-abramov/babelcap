import Foundation
import LocalEngines
import LocalLLM

/// Which text translator on-device speech engines use: "auto", "apple", "whisper" (Whisper's own audio translation,
/// English only) or a translation model's catalog id.
public enum TranslatorChoice {
    public static let auto = "auto", apple = "apple", whisper = "whisper"

    @MainActor
    public static func resolve(_ id: String) -> (any TextTranslator)? {
        switch id {
        case apple: return AppleTextTranslator()
        case whisper: return nil
        case auto:
            if let installed = ModelCatalog.translatorPreference.first(where: { ModelDownloads.shared.isInstalled($0) }),
               let e = ModelCatalog.entry(installed) { return translator(for: e) }
            return AppleTextTranslator()
        default:
            guard let e = ModelCatalog.entry(id), ModelDownloads.shared.isInstalled(id) else { return AppleTextTranslator() }
            return translator(for: e)
        }
    }

    public static func translator(for e: CatalogEntry) -> (any TextTranslator)? {
        guard case let .mlxTranslator(style)? = e.engine else { return nil }
        return MLXTranslator(folder: ModelStorage.folder(for: e.id).appendingPathComponent("model"),
                             style: style == .translateGemma ? .translateGemma : .chat, name: e.name)
    }

    @MainActor
    public static func title(_ id: String) -> String {
        switch id {
        case auto:
            let r = resolve(auto)
            return "Auto (\(r?.name ?? "none"))"
        case apple: return "Apple Translation"
        case whisper: return "Whisper's own (into English only)"
        default: return ModelCatalog.entry(id)?.name ?? id
        }
    }
}
