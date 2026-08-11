import Foundation

public enum MeetingProcessingPhase: String, Codable, CaseIterable, Sendable, Equatable {
    case preparingAudio = "preparing_audio"
    case preparingRecording = "preparing_recording"
    case transcribing
    case generatingTitle = "generating_title"
    case summarizing
    case encodingRecording = "encoding_recording"
    case saving

    public var displayLabel: String {
        switch self {
        case .preparingAudio: return "Preparing audio"
        case .preparingRecording: return "Preparing recording"
        case .transcribing: return "Transcribing"
        case .generatingTitle: return "Generating title"
        case .summarizing: return "Summarizing"
        case .encodingRecording: return "Encoding recording"
        case .saving: return "Saving"
        }
    }
}

public enum MeetingProcessingOperation: String, Codable, CaseIterable, Sendable, Equatable {
    case finalization
    case recovery
    case retranscription
    case resummarization

    public var displayLabel: String {
        switch self {
        case .finalization: return "Final processing"
        case .recovery: return "Recovery"
        case .retranscription: return "Re-transcribing"
        case .resummarization: return "Re-summarizing"
        }
    }

    public var phases: [MeetingProcessingPhase] {
        switch self {
        case .finalization, .recovery:
            return [
                .preparingAudio,
                .preparingRecording,
                .transcribing,
                .generatingTitle,
                .summarizing,
                .encodingRecording,
                .saving,
            ]
        case .retranscription:
            return [.preparingAudio, .transcribing, .summarizing, .saving]
        case .resummarization:
            return [.summarizing, .saving]
        }
    }
}

public struct MeetingProcessingProgress: Codable, Sendable, Equatable {
    public let runID: UUID
    public let operation: MeetingProcessingOperation
    public let phaseIndex: Int
    public let phaseCount: Int
    public let phase: MeetingProcessingPhase
    public let phaseStartedAt: Date
    public let totalStartedAt: Date

    public var phaseLabel: String { phase.displayLabel }

    public init(
        runID: UUID,
        operation: MeetingProcessingOperation,
        phaseIndex: Int,
        phaseCount: Int,
        phase: MeetingProcessingPhase,
        phaseStartedAt: Date,
        totalStartedAt: Date
    ) {
        self.runID = runID
        self.operation = operation
        self.phaseIndex = phaseIndex
        self.phaseCount = phaseCount
        self.phase = phase
        self.phaseStartedAt = phaseStartedAt
        self.totalStartedAt = totalStartedAt
    }

    public static func starting(
        operation: MeetingProcessingOperation,
        runID: UUID = UUID(),
        now: Date = Date()
    ) -> MeetingProcessingProgress {
        let phases = operation.phases
        precondition(!phases.isEmpty)
        return MeetingProcessingProgress(
            runID: runID,
            operation: operation,
            phaseIndex: 1,
            phaseCount: phases.count,
            phase: phases[0],
            phaseStartedAt: now,
            totalStartedAt: now
        )
    }

    /// Returns nil for a phase outside this operation or for an out-of-order transition.
    /// Repeating the current phase preserves its original timer.
    public func advancing(
        to nextPhase: MeetingProcessingPhase,
        now: Date = Date()
    ) -> MeetingProcessingProgress? {
        guard let zeroBasedIndex = operation.phases.firstIndex(of: nextPhase) else { return nil }
        let nextIndex = zeroBasedIndex + 1
        guard nextIndex >= phaseIndex else { return nil }
        return MeetingProcessingProgress(
            runID: runID,
            operation: operation,
            phaseIndex: nextIndex,
            phaseCount: operation.phases.count,
            phase: nextPhase,
            phaseStartedAt: nextIndex == phaseIndex ? phaseStartedAt : now,
            totalStartedAt: totalStartedAt
        )
    }
}

