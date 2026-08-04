import Foundation
import MuesliCore

enum MeetingProcessingMetadataFactory {
    static func transcription(
        backend: BackendOption,
        startedAt: Date,
        completedAt: Date = Date()
    ) -> MeetingProcessingRunMetadata {
        MeetingProcessingRunMetadata(
            completedAt: completedAt,
            durationSeconds: completedAt.timeIntervalSince(startedAt),
            backend: backend.backend,
            model: backend.model,
            displayName: backend.label
        )
    }

    static func summary(
        config: AppConfig,
        startedAt: Date,
        completedAt: Date = Date(),
        thinkingStatus: MeetingProcessingThinkingStatus? = nil
    ) -> MeetingProcessingRunMetadata {
        let backend = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        let model = config.resolvedMeetingSummaryModel(for: backend)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingProcessingRunMetadata(
            completedAt: completedAt,
            durationSeconds: completedAt.timeIntervalSince(startedAt),
            backend: backend.backend,
            model: model,
            displayName: model.isEmpty ? backend.label : "\(backend.label) · \(model)",
            thinkingStatus: backend == .ollama ? thinkingStatus : nil
        )
    }
}
