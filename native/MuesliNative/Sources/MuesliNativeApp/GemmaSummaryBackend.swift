import Foundation
import LLM

/// On-device meeting-summarization backend: Gemma 4 (E4B default, or E2B/QAT
/// variants) GGUF via upstream LLM.swift (llama.cpp b10068, gemma4 support).
/// LLM.swift is macOS 13+, so no availability gate is needed.
///
/// Uses the chat-template path (`template == nil` → `respondUsingChatTemplate` →
/// embedded GGUF jinja), system prompt via `bot.systemPrompt`, and thinking
/// suppression. Sampler defaults are Google's recommended Gemma 4 settings —
/// `temp=1.0, top_p=0.95, top_k=64`, repeat penalty off — and must not be lowered
/// for quality (Gemma 4 degrades at low temperature / greedy top_k=1).
actor GemmaSummaryBackend {
    static let shared = GemmaSummaryBackend()

    /// Google's recommended Gemma 4 sampler (also baked into the GGUF
    /// `general.sampling.*` metadata). Keep `topK = 64` — top_k=1 is greedy and
    /// disables temperature/top_p.
    static let defaultTopK: Int32 = 64
    static let defaultTopP: Double = 0.95
    static let defaultTemperature: Double = 1.0
    static let defaultContextTokens: Int = 32_768
    static let defaultMaxOutputTokens = 4_096

    /// Backend label used in `MeetingSummaryError` messages and logs.
    static let displayName = MeetingSummaryBackendOption.gemmaLocal.label

    private var bot: LLM?
    private var loadedModelID: String?
    private var loadedSamplerKey: String?
    private let inferenceGate = InferenceGate()

    /// Generate a meeting summary (or title) from the rendered Homan prompts.
    ///
    /// - Parameters:
    ///   - systemPrompt: rendered `summaryInstructions(...)` (or title instructions).
    ///   - userPrompt: rendered `summaryUserPrompt(...)` (or the title excerpt).
    ///   - modelID: `GemmaSummaryModel` catalog id (`config.gemmaSummaryModel`).
    ///   - settings: optional per-model generation overrides (temp/top_p/max tokens/context).
    /// - Returns: the cleaned, trimmed summary text.
    /// - Throws: `MeetingSummaryError` for empty/degenerate output; a generic error
    ///   if the model is missing or fails to load.
    func summarize(
        systemPrompt: String,
        userPrompt: String,
        modelID: String,
        settings: SummaryGenerationSettings
    ) async throws -> String {
        // Actors can re-enter while respond() awaits; serialize access to the cached mutable LLM.
        try await inferenceGate.acquire()
        do {
            try Task.checkCancellation()
            let bot = try loadBot(modelID: modelID, settings: settings)
            defer { bot.reset() }
            bot.systemPrompt = systemPrompt
            await bot.respond(to: userPrompt, thinking: .suppressed)
            let raw = bot.output
            let capped = await cappedOutput(raw, maxTokens: settings.normalized.maxOutputTokens, bot: bot)
            let cleaned = GemmaSummaryOutputCleaner.clean(capped)
            // T020: map empty/degenerate output to a plain failure — no auto-retry.
            guard GemmaSummaryOutputCleaner.isUsable(cleaned) else {
                await inferenceGate.release()
                throw MeetingSummaryError.degenerateOutput(backend: Self.displayName)
            }
            await inferenceGate.release()
            return cleaned
        } catch {
            await inferenceGate.release()
            throw error
        }
    }

    /// Release the loaded model (e.g. when its files are deleted from the Models tab).
    func shutdown() {
        bot = nil
        loadedModelID = nil
        loadedSamplerKey = nil
    }

    // MARK: - Loading

    private func loadBot(modelID: String, settings: SummaryGenerationSettings) throws -> LLM {
        let normalized = settings.normalized
        let context = Int32(normalized.contextTokens ?? Self.defaultContextTokens)
        let temperature = Float(normalized.temperature ?? Self.defaultTemperature)
        let topP = Float(normalized.topP ?? Self.defaultTopP)
        let samplerKey = "\(context)|\(temperature)|\(topP)"

        if let bot, loadedModelID == modelID, loadedSamplerKey == samplerKey {
            return bot
        }

        let model = GemmaSummaryModel.resolve(id: modelID)
        guard FileManager.default.fileExists(atPath: model.modelURL.path) else {
            throw NSError(
                domain: "GemmaSummaryBackend",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Gemma 4 summary model not found at \(model.modelURL.path). Download it from the Models tab.",
                ]
            )
        }
        guard let loaded = LLM(
            from: model.modelURL,
            seed: 7,
            topK: Self.defaultTopK,
            topP: topP,
            temp: temperature,
            repeatPenalty: 1.0,
            repetitionLookback: 64,
            historyLimit: 0,
            maxTokenCount: context
        ) else {
            throw NSError(
                domain: "GemmaSummaryBackend",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to load Gemma 4 summary model at \(model.modelURL.path).",
                ]
            )
        }
        bot = loaded
        loadedModelID = modelID
        loadedSamplerKey = samplerKey
        return loaded
    }

    /// Safety net for runaway output: LLM.swift has no max-output-token parameter,
    /// so cap a too-long summary post-hoc at the token level (approximate).
    private func cappedOutput(_ raw: String, maxTokens: Int?, bot: LLM) async -> String {
        guard let maxTokens, maxTokens > 0 else { return raw }
        let tokens = await bot.encode(raw)
        guard tokens.count > maxTokens else { return raw }
        let capped = tokens.prefix(maxTokens)
        var text: String = ""
        for token in capped {
            text += await bot.core.decode(token)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Post-processes Gemma summary output: strips thinking/marker boilerplate and
/// rejects empty or degenerate generations.
enum GemmaSummaryOutputCleaner {
    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = result.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?is)<think\b[^>]*>[\s\S]*$"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<\|turn\|>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<\|im_(?:start|end)\|>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[end of text\]"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```[A-Za-z0-9_-]*\s*"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `true` when the output is a real, non-empty answer. Rejects the "..." the
    /// client emits for an empty generation, punctuation-only stubs, and whitespace.
    static func isUsable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = trimmed.replacingOccurrences(of: "…", with: "...")
        if normalized == "..." || normalized == ". . ." {
            return false
        }
        let punctuationOnly = normalized.allSatisfy { character in
            character.isWhitespace || ".…-_,;:!?()[]{}".contains(character)
        }
        return !(punctuationOnly && normalized.count <= 8)
    }
}
