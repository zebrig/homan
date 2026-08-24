import Foundation
import MuesliCore

enum MeetingProcessingMetadataFactory {
    static func transcription(
        backend: BackendOption,
        startedAt: Date,
        completedAt: Date = Date(),
        audioSource: String? = nil,
        aecModel: String? = nil,
        aecDiagnostics: [MeetingAecDiagnosticsSnapshot] = []
    ) -> MeetingProcessingRunMetadata {
        MeetingProcessingRunMetadata(
            completedAt: completedAt,
            durationSeconds: completedAt.timeIntervalSince(startedAt),
            backend: backend.backend,
            model: backend.model,
            displayName: backend.label,
            audioSource: audioSource,
            aecModel: aecModel,
            aecDiagnostics: aggregateAEC(aecDiagnostics)
        )
    }

    private static func aggregateAEC(
        _ snapshots: [MeetingAecDiagnosticsSnapshot]
    ) -> MeetingAecRunDiagnostics? {
        guard !snapshots.isEmpty else { return nil }
        let processors = Set(snapshots.map(\.processor)).sorted()
        let appliedUnitCount = snapshots.count { snapshot in
            snapshot.ready
                && snapshot.processedFrames > 0
                && snapshot.fullReferenceFrames + snapshot.partialReferenceFrames > 0
                && snapshot.lastProcessingError == nil
        }
        return MeetingAecRunDiagnostics(
            processor: processors.joined(separator: "+"),
            ready: snapshots.allSatisfy(\.ready),
            processedFrames: snapshots.reduce(0) { $0 + $1.processedFrames },
            fullReferenceFrames: snapshots.reduce(0) { $0 + $1.fullReferenceFrames },
            partialReferenceFrames: snapshots.reduce(0) { $0 + $1.partialReferenceFrames },
            missingReferenceFrames: snapshots.reduce(0) { $0 + $1.missingReferenceFrames },
            sourceUnitCount: snapshots.count,
            appliedSourceUnitCount: appliedUnitCount,
            processingError: snapshots.contains { $0.lastProcessingError != nil }
                ? "processing_failed"
                : nil
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
