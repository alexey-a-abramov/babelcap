import Foundation
import LocalEngines
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import SonioxClient
import Tokenizers

/// Loads one MLX language model at a time from a local folder and runs prompts on it (translation, summaries).
public actor MLXRunner {
    public static let shared = MLXRunner()
    private var loaded: (path: String, container: ModelContainer)?
    private var loading: (path: String, task: Task<ModelContainer, Error>)?

    func container(_ folder: URL) async throws -> ModelContainer {
        if let l = loaded, l.path == folder.path { return l.container }
        if let l = loading, l.path == folder.path { return try await l.task.value }
        loaded = nil
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) else {
            throw LocalEngineError.modelMissing("The translation model is not downloaded yet. Open Models & Providers and download it.")
        }
        let path = folder.path
        let task = Task<ModelContainer, Error> {
            let started = Date()
            MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
            let c = try await LLMModelFactory.shared.loadContainer(from: folder, using: #huggingFaceTokenizerLoader())
            Trace.log("mlx", "loaded \(folder.lastPathComponent) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            return c
        }
        loading = (path, task)
        defer { loading = nil }
        let c = try await task.value
        loaded = (path, c)
        return c
    }

    /// Generates a completion. `raw` = a fully formatted prompt; otherwise system + user chat messages.
    public func complete(folder: URL, raw: String? = nil, system: String? = nil, user: String = "", maxTokens: Int = 400) async throws -> String {
        let c = try await container(folder)
        return try await c.perform { (context: ModelContext) async throws -> String in
            let input: LMInput
            if let raw {
                let ids = context.tokenizer.encode(text: raw, addSpecialTokens: false)
                input = LMInput(tokens: MLXArray(ids))
            } else {
                var chat: [Chat.Message] = []
                if let system { chat.append(.system(system)) }
                chat.append(.user(user))
                input = try await context.processor.prepare(input: UserInput(chat: chat))
            }
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
            // Some models (e.g. TranslateGemma) do not declare their end-of-turn marker as EOS: stop on it cleanly.
            let stopIDs = Set(Self.stopMarkers.compactMap { context.tokenizer.convertTokenToId($0) })
            let started = Date()
            let result = try MLXLMCommon.generate(input: input, parameters: params, context: context) { tokens in
                if let last = tokens.last, stopIDs.contains(last) { return .stop }
                return .more
            }
            let ids = result.tokenIds.filter { !stopIDs.contains($0) }
            let text = context.tokenizer.decode(tokenIds: ids, skipSpecialTokens: true)
            Trace.log("mlx", "\(ids.count) tokens in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            return text
        }
    }

    public func unload() { loaded = nil }

    static let stopMarkers = ["<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<start_of_turn>"]
}

/// Text translation with a local MLX model (TranslateGemma or a general instruct model).
public struct MLXTranslator: TextTranslator {
    public enum Style: Sendable { case translateGemma, chat }

    public let folder: URL
    public let style: Style
    public let name: String

    public init(folder: URL, style: Style, name: String) {
        self.folder = folder; self.style = style; self.name = name
    }

    public func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        let src = source ?? "auto"
        let out: String
        switch style {
        case .translateGemma:
            out = try await MLXRunner.shared.complete(folder: folder, raw: Self.translateGemmaPrompt(text, from: src, to: target))
        case .chat:
            let system = "You are a professional interpreter. Translate the user's text\(source.map { " from \(Self.name($0))" } ?? "") into \(Self.name(target)). Output only the translation, nothing else."
            out = try await MLXRunner.shared.complete(folder: folder, system: system, user: text)
        }
        return Self.clean(out)
    }

    public func problem(from source: String?, to target: String) async -> String? {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) ? nil : "\(name) is not downloaded yet."
    }

    static func name(_ code: String) -> String { Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code }

    /// The prompt TranslateGemma was trained with (its chat template, without the image branch).
    static func translateGemmaPrompt(_ text: String, from src: String, to tgt: String) -> String {
        let s = name(src), t = name(tgt)
        return "<bos><start_of_turn>user\nYou are a professional \(s) (\(src)) to \(t) (\(tgt)) translator. Your goal is to accurately convey the meaning and nuances of the original \(s) text while adhering to \(t) grammar, vocabulary, and cultural sensitivities.\nProduce only the \(t) translation, without any additional explanations or commentary. Please translate the following \(s) text into \(t):\n\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))<end_of_turn>\n<start_of_turn>model\n"
    }

    static func clean(_ s: String) -> String {
        var t = s
        for marker in ["<end_of_turn>", "<eos>", "<|im_end|>", "</s>"] { t = t.replacingOccurrences(of: marker, with: "") }
        if let r = t.range(of: "</think>") { t = String(t[r.upperBound...]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
