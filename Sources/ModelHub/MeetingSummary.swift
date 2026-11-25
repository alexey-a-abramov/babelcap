import Foundation
import LocalLLM

/// Meeting summary with a local MLX chat model (Qwen3 4B / EuroLLM 9B). Nothing leaves the Mac.
public enum MeetingSummary {
    public static let preferredModels = ["mlx-qwen3-4b", "mlx-eurollm-9b"]

    @MainActor
    public static var model: CatalogEntry? {
        preferredModels.first { ModelDownloads.shared.isInstalled($0) }.flatMap(ModelCatalog.entry)
    }

    @MainActor
    public static func summarize(transcript: String, language: String) async throws -> String {
        guard let e = model else {
            throw NSError(domain: "Babelcap", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Download Qwen3 4B Instruct in Models & Providers to summarize meetings on this Mac."])
        }
        let folder = ModelStorage.folder(for: e.id).appendingPathComponent("model")
        let lang = Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language
        // Keep the prompt within a comfortable context: the most recent ~12 000 characters.
        let text = transcript.count > 12_000 ? String(transcript.suffix(12_000)) : transcript
        let system = """
        You summarise meeting transcripts. Write in \(lang). Use short Markdown sections:
        **Summary** (2–4 sentences), **Key points** (bullets), **Decisions** (bullets), **Action items** (bullets with owners when named).
        Only use facts from the transcript. If a section has nothing, write "—".
        """
        return try await MLXRunner.shared.complete(folder: folder, system: system, user: "Transcript:\n\n\(text)", maxTokens: 700)
    }
}
