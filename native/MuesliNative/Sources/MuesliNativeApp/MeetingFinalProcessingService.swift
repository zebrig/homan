import Foundation
import FluidAudio
import MuesliCore

enum MeetingFinalProcessingError: Error, LocalizedError {
    case finalModelUnavailable(String)
    case noCapturedAudio

    var errorDescription: String? {
        switch self {
        case .finalModelUnavailable(let label):
            return "The saved Final transcript model is not ready: \(label). Configure its credentials or download it, then retry."
        case .noCapturedAudio:
            return "The recovery session does not contain readable microphone or system audio."
        }
    }
}

struct RecoveredMeetingProcessingResult: Sendable {
    let title: String
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let formattedNotes: String
    let templateSnapshot: MeetingTemplateSnapshot
    let stagedAudio: MeetingStagedAudio
    let processingMetadata: MeetingProcessingMetadata
}

enum MeetingFinalProcessingService {
    private struct CachedResult: Codable {
        let sessionID: UUID
        let title: String
        let startTime: Date
        let endTime: Date
        let durationSeconds: Double
        let rawTranscript: String
        let formattedNotes: String
        let templateSnapshot: MeetingTemplateSnapshot
        let transcriptionMetadata: MeetingProcessingRunMetadata?
        let summaryMetadata: MeetingProcessingRunMetadata?
    }

    static func process(
        stagedAudio originalStagedAudio: MeetingStagedAudio,
        meeting: MeetingRecord,
        config: AppConfig,
        templateSnapshot: MeetingTemplateSnapshot,
        coordinator: TranscriptionCoordinator,
        progress: @Sendable (MeetingProcessingPhase) -> Void = { _ in }
    ) async throws -> RecoveredMeetingProcessingResult {
        var stagedAudio = try MeetingProcessingCapture.markProcessing(originalStagedAudio)
        if let cached = try loadCachedResult(for: stagedAudio),
           cached.sessionID == stagedAudio.manifest.sessionID {
            stagedAudio = try MeetingProcessingCapture.markState(.committing, for: stagedAudio)
            return RecoveredMeetingProcessingResult(
                title: cached.title,
                startTime: cached.startTime,
                endTime: cached.endTime,
                durationSeconds: cached.durationSeconds,
                rawTranscript: cached.rawTranscript,
                formattedNotes: cached.formattedNotes,
                templateSnapshot: cached.templateSnapshot,
                stagedAudio: stagedAudio,
                processingMetadata: MeetingProcessingMetadata(
                    transcription: cached.transcriptionMetadata,
                    summary: cached.summaryMetadata,
                    manualNotesUpdatedAt: meeting.processingMetadata.manualNotesUpdatedAt
                )
            )
        }
        let modelID = stagedAudio.manifest.finalModelID
        guard let backend = BackendOption.resolve(
            backend: modelID.backend,
            model: modelID.model
        ), backend.supportsMeetingTranscription,
           (backend.capabilitiesExecutionLocation == .cloud
                ? !config.homanWhisperAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : backend.isDownloaded) else {
            let label = MeetingASRModelCatalog.resolve(id: modelID)?.label
                ?? "\(modelID.backend)/\(modelID.model)"
            throw MeetingFinalProcessingError.finalModelUnavailable(label)
        }
        guard stagedAudio.manifest.microphoneSampleCount > 0
                || stagedAudio.manifest.systemSampleCount > 0 else {
            throw MeetingFinalProcessingError.noCapturedAudio
        }

        if backend.backend == BackendOption.nemotron35Multilingual.backend {
            let language = Nemotron35Language.resolved(
                stagedAudio.manifest.nemotron35Language
                    ?? config.nemotron35Language
            )
            await coordinator.setNemotron35PromptId(language.promptId)
        }
        progress(.transcribing)
        let transcriptionStartedAt = Date()
        if backend.backend == BackendOption.homanWhisper.backend {
            try await coordinator.configureHomanWhisper(
                endpointString: config.homanWhisperEndpoint,
                apiKey: config.homanWhisperAPIKey
            )
        }
        try await coordinator.preloadRequired(
            backend: backend,
            enablePostProcessor: false,
            includeMeetingHelpers: backend.backend == BackendOption.homanWhisper.backend
        )

        let transcription = try await MeetingTranscriptionPipeline(
            coordinator: coordinator
        ).process(
            stagedAudio: stagedAudio,
            backend: backend,
            languages: MeetingLanguageSnapshot(
                cohereLanguage: stagedAudio.manifest.cohereLanguage
                    ?? config.cohereLanguage,
                indicASRLanguage: stagedAudio.manifest.indicASRLanguage
                    ?? config.indicASRLanguage,
                nemotron35Language: stagedAudio.manifest.nemotron35Language
                    ?? config.nemotron35Language
            ),
            purpose: .recovery,
            systemDiarization: .optionalPost
        )
        let transcriptionMetadata = MeetingProcessingMetadataFactory.transcription(
            backend: backend,
            startedAt: transcriptionStartedAt
        )
        stagedAudio = try MeetingProcessingCapture.markState(.diarizing, for: stagedAudio)
        let currentSessionTranscript = transcription.formattedTranscript
        let priorTranscript = meeting.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedTranscript = MeetingResumePolicy.combinedResumeTranscript(
            prior: priorTranscript,
            new: currentSessionTranscript
        )

        progress(.generatingTitle)
        let title = await resolvedTitle(
            meeting: meeting,
            transcript: combinedTranscript,
            config: config
        )
        stagedAudio = try MeetingProcessingCapture.markState(.summarizing, for: stagedAudio)
        progress(.summarizing)
        let formattedNotes: String
        var summaryMetadata: MeetingProcessingRunMetadata?
        if !MeetingResumePolicy.hasNewTranscriptContent(
            prior: priorTranscript,
            new: currentSessionTranscript
        ), !meeting.formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            formattedNotes = meeting.formattedNotes
            summaryMetadata = meeting.processingMetadata.summary
        } else {
            let summaryStartedAt = Date()
            do {
                let summaryResult = try await MeetingSummaryClient.summarizeWithMetadata(
                    transcript: combinedTranscript,
                    meetingTitle: title,
                    config: config,
                    template: templateSnapshot,
                    manualNotesToRetain: meeting.manualNotes,
                    visualContext: nil
                )
                formattedNotes = summaryResult.notes
                summaryMetadata = MeetingProcessingMetadataFactory.summary(
                    config: config,
                    startedAt: summaryStartedAt,
                    thinkingStatus: summaryResult.thinkingStatus
                )
            } catch {
                formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                    transcript: combinedTranscript,
                    meetingTitle: title,
                    error: error,
                    manualNotes: meeting.manualNotes
                )
            }
        }

        let sessionEnd = stagedAudio.manifest.endedAt ?? Date()
        let sessionDuration = max(
            sourceDuration(max(
                stagedAudio.manifest.microphoneSampleCount,
                stagedAudio.manifest.systemSampleCount
            )),
            0
        )
        let isResume = !priorTranscript.isEmpty
        let originalStart = ISO8601DateFormatter().date(from: meeting.startTime)
        let startTime = isResume
            ? (originalStart ?? stagedAudio.manifest.startedAt)
            : stagedAudio.manifest.startedAt
        let duration = isResume
            ? meeting.durationSeconds + sessionDuration
            : sessionDuration

        let cachedResult = CachedResult(
            sessionID: stagedAudio.manifest.sessionID,
            title: title,
            startTime: startTime,
            endTime: sessionEnd,
            durationSeconds: duration,
            rawTranscript: combinedTranscript,
            formattedNotes: formattedNotes,
            templateSnapshot: templateSnapshot,
            transcriptionMetadata: transcriptionMetadata,
            summaryMetadata: summaryMetadata
        )
        try saveCachedResult(cachedResult, for: stagedAudio)
        stagedAudio = try MeetingProcessingCapture.markState(.committing, for: stagedAudio)
        return RecoveredMeetingProcessingResult(
            title: cachedResult.title,
            startTime: cachedResult.startTime,
            endTime: cachedResult.endTime,
            durationSeconds: cachedResult.durationSeconds,
            rawTranscript: cachedResult.rawTranscript,
            formattedNotes: cachedResult.formattedNotes,
            templateSnapshot: cachedResult.templateSnapshot,
            stagedAudio: stagedAudio,
            processingMetadata: MeetingProcessingMetadata(
                transcription: cachedResult.transcriptionMetadata,
                summary: cachedResult.summaryMetadata,
                manualNotesUpdatedAt: meeting.processingMetadata.manualNotesUpdatedAt
            )
        )
    }

    private static func sourceDuration(_ sampleCount: Int) -> TimeInterval {
        Double(sampleCount) / Double(MeetingProcessingCapture.sampleRate)
    }

    private static func resolvedTitle(
        meeting: MeetingRecord,
        transcript: String,
        config: AppConfig
    ) async -> String {
        let current = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, current.caseInsensitiveCompare("Meeting") != .orderedSame {
            return current
        }
        if let generated = await MeetingSummaryClient.generateTitle(
            transcript: transcript,
            manualNotes: meeting.manualNotes,
            config: config
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !generated.isEmpty {
            return generated
        }
        return current.isEmpty ? "Meeting" : current
    }

    private static func cachedResultURL(for stagedAudio: MeetingStagedAudio) -> URL {
        stagedAudio.directoryURL.appendingPathComponent("final-result.json")
    }

    private static func loadCachedResult(
        for stagedAudio: MeetingStagedAudio
    ) throws -> CachedResult? {
        let url = cachedResultURL(for: stagedAudio)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CachedResult.self, from: Data(contentsOf: url))
    }

    private static func saveCachedResult(
        _ result: CachedResult,
        for stagedAudio: MeetingStagedAudio
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = cachedResultURL(for: stagedAudio)
        try encoder.encode(result).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
