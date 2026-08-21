import Foundation
import MuesliCore
import os

enum MeetingSummaryError: LocalizedError {
    case backendFailed(backend: String, statusCode: Int?, message: String)
    case emptyResponse(backend: String)
    case requestFailed(backend: String, underlying: Error)
    /// On-device model produced empty or degenerate output (e.g. "...").
    /// Deliberately NOT retried — regenerating won't fix it.
    case degenerateOutput(backend: String)

    var errorDescription: String? {
        switch self {
        case let .backendFailed(backend, statusCode, message):
            let statusText = statusCode.map { " Status \($0)." } ?? ""
            return "\(backend) could not generate meeting notes.\(statusText) \(message) The selected model may be unavailable or retired."
        case let .emptyResponse(backend):
            return "\(backend) returned an empty response while generating meeting notes. The selected model may be unavailable or incompatible."
        case let .requestFailed(backend, underlying):
            return "\(backend) could not be reached while generating meeting notes. \(underlying.localizedDescription)"
        case let .degenerateOutput(backend):
            return "\(backend) did not produce usable meeting notes. Try summarizing again, or pick a different model in the Models tab."
        }
    }
}

enum MeetingSummaryRetryPolicy {
    static let defaultRetryCount = 3
    static let maximumRetryCount = 5

    static func clampedRetryCount(_ count: Int) -> Int {
        min(max(count, 0), maximumRetryCount)
    }

    static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        guard let summaryError = error as? MeetingSummaryError else {
            return false
        }

        switch summaryError {
        case .requestFailed(let backend, let underlying):
            if isPermanentRequestFailure(underlying) {
                return false
            }
            if isLocalBackend(backend), isLocalEndpointUnavailable(underlying) {
                return false
            }
            return true
        case .emptyResponse:
            return true
        case .backendFailed(_, let statusCode, _):
            guard let statusCode else { return false }
            return isTransientHTTPStatus(statusCode)
        case .degenerateOutput:
            return false
        }
    }

    static func effectiveRetryCount(configuredCount: Int, after error: Error) -> Int {
        let retryCount = clampedRetryCount(configuredCount)
        guard retryCount > 0, shouldRetry(error) else { return 0 }
        guard let summaryError = error as? MeetingSummaryError else { return 0 }

        switch summaryError {
        case .requestFailed(let backend, _),
             .emptyResponse(let backend),
             .backendFailed(let backend, _, _):
            if isLocalBackend(backend) {
                return min(retryCount, 1)
            }
            return retryCount
        case .degenerateOutput:
            return 0
        }
    }

    private static func isPermanentRequestFailure(_ error: Error) -> Bool {
        if error is CancellationError || error is ChatGPTAuthError {
            return true
        }

        guard let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .badURL, .unsupportedURL, .cancelled:
            return true
        default:
            return false
        }
    }

    private static func isLocalBackend(_ backend: String) -> Bool {
        let normalized = backend.lowercased()
        return normalized == MeetingSummaryBackendOption.ollama.backend
            || normalized == MeetingSummaryBackendOption.lmStudio.backend
            || normalized == "lm studio"
    }

    private static func isLocalEndpointUnavailable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func isTransientHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 409
            || statusCode == 425
            || statusCode == 429
            || (500..<600).contains(statusCode)
    }

    static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        min(pow(2.0, Double(max(attempt - 1, 0))), 8.0)
    }
}

struct MeetingSummaryGenerationResult: Sendable, Equatable {
    let notes: String
    let thinkingStatus: MeetingProcessingThinkingStatus?
}

private struct OllamaSummaryResponse {
    let text: String
    let thinkingStatus: MeetingProcessingThinkingStatus
}

enum MeetingSummaryClient {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingSummary")
    private static let openAIURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let defaultOllamaBaseURL = URL(string: "http://localhost:11434")!
    private static let defaultLMStudioBaseURL = URL(string: "http://localhost:1234")!
    private static let defaultOpenAIModel = "gpt-5.4-mini"
    private static let defaultOpenRouterModel = "stepfun/step-3.5-flash:free"
    private static let defaultChatGPTModel = "gpt-5.4-mini"
    private static let defaultOllamaModel = "qwen3.5"
    private static let titlePromptCharacterLimit = 6_000
    private static let ollamaTitleTimeout: TimeInterval = 120
    private static let lmStudioTitleTimeout: TimeInterval = 120
    private static let customLLMTitleTimeout: TimeInterval = 120

    private static let titleInstructions = """
    Generate a short, descriptive meeting title (3-7 words) from these transcript excerpts and any written notes. \
    Treat written notes as high-priority context: they may contain the clearest statement of the meeting's topic or outcome. \
    Prefer the main topic and outcome across the whole meeting over opening small talk or setup. \
    Write the title in the same language as the meeting transcript; do not default to English just because the examples are in English. \
    Return ONLY the title text, nothing else. No quotes, no prefix, no explanation. \
    Examples: "Q3 Sprint Planning", "Customer Onboarding Review", "Security Audit Discussion"
    """

    static func summarize(
        transcript: String,
        meetingTitle: String,
        config: AppConfig,
        template: MeetingTemplateSnapshot = MeetingTemplates.auto.snapshot,
        manualNotesToRetain: String? = nil,
        visualContext: String? = nil,
        previousMeetingNotes: String? = nil
    ) async throws -> String {
        try await summarizeWithMetadata(
            transcript: transcript,
            meetingTitle: meetingTitle,
            config: config,
            template: template,
            manualNotesToRetain: manualNotesToRetain,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes
        ).notes
    }

    static func summarizeWithMetadata(
        transcript: String,
        meetingTitle: String,
        config: AppConfig,
        template: MeetingTemplateSnapshot = MeetingTemplates.auto.snapshot,
        manualNotesToRetain: String? = nil,
        visualContext: String? = nil,
        previousMeetingNotes: String? = nil
    ) async throws -> MeetingSummaryGenerationResult {
        try await withSummaryRetries(maxRetries: config.meetingSummaryRetryCount) {
            try await summarizeOnce(
                transcript: transcript,
                meetingTitle: meetingTitle,
                config: config,
                template: template,
                manualNotesToRetain: manualNotesToRetain,
                visualContext: visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
        }
    }

    static func withSummaryRetries<Result>(
        maxRetries: Int,
        sleep: (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        },
        operation: () async throws -> Result
    ) async throws -> Result {
        let retryCount = MeetingSummaryRetryPolicy.clampedRetryCount(maxRetries)
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                let effectiveRetryCount = MeetingSummaryRetryPolicy.effectiveRetryCount(
                    configuredCount: retryCount,
                    after: error
                )
                guard attempt < effectiveRetryCount else {
                    throw error
                }
                attempt += 1
                fputs("[summary] retrying summary generation after failure (\(attempt)/\(effectiveRetryCount)): \(error.localizedDescription)\n", stderr)
                try await sleep(MeetingSummaryRetryPolicy.retryDelay(forAttempt: attempt))
            }
        }
    }

    private static func summarizeOnce(
        transcript: String,
        meetingTitle: String,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        manualNotesToRetain: String?,
        visualContext: String?,
        previousMeetingNotes: String?
    ) async throws -> MeetingSummaryGenerationResult {
        let backend = (config.meetingSummaryBackend.isEmpty ? MeetingSummaryBackendOption.transcriptOnly.backend : config.meetingSummaryBackend).lowercased()
        if backend == MeetingSummaryBackendOption.transcriptOnly.backend {
            // Transcript-only: no LLM request. Notes carry any manual notes the
            // user wrote; without them the meeting keeps its raw transcript
            // (notesState .missing shows it in the Notes tab).
            return MeetingSummaryGenerationResult(
                notes: notesByRetainingManualNotes(generatedNotes: "", manualNotes: manualNotesToRetain),
                thinkingStatus: nil
            )
        }
        let generatedNotes: String
        if backend == MeetingSummaryBackendOption.chatGPT.backend {
            generatedNotes = try await summarizeWithChatGPT(
                transcript: transcript,
                meetingTitle: meetingTitle,
                manualNotes: manualNotesToRetain,
                config: config,
                template: template,
                visualContext: visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
            return MeetingSummaryGenerationResult(
                notes: notesByRetainingManualNotes(generatedNotes: generatedNotes, manualNotes: manualNotesToRetain),
                thinkingStatus: nil
            )
        }
        if backend == MeetingSummaryBackendOption.openRouter.backend {
            generatedNotes = try await summarizeWithOpenRouter(
                transcript: transcript,
                meetingTitle: meetingTitle,
                manualNotes: manualNotesToRetain,
                config: config,
                template: template,
                visualContext: visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
            return MeetingSummaryGenerationResult(
                notes: notesByRetainingManualNotes(generatedNotes: generatedNotes, manualNotes: manualNotesToRetain),
                thinkingStatus: nil
            )
        }
        if backend == MeetingSummaryBackendOption.ollama.backend {
            let ollamaResponse = try await summarizeWithOllama(
                transcript: transcript,
                meetingTitle: meetingTitle,
                manualNotes: manualNotesToRetain,
                config: config,
                template: template,
                visualContext: visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
            return MeetingSummaryGenerationResult(
                notes: notesByRetainingManualNotes(
                    generatedNotes: ollamaResponse.text,
                    manualNotes: manualNotesToRetain
                ),
                thinkingStatus: ollamaResponse.thinkingStatus
            )
        }
        if backend == MeetingSummaryBackendOption.lmStudio.backend {
            generatedNotes = try await summarizeWithLMStudio(
                transcript: transcript,
                meetingTitle: meetingTitle,
                manualNotes: manualNotesToRetain,
                config: config,
                template: template,
                visualContext: visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
            return MeetingSummaryGenerationResult(
                notes: notesByRetainingManualNotes(generatedNotes: generatedNotes, manualNotes: manualNotesToRetain),
                thinkingStatus: nil
            )
        }
        if backend == MeetingSummaryBackendOption.customLLM.backend {
            generatedNotes = try await summarizeWithCustomLLM(
                transcript: transcript,
                meetingTitle: meetingTitle,
                manualNotes: manualNotesToRetain,
                config: config,
                template: template,
                visualContext: visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
            return MeetingSummaryGenerationResult(
                notes: notesByRetainingManualNotes(generatedNotes: generatedNotes, manualNotes: manualNotesToRetain),
                thinkingStatus: nil
            )
        }
        if backend == MeetingSummaryBackendOption.gemmaLocal.backend {
            generatedNotes = try await summarizeWithGemma(
                transcript: transcript,
                meetingTitle: meetingTitle,
                manualNotes: manualNotesToRetain,
                config: config,
                template: template,
                visualContext: visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
            return MeetingSummaryGenerationResult(
                notes: notesByRetainingManualNotes(generatedNotes: generatedNotes, manualNotes: manualNotesToRetain),
                thinkingStatus: nil
            )
        }
        generatedNotes = try await summarizeWithOpenAI(
            transcript: transcript,
            meetingTitle: meetingTitle,
            manualNotes: manualNotesToRetain,
            config: config,
            template: template,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes
        )
        return MeetingSummaryGenerationResult(
            notes: notesByRetainingManualNotes(generatedNotes: generatedNotes, manualNotes: manualNotesToRetain),
            thinkingStatus: nil
        )
    }

    static func summaryFailureNotes(transcript: String, meetingTitle: String, error: Error, manualNotes: String? = nil) -> String {
        let trimmedTitle = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedManualNotes = manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var sections = ["## Summary failed"]
        if !trimmedTitle.isEmpty {
            sections.append("Meeting: \(trimmedTitle)")
        }
        sections.append("Homan could not generate structured meeting notes.\n\n\(error.localizedDescription)")
        if !trimmedManualNotes.isEmpty {
            sections.append("### Written notes\n\n\(trimmedManualNotes)")
        }
        sections.append("## Raw Transcript\n\n\(transcript)")
        return sections.joined(separator: "\n\n")
    }

    static func summaryInstructions(
        for template: MeetingTemplateSnapshot,
        manualNotes: String? = nil,
        previousMeetingNotes: String? = nil,
        userName: String = "",
        promptTemplate: String = MeetingSummaryPromptTemplates.defaultSystem
    ) -> String {
        let normalizedOwner = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let editableInstructions = MeetingSummaryPromptTemplates.render(
            promptTemplate,
            context: MeetingSummaryPromptContext(
                template: template.prompt,
                templateName: template.name,
                userName: normalizedOwner,
                meetingTitle: "",
                transcript: "",
                meetingContext: "",
                previousMeetingNotes: previousMeetingNotes ?? "",
                writtenNotes: manualNotes ?? ""
            )
        )
        return speakerRoleContract(userName: normalizedOwner)
            + "\n\n"
            + editableInstructions
    }

    /// This source-role legend is application data semantics, not an editable
    /// style prompt. It is therefore attached to every summary backend even if
    /// a custom prompt predates speaker-aware transcripts.
    static func speakerRoleContract(userName: String) -> String {
        let owner = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerSentence = owner.isEmpty
            ? ""
            : "The app owner's name is \(owner). "
        let ownerAttribution = owner.isEmpty
            ? "the local app owner"
            : owner
        return """
        Transcript speaker-role contract:
        \(ownerSentence)In a diarized transcript, a line labeled "You" comes from the app owner's local microphone track, so identify "You" as \(ownerAttribution).
        A line labeled "Others" comes from the remote system-audio track and must not be attributed to \(ownerAttribution).
        "Speaker 1", "Speaker 2", and similar labels are anonymous acoustic identities scoped only to this meeting. In a source-aware meeting they come from the remote system-audio track; in an imported mixed recording their side is unknown. Never assume a numbered Speaker is \(ownerAttribution).
        A legacy line labeled only "Speaker" has no reliable side attribution.
        Do not infer or change a speaker's identity from the language they use, the content of a remark, or a name mentioned in conversation. Do not use the LLM to repair or reinterpret diarization.
        """
    }

    static func summaryUserPrompt(
        transcript: String,
        meetingTitle: String,
        manualNotes: String? = nil,
        visualContext: String? = nil,
        previousMeetingNotes: String? = nil,
        template: MeetingTemplateSnapshot = MeetingTemplates.auto.snapshot,
        userName: String = "",
        promptTemplate: String = MeetingSummaryPromptTemplates.defaultUser
    ) -> String {
        let visualContextCharCount = visualContext?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
        logger.info("summary prompt visualContextIncluded=\(visualContextCharCount > 0) visualContextChars=\(visualContextCharCount)")
        fputs("[summary] prompt visualContextIncluded=\(visualContextCharCount > 0) visualContextChars=\(visualContextCharCount)\n", stderr)
        return MeetingSummaryPromptTemplates.render(
            promptTemplate,
            context: MeetingSummaryPromptContext(
                template: template.prompt,
                templateName: template.name,
                userName: userName.trimmingCharacters(in: .whitespacesAndNewlines),
                meetingTitle: meetingTitle,
                transcript: transcript,
                meetingContext: visualContext ?? "",
                previousMeetingNotes: previousMeetingNotes ?? "",
                writtenNotes: manualNotes ?? ""
            )
        )
    }

    static func applyGenerationSettings(
        _ settings: SummaryGenerationSettings,
        to body: inout [String: Any],
        maxOutputTokenKey: String
    ) {
        let settings = settings.normalized
        if let value = settings.maxOutputTokens {
            body[maxOutputTokenKey] = value
        }
        if let value = settings.temperature {
            body["temperature"] = value
        }
        if let value = settings.topP {
            body["top_p"] = value
        }
    }

    static func ollamaOptions(for settings: SummaryGenerationSettings) -> [String: Any] {
        let settings = settings.normalized
        var options: [String: Any] = [:]
        if let value = settings.maxOutputTokens {
            options["num_predict"] = value
        }
        if let value = settings.contextTokens {
            options["num_ctx"] = value
        }
        if let value = settings.temperature {
            options["temperature"] = value
        }
        if let value = settings.topP {
            options["top_p"] = value
        }
        return options
    }

    static func ollamaThinkingStatus(from message: [String: Any]) -> MeetingProcessingThinkingStatus {
        guard message.keys.contains("thinking") else { return .notReported }
        let thinking = (message["thinking"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return thinking.isEmpty ? .notUsed : .used
    }

    static func applyOllamaThinking(_ enabled: Bool, to body: inout [String: Any]) {
        body["think"] = enabled
    }

    private static func applyTimeout(
        from settings: SummaryGenerationSettings,
        to request: inout URLRequest
    ) {
        if let timeoutSeconds = settings.normalized.timeoutSeconds {
            request.timeoutInterval = TimeInterval(timeoutSeconds)
        }
    }

    static func notesByRetainingManualNotes(generatedNotes: String, manualNotes: String?) -> String {
        let trimmedManualNotes = manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedManualNotes.isEmpty else { return generatedNotes }

        let trimmedGeneratedNotes = generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let missingNotes = manualNoteBlocks(from: trimmedManualNotes).filter { note in
            !generatedNotesContainManualNote(trimmedGeneratedNotes, note: note)
        }
        guard !missingNotes.isEmpty else {
            return trimmedGeneratedNotes
        }
        let manualSection = "### Written notes\n\n\(missingNotes.joined(separator: "\n"))"
        if trimmedGeneratedNotes.isEmpty {
            return manualSection
        }
        return "\(trimmedGeneratedNotes)\n\n\(manualSection)"
    }

    static func manualNoteBlocks(from notes: String) -> [String] {
        let normalized = notes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let lines = normalized.components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let listLines = nonEmptyLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("- ")
                || trimmed.hasPrefix("* ")
                || trimmed.hasPrefix("• ")
                || trimmed.hasPrefix("- [ ] ")
                || trimmed.hasPrefix("- [x] ")
                || trimmed.hasPrefix("- [X] ")
                || isNumberedListLine(trimmed)
        }
        if !listLines.isEmpty, listLines.count == nonEmptyLines.count {
            return listLines.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return [normalized]
    }

    private static func generatedNotesContainManualNote(_ generatedNotes: String, note: String) -> Bool {
        let normalizedNote = normalizedManualNoteMatchText(note)
        guard !normalizedNote.isEmpty else { return true }
        let generatedLines = generatedNotes
            .components(separatedBy: .newlines)
            .map(normalizedManualNoteMatchText)
        if generatedLines.contains(normalizedNote) {
            return true
        }
        return normalizedNote.count >= 40
            && normalizedManualNoteMatchText(generatedNotes).contains(normalizedNote)
    }

    private static func normalizedManualNoteMatchText(_ text: String) -> String {
        normalizedManualNoteContent(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func normalizedManualNoteContent(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "- [ ] ", "- [x] ", "- [X] ",
            "* [ ] ", "* [x] ", "* [X] ",
            "• [ ] ", "• [x] ", "• [X] ",
            "- ", "* ", "• "
        ]
        if let prefix = prefixes.first(where: { trimmed.hasPrefix($0) }) {
            trimmed.removeFirst(prefix.count)
            return trimmed
        }

        if let match = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            trimmed.removeSubrange(match)
        }
        return trimmed
    }

    private static func isNumberedListLine(_ line: String) -> Bool {
        var sawDigit = false
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            sawDigit = true
            index = line.index(after: index)
        }
        guard sawDigit, index < line.endIndex, line[index] == "." || line[index] == ")" else { return false }
        let next = line.index(after: index)
        return next < line.endIndex && line[next].isWhitespace
    }

    private static func summarizeWithOpenAI(
        transcript: String,
        meetingTitle: String,
        manualNotes: String?,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        visualContext: String? = nil,
        previousMeetingNotes: String? = nil
    ) async throws -> String {
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? config.openAIAPIKey
        guard !apiKey.isEmpty else {
            return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
        }

        let instructions = summaryInstructions(
            for: template,
            manualNotes: manualNotes,
            previousMeetingNotes: previousMeetingNotes,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummarySystemPrompt
        )
        let userPrompt = summaryUserPrompt(
            transcript: transcript,
            meetingTitle: meetingTitle,
            manualNotes: manualNotes,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes,
            template: template,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummaryUserPrompt
        )
        let model = config.resolvedMeetingSummaryModel(for: .openAI)
        let generationSettings = config.meetingSummaryGenerationSettings(backend: .openAI, model: model)
        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": userPrompt],
            ],
            "reasoning": ["effort": SummaryModelPreset.reasoningEffort(for: model) ?? "low"],
            "text": ["verbosity": "low"],
        ]
        applyGenerationSettings(
            generationSettings,
            to: &body,
            maxOutputTokenKey: "max_output_tokens"
        )

        var request = URLRequest(url: openAIURL)
        applyTimeout(from: generationSettings, to: &request)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "OpenAI")
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenAIText(from: json),
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw MeetingSummaryError.backendFailed(backend: "OpenAI", statusCode: nil, message: message)
                }
                throw MeetingSummaryError.emptyResponse(backend: "OpenAI")
            }
            return text
        } catch {
            throw summaryRequestError(backend: "OpenAI", error: error)
        }
    }

    private static func summarizeWithOpenRouter(
        transcript: String,
        meetingTitle: String,
        manualNotes: String?,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        visualContext: String? = nil,
        previousMeetingNotes: String? = nil
    ) async throws -> String {
        let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? config.openRouterAPIKey
        guard !apiKey.isEmpty else {
            return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
        }

        let model = config.resolvedMeetingSummaryModel(for: .openRouter)
        let generationSettings = config.meetingSummaryGenerationSettings(backend: .openRouter, model: model)
        let instructions = summaryInstructions(
            for: template,
            manualNotes: manualNotes,
            previousMeetingNotes: previousMeetingNotes,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummarySystemPrompt
        )
        let userPrompt = summaryUserPrompt(
            transcript: transcript,
            meetingTitle: meetingTitle,
            manualNotes: manualNotes,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes,
            template: template,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummaryUserPrompt
        )
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": userPrompt],
            ],
        ]
        applyGenerationSettings(generationSettings, to: &body, maxOutputTokenKey: "max_tokens")

        var request = URLRequest(url: openRouterURL)
        applyTimeout(from: generationSettings, to: &request)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(AppIdentity.displayName, forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "OpenRouter")
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenRouterText(from: json),
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw MeetingSummaryError.backendFailed(backend: "OpenRouter", statusCode: nil, message: message)
                }
                throw MeetingSummaryError.emptyResponse(backend: "OpenRouter")
            }
            return text
        } catch {
            throw summaryRequestError(backend: "OpenRouter", error: error)
        }
    }

    private static func summarizeWithChatGPT(
        transcript: String,
        meetingTitle: String,
        manualNotes: String?,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        visualContext: String? = nil,
        previousMeetingNotes: String? = nil
    ) async throws -> String {
        do {
            let instructions = summaryInstructions(
                for: template,
                manualNotes: manualNotes,
                previousMeetingNotes: previousMeetingNotes,
                userName: config.userName,
                promptTemplate: config.resolvedMeetingSummarySystemPrompt
            )
            let model = config.resolvedMeetingSummaryModel(for: .chatGPT)
            let generationSettings = config.meetingSummaryGenerationSettings(backend: .chatGPT, model: model)
            let text = try await ChatGPTResponsesClient.respond(
                systemPrompt: instructions,
                userPrompt: summaryUserPrompt(
                    transcript: transcript,
                    meetingTitle: meetingTitle,
                    manualNotes: manualNotes,
                    visualContext: visualContext,
                    previousMeetingNotes: previousMeetingNotes,
                    template: template,
                    userName: config.userName,
                    promptTemplate: config.resolvedMeetingSummaryUserPrompt
                ),
                model: model,
                logCategory: "summary",
                generationSettings: generationSettings,
                timeout: generationSettings.timeoutSeconds.map(TimeInterval.init)
            )
            guard !text.isEmpty else {
                throw MeetingSummaryError.emptyResponse(backend: "ChatGPT")
            }
            return text
        } catch {
            fputs("[summary] ChatGPT summarization failed: \(error)\n", stderr)
            throw summaryRequestError(backend: "ChatGPT", error: error)
        }
    }

    private static func summarizeWithOllama(
        transcript: String,
        meetingTitle: String,
        manualNotes: String?,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        visualContext: String? = nil,
        previousMeetingNotes: String? = nil
    ) async throws -> OllamaSummaryResponse {
        let baseURLString = config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL: URL
        if baseURLString.isEmpty {
            baseURL = defaultOllamaBaseURL
        } else {
            guard let url = URL(string: baseURLString) else {
                throw MeetingSummaryError.backendFailed(backend: "Ollama", statusCode: nil, message: "Invalid Ollama URL: \(baseURLString)")
            }
            baseURL = url
        }
        let chatURL = baseURL.appendingPathComponent("api/chat")

        let model = config.resolvedMeetingSummaryModel(for: .ollama)
        let generationSettings = config.meetingSummaryGenerationSettings(backend: .ollama, model: model)
        let instructions = summaryInstructions(
            for: template,
            manualNotes: manualNotes,
            previousMeetingNotes: previousMeetingNotes,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummarySystemPrompt
        )
        let userPrompt = summaryUserPrompt(
            transcript: transcript,
            meetingTitle: meetingTitle,
            manualNotes: manualNotes,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes,
            template: template,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummaryUserPrompt
        )
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": userPrompt],
            ],
            "stream": false,
        ]
        applyOllamaThinking(true, to: &body)
        let options = ollamaOptions(for: generationSettings)
        if !options.isEmpty {
            body["options"] = options
        }

        var request = URLRequest(url: chatURL)
        applyTimeout(from: generationSettings, to: &request)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        OllamaAuthorization.apply(configuredToken: config.ollamaAPIKey, to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "Ollama")
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = json["message"] as? [String: Any],
                let text = message["content"] as? String,
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw MeetingSummaryError.backendFailed(backend: "Ollama", statusCode: nil, message: message)
                }
                throw MeetingSummaryError.emptyResponse(backend: "Ollama")
            }
            return OllamaSummaryResponse(
                text: text,
                thinkingStatus: ollamaThinkingStatus(from: message)
            )
        } catch {
            throw summaryRequestError(backend: "Ollama", error: error)
        }
    }

    private static func summarizeWithLMStudio(
        transcript: String,
        meetingTitle: String,
        manualNotes: String?,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        visualContext: String? = nil,
        previousMeetingNotes: String? = nil
    ) async throws -> String {
        guard let requestURL = resolveLMStudioURL(config: config) else {
            throw MeetingSummaryError.backendFailed(backend: "LM Studio", statusCode: nil, message: "Invalid LM Studio URL: \(config.lmStudioURL)")
        }
        let configuredModel = config.resolvedMeetingSummaryModel(for: .lmStudio)
        guard !configuredModel.isEmpty else {
            throw MeetingSummaryError.backendFailed(
                backend: "LM Studio",
                statusCode: nil,
                message: "No model selected. Select an LM Studio model in Settings."
            )
        }
        return try await summarizeWithChatCompletions(
            backend: "LM Studio",
            requestURL: requestURL,
            apiKey: "",
            model: configuredModel,
            transcript: transcript,
            meetingTitle: meetingTitle,
            manualNotes: manualNotes,
            config: config,
            template: template,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes,
            generationSettings: config.meetingSummaryGenerationSettings(
                backend: .lmStudio,
                model: configuredModel
            )
        )
    }

    private static func summarizeWithCustomLLM(
        transcript: String,
        meetingTitle: String,
        manualNotes: String?,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        visualContext: String? = nil,
        previousMeetingNotes: String? = nil
    ) async throws -> String {
        let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
        guard let requestURL = resolveCustomLLMURL(config: config, format: format) else {
            throw MeetingSummaryError.backendFailed(backend: "Custom LLM", statusCode: nil, message: "Invalid custom URL: \(config.customLLMURL)")
        }
        let configuredModel = config.resolvedMeetingSummaryModel(for: .customLLM)
        guard !configuredModel.isEmpty else {
            throw MeetingSummaryError.backendFailed(
                backend: "Custom LLM",
                statusCode: nil,
                message: "No model selected. Enter a model in Settings."
            )
        }
        let apiKey = config.customLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if customLLMRequiresAPIKey(config: config) && apiKey.isEmpty {
            throw MeetingSummaryError.backendFailed(
                backend: "Custom LLM",
                statusCode: nil,
                message: "Enter an API key for the selected Custom LLM format."
            )
        }

        switch format {
        case .openAI:
            return try await summarizeWithChatCompletions(
                backend: "Custom LLM",
                requestURL: requestURL,
                apiKey: apiKey,
                model: configuredModel,
                transcript: transcript,
                meetingTitle: meetingTitle,
                manualNotes: manualNotes,
                config: config,
                template: template,
                visualContext: visualContext,
                previousMeetingNotes: previousMeetingNotes,
                generationSettings: config.meetingSummaryGenerationSettings(
                    backend: .customLLM,
                    model: configuredModel
                )
            )
        case .anthropic:
            return try await summarizeWithAnthropicMessages(
                backend: "Custom LLM",
                requestURL: requestURL,
                apiKey: apiKey,
                model: configuredModel,
                transcript: transcript,
                meetingTitle: meetingTitle,
                manualNotes: manualNotes,
                config: config,
                template: template,
                visualContext: visualContext,
                previousMeetingNotes: previousMeetingNotes,
                generationSettings: config.meetingSummaryGenerationSettings(
                    backend: .customLLM,
                    model: configuredModel
                )
            )
        }
    }

    private static func summarizeWithGemma(
        transcript: String,
        meetingTitle: String,
        manualNotes: String?,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        visualContext: String? = nil,
        previousMeetingNotes: String? = nil
    ) async throws -> String {
        let modelID = config.gemmaSummaryModel
        // Mirrors the cloud backends: when the backend is not actually configured
        // (model not downloaded), keep the raw transcript instead of failing.
        if let fallback = gemmaUnavailableFallback(
            transcript: transcript,
            meetingTitle: meetingTitle,
            isModelDownloaded: GemmaSummaryModel.resolve(id: modelID).isDownloaded
        ) {
            return fallback
        }
        let settings = config.meetingSummaryGenerationSettings(
            backend: .gemmaLocal,
            model: config.resolvedMeetingSummaryModel(for: .gemmaLocal)
        )
        let systemPrompt = summaryInstructions(
            for: template,
            manualNotes: manualNotes,
            previousMeetingNotes: previousMeetingNotes,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummarySystemPrompt
        )
        let userPrompt = summaryUserPrompt(
            transcript: transcript,
            meetingTitle: meetingTitle,
            manualNotes: manualNotes,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes,
            template: template,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummaryUserPrompt
        )
        return try await GemmaSummaryBackend.shared.summarize(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            modelID: modelID,
            settings: settings
        )
    }

    static func gemmaUnavailableFallback(
        transcript: String,
        meetingTitle: String,
        isModelDownloaded: Bool
    ) -> String? {
        guard !isModelDownloaded else { return nil }
        return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
    }

    static func customLLMRequiresAPIKey(config: AppConfig) -> Bool {
        (CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI) == .anthropic
    }

    static func lmStudioHasRequiredSettings(config: AppConfig) -> Bool {
        !config.lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func customLLMHasRequiredSettings(config: AppConfig) -> Bool {
        let model = config.customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = config.customLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !model.isEmpty && (!customLLMRequiresAPIKey(config: config) || !apiKey.isEmpty)
    }

    private static func summarizeWithChatCompletions(
        backend: String,
        requestURL: URL,
        apiKey: String,
        model: String,
        transcript: String,
        meetingTitle: String,
        manualNotes: String?,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        visualContext: String?,
        previousMeetingNotes: String?,
        generationSettings: SummaryGenerationSettings
    ) async throws -> String {
        let instructions = summaryInstructions(
            for: template,
            manualNotes: manualNotes,
            previousMeetingNotes: previousMeetingNotes,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummarySystemPrompt
        )
        let userPrompt = summaryUserPrompt(
            transcript: transcript,
            meetingTitle: meetingTitle,
            manualNotes: manualNotes,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes,
            template: template,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummaryUserPrompt
        )
        let isOpenAI = requestURL.host?.contains("openai.com") == true
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": userPrompt],
            ],
        ]
        applyGenerationSettings(
            generationSettings,
            to: &body,
            maxOutputTokenKey: isOpenAI ? "max_completion_tokens" : "max_tokens"
        )

        var request = URLRequest(url: requestURL)
        applyTimeout(from: generationSettings, to: &request)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: backend)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenRouterText(from: json),
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw MeetingSummaryError.backendFailed(backend: backend, statusCode: nil, message: message)
                }
                throw MeetingSummaryError.emptyResponse(backend: backend)
            }
            return text
        } catch {
            throw summaryRequestError(backend: backend, error: error)
        }
    }

    private static func summarizeWithAnthropicMessages(
        backend: String,
        requestURL: URL,
        apiKey: String,
        model: String,
        transcript: String,
        meetingTitle: String,
        manualNotes: String?,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        visualContext: String?,
        previousMeetingNotes: String?,
        generationSettings: SummaryGenerationSettings
    ) async throws -> String {
        let instructions = summaryInstructions(
            for: template,
            manualNotes: manualNotes,
            previousMeetingNotes: previousMeetingNotes,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummarySystemPrompt
        )
        let userPrompt = summaryUserPrompt(
            transcript: transcript,
            meetingTitle: meetingTitle,
            manualNotes: manualNotes,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes,
            template: template,
            userName: config.userName,
            promptTemplate: config.resolvedMeetingSummaryUserPrompt
        )
        var body: [String: Any] = [
            "model": model,
            "system": instructions,
            "messages": [
                ["role": "user", "content": userPrompt],
            ],
        ]
        applyGenerationSettings(generationSettings, to: &body, maxOutputTokenKey: "max_tokens")

        var request = URLRequest(url: requestURL)
        applyTimeout(from: generationSettings, to: &request)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: backend)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractAnthropicText(from: json),
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw MeetingSummaryError.backendFailed(backend: backend, statusCode: nil, message: message)
                }
                throw MeetingSummaryError.emptyResponse(backend: backend)
            }
            return text
        } catch {
            throw summaryRequestError(backend: backend, error: error)
        }
    }

    private static func extractOpenAIText(from payload: [String: Any]) -> String? {
        if let outputText = payload["output_text"] as? String, !outputText.isEmpty {
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let output = payload["output"] as? [[String: Any]] ?? []
        for item in output where (item["type"] as? String) == "message" {
            let content = item["content"] as? [[String: Any]] ?? []
            for entry in content {
                if let text = entry["text"] as? String, !text.isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data, backend: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = extractErrorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw MeetingSummaryError.backendFailed(
                backend: backend,
                statusCode: httpResponse.statusCode,
                message: String(message.prefix(800))
            )
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = error["code"] as? String, !code.isEmpty {
                return code
            }
            return String(describing: error)
        }

        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }

        if let detail = json["detail"] as? String, !detail.isEmpty {
            return detail
        }

        return nil
    }

    private static func summaryRequestError(backend: String, error: Error) -> Error {
        if error is MeetingSummaryError {
            return error
        }
        if let error = error as? ChatGPTResponsesError {
            switch error {
            case let .backendFailed(statusCode, message):
                return MeetingSummaryError.backendFailed(backend: backend, statusCode: statusCode, message: message)
            }
        }
        return MeetingSummaryError.requestFailed(backend: backend, underlying: error)
    }

    private static func extractOpenRouterText(from payload: [String: Any]) -> String? {
        let choices = payload["choices"] as? [[String: Any]] ?? []
        guard let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        if let content = message["content"] as? String, !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let content = message["content"] as? [[String: Any]] {
            let parts = content.compactMap { entry -> String? in
                guard (entry["type"] as? String) == "text", let text = entry["text"] as? String, !text.isEmpty else {
                    return nil
                }
                return text
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func extractAnthropicText(from payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { entry -> String? in
            guard (entry["type"] as? String) == "text",
                  let text = entry["text"] as? String,
                  !text.isEmpty else {
                return nil
            }
            return text
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolveCustomLLMURL(config: AppConfig, format: CustomLLMFormat) -> URL? {
        let rawURL = config.customLLMURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultURL: String
        let endpointSuffix: String
        switch format {
        case .openAI:
            defaultURL = "http://localhost:8080/v1/chat/completions"
            endpointSuffix = "v1/chat/completions"
        case .anthropic:
            defaultURL = "https://api.anthropic.com/v1/messages"
            endpointSuffix = "v1/messages"
        }
        return resolveEndpointURL(rawURL.isEmpty ? defaultURL : rawURL, endpointSuffix: endpointSuffix)
    }

    static func resolveLMStudioURL(config: AppConfig) -> URL? {
        let rawURL = config.lmStudioURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolveEndpointURL(
            rawURL.isEmpty ? defaultLMStudioBaseURL.absoluteString : rawURL,
            endpointSuffix: "v1/chat/completions"
        )
    }

    private static func resolveEndpointURL(_ rawURL: String, endpointSuffix: String) -> URL? {
        guard var components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }

        let suffixParts = endpointSuffix.split(separator: "/").map(String.init)
        var pathParts = components.path.split(separator: "/").map(String.init)

        if pathParts.isEmpty {
            pathParts = suffixParts
        } else if pathParts.last == suffixParts.first {
            pathParts = Array(pathParts.dropLast()) + suffixParts
        } else if !isCompleteEndpointPath(pathParts, endpointSuffixParts: suffixParts) {
            pathParts.append(contentsOf: suffixParts)
        }

        components.path = "/" + pathParts.joined(separator: "/")
        return components.url
    }

    private static func isCompleteEndpointPath(_ pathParts: [String], endpointSuffixParts suffixParts: [String]) -> Bool {
        if pathParts.suffix(suffixParts.count).elementsEqual(suffixParts) {
            return true
        }
        if suffixParts == ["v1", "chat", "completions"] {
            return pathParts.suffix(2).elementsEqual(["chat", "completions"])
        }
        if suffixParts == ["v1", "messages"] {
            return pathParts.count >= suffixParts.count && pathParts.last == "messages"
        }
        return false
    }

    static func generateTitle(transcript: String, config: AppConfig) async -> String? {
        await generateTitle(transcript: transcript, manualNotes: nil, config: config)
    }

    static func generateTitle(
        transcript: String,
        manualNotes: String?,
        config: AppConfig
    ) async -> String? {
        let backend = (config.meetingSummaryBackend.isEmpty ? MeetingSummaryBackendOption.transcriptOnly.backend : config.meetingSummaryBackend).lowercased()
        if backend == MeetingSummaryBackendOption.transcriptOnly.backend {
            return nil
        }

        let excerpt = titlePrompt(transcript: transcript, manualNotes: manualNotes)

        if backend == MeetingSummaryBackendOption.chatGPT.backend {
            return await generateTitleWithChatGPT(transcript: excerpt, config: config)
        }

        if backend == MeetingSummaryBackendOption.openRouter.backend {
            let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? config.openRouterAPIKey
            guard !apiKey.isEmpty else { return nil }
            let configuredModel = config.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = configuredModel.isEmpty ? defaultOpenRouterModel : configuredModel
            return await callChatCompletions(
                url: openRouterURL,
                apiKey: apiKey,
                model: model,
                systemPrompt: titleInstructions,
                userPrompt: excerpt,
                maxTokens: nil,
                extraHeaders: ["X-OpenRouter-Title": AppIdentity.displayName]
            )
        }

        if backend == MeetingSummaryBackendOption.ollama.backend {
            return await generateTitleWithOllama(transcript: excerpt, config: config)
        }

        if backend == MeetingSummaryBackendOption.lmStudio.backend {
            return await generateTitleWithLMStudio(transcript: excerpt, config: config)
        }

        if backend == MeetingSummaryBackendOption.customLLM.backend {
            return await generateTitleWithCustomLLM(transcript: excerpt, config: config)
        }

        if backend == MeetingSummaryBackendOption.gemmaLocal.backend {
            return await generateTitleWithGemma(transcript: excerpt, config: config)
        }

        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? config.openAIAPIKey
        guard !apiKey.isEmpty else { return nil }
        let model = config.openAIModel.isEmpty ? defaultOpenAIModel : config.openAIModel
        return await callChatCompletions(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiKey: apiKey,
            model: model,
            systemPrompt: titleInstructions,
            userPrompt: excerpt,
            maxTokens: nil,
            extraHeaders: [:]
        )
    }

    static func titlePrompt(transcript: String, manualNotes: String? = nil) -> String {
        let excerpt = titleTranscriptExcerpt(from: transcript)
        let trimmedManualNotes = manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedManualNotes.isEmpty else { return excerpt }

        let transcriptLabel = "Meeting transcript excerpts:\n"
        let notesLabel = "\n\nWritten notes captured by the user during the meeting. Treat these as high-priority context when choosing the main topic and outcome:\n"
        let availableNotesCharacters = max(
            0,
            titlePromptCharacterLimit - transcriptLabel.count - excerpt.count - notesLabel.count
        )
        let boundedManualNotes = String(trimmedManualNotes.prefix(availableNotesCharacters))
        return transcriptLabel + excerpt + notesLabel + boundedManualNotes
    }

    static func titleTranscriptExcerpt(from transcript: String, segmentLength: Int = 900) -> String {
        let normalized = transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, segmentLength > 0 else { return normalized }
        guard normalized.count > segmentLength * 3 else { return normalized }

        let start = String(normalized.prefix(segmentLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        let middleStartOffset = max(0, (normalized.count / 2) - (segmentLength / 2))
        let middleStart = normalized.index(normalized.startIndex, offsetBy: middleStartOffset)
        let middleEnd = normalized.index(middleStart, offsetBy: segmentLength, limitedBy: normalized.endIndex) ?? normalized.endIndex
        let middle = String(normalized[middleStart..<middleEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let end = String(normalized.suffix(segmentLength)).trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        Opening excerpt:
        \(start)

        Middle excerpt:
        \(middle)

        Closing excerpt:
        \(end)
        """
    }

    private static func callChatCompletions(
        url: URL, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String,
        maxTokens: Int?, extraHeaders: [String: String], timeout: TimeInterval? = nil
    ) async -> String? {
        let isOpenAI = url.host?.contains("openai.com") == true
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        if let maxTokens {
            // OpenAI newer models require max_completion_tokens; OpenRouter uses max_tokens
            body[isOpenAI ? "max_completion_tokens" : "max_tokens"] = maxTokens
        }
        if isOpenAI, let effort = SummaryModelPreset.reasoningEffort(for: model) {
            body["reasoning_effort"] = effort
        }

        var request = URLRequest(url: url)
        if let timeout {
            request.timeoutInterval = timeout
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fputs("[summary] title generation: invalid JSON response\n", stderr)
                return nil
            }
            if let error = json["error"] as? [String: Any] {
                fputs("[summary] title generation error: \(error["message"] ?? error)\n", stderr)
                return nil
            }
            // Try chat completions format first, then responses API format
            let result = (extractOpenRouterText(from: json) ?? extractOpenAIText(from: json))?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            if result == nil {
                let choices = json["choices"] as? [[String: Any]] ?? []
                let firstChoice = choices.first ?? [:]
                let message = firstChoice["message"] as? [String: Any] ?? [:]
                fputs("[summary] title generation: nil. message keys: \(message.keys.sorted()), content type: \(type(of: message["content"] as Any)), content: \(String(describing: message["content"]).prefix(300))\n", stderr)
            }
            fputs("[summary] generated title: \(result ?? "(nil)")\n", stderr)
            return result
        } catch {
            fputs("[summary] title generation failed: \(error)\n", stderr)
            return nil
        }
    }

    private static func callAnthropicMessages(
        url: URL,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        timeout: TimeInterval? = nil
    ) async -> String? {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt],
            ],
        ]

        var request = URLRequest(url: url)
        if let timeout {
            request.timeoutInterval = timeout
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "Custom LLM")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fputs("[summary] Anthropic title generation: invalid JSON response\n", stderr)
                return nil
            }
            return extractAnthropicText(from: json)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
        } catch {
            fputs("[summary] Anthropic title generation failed: \(error)\n", stderr)
            return nil
        }
    }

    private static func generateTitleWithChatGPT(transcript: String, config: AppConfig) async -> String? {
        do {
            let model = config.chatGPTModel.isEmpty ? defaultChatGPTModel : config.chatGPTModel
            let result = try await ChatGPTResponsesClient.respond(
                systemPrompt: titleInstructions,
                userPrompt: transcript,
                model: model,
                logCategory: "summary"
            )
            let title = result.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            guard !title.isEmpty else { return nil }
            fputs("[summary] ChatGPT generated title: \(title)\n", stderr)
            return title
        } catch {
            fputs("[summary] ChatGPT title generation failed: \(error)\n", stderr)
            return nil
        }
    }

    private static func generateTitleWithLMStudio(transcript: String, config: AppConfig) async -> String? {
        guard let requestURL = resolveLMStudioURL(config: config) else {
            fputs("[summary] LM Studio title generation: invalid URL \(config.lmStudioURL)\n", stderr)
            return nil
        }
        let model = config.lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            fputs("[summary] LM Studio title generation: no model selected\n", stderr)
            return nil
        }
        return await callChatCompletions(
            url: requestURL,
            apiKey: "",
            model: model,
            systemPrompt: titleInstructions,
            userPrompt: transcript,
            maxTokens: 100,
            extraHeaders: [:],
            timeout: lmStudioTitleTimeout
        )
    }

    private static func generateTitleWithCustomLLM(transcript: String, config: AppConfig) async -> String? {
        let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
        guard let requestURL = resolveCustomLLMURL(config: config, format: format) else { return nil }
        let apiKey = config.customLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredModel = config.customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredModel.isEmpty else {
            fputs("[summary] Custom LLM title generation: no model selected\n", stderr)
            return nil
        }
        if customLLMRequiresAPIKey(config: config) && apiKey.isEmpty {
            fputs("[summary] Custom LLM title generation: no API key configured\n", stderr)
            return nil
        }

        switch format {
        case .openAI:
            return await callChatCompletions(
                url: requestURL,
                apiKey: apiKey,
                model: configuredModel,
                systemPrompt: titleInstructions,
                userPrompt: transcript,
                maxTokens: 100,
                extraHeaders: [:],
                timeout: customLLMTitleTimeout
            )
        case .anthropic:
            return await callAnthropicMessages(
                url: requestURL,
                apiKey: apiKey,
                model: configuredModel,
                systemPrompt: titleInstructions,
                userPrompt: transcript,
                maxTokens: 100,
                timeout: customLLMTitleTimeout
            )
        }
    }

    private static func generateTitleWithGemma(transcript: String, config: AppConfig) async -> String? {
        do {
            let modelID = config.gemmaSummaryModel
            let settings = config.meetingSummaryGenerationSettings(
                backend: .gemmaLocal,
                model: config.resolvedMeetingSummaryModel(for: .gemmaLocal)
            )
            let title = try await GemmaSummaryBackend.shared.summarize(
                systemPrompt: titleInstructions,
                userPrompt: transcript,
                modelID: modelID,
                settings: settings
            )
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            guard !trimmed.isEmpty else {
                fputs("[summary] Gemma title generation: empty response\n", stderr)
                return nil
            }
            fputs("[summary] Gemma generated title: \(trimmed)\n", stderr)
            return trimmed
        } catch {
            fputs("[summary] Gemma title generation failed: \(error)\n", stderr)
            return nil
        }
    }

    private static func generateTitleWithOllama(transcript: String, config: AppConfig) async -> String? {
        let baseURLString = config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL: URL
        if baseURLString.isEmpty {
            baseURL = defaultOllamaBaseURL
        } else {
            guard let url = URL(string: baseURLString) else {
                fputs("[summary] Ollama title generation: invalid URL \(baseURLString)\n", stderr)
                return nil
            }
            baseURL = url
        }
        let chatURL = baseURL.appendingPathComponent("api/chat")
        let configuredModel = config.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty ? defaultOllamaModel : configuredModel

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": titleInstructions],
                ["role": "user", "content": transcript],
            ],
            "options": ["num_predict": 100],
            "stream": false,
        ]
        applyOllamaThinking(false, to: &body)

        var request = URLRequest(url: chatURL)
        request.timeoutInterval = ollamaTitleTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        OllamaAuthorization.apply(configuredToken: config.ollamaAPIKey, to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "Ollama")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.isEmpty else {
                fputs("[summary] Ollama title generation: empty or invalid response\n", stderr)
                return nil
            }
            let title = content.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            guard !title.isEmpty else {
                fputs("[summary] Ollama title generation: trimmed response is empty\n", stderr)
                return nil
            }
            fputs("[summary] Ollama generated title: \(title)\n", stderr)
            return title
        } catch let error as MeetingSummaryError {
            fputs("[summary] Ollama title generation failed: \(error.localizedDescription)\n", stderr)
            return nil
        } catch {
            fputs("[summary] Ollama title generation failed: \(error)\n", stderr)
            return nil
        }
    }

    private static func rawTranscriptFallback(transcript: String, meetingTitle: String) -> String {
        "## Raw Transcript\n\n\(transcript)"
    }
}
