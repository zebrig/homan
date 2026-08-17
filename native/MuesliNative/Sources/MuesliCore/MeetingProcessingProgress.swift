import Foundation

public enum MeetingProcessingPhase: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case preparingAudio = "preparing_audio"
    case preparingRecording = "preparing_recording"
    case transcribing
    case preparingDiarizer = "preparing_diarizer"
    case diarizing
    case applyingSpeakerLabels = "applying_speaker_labels"
    case generatingTitle = "generating_title"
    case summarizing
    case encodingRecording = "encoding_recording"
    case saving

    public var displayLabel: String {
        switch self {
        case .preparingAudio: return "Preparing audio"
        case .preparingRecording: return "Preparing recording"
        case .transcribing: return "Transcribing"
        case .preparingDiarizer: return "Preparing speaker model"
        case .diarizing: return "Analyzing speakers"
        case .applyingSpeakerLabels: return "Applying speaker labels"
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
    case rediarization
    case resummarization

    public var displayLabel: String {
        switch self {
        case .finalization: return "Final processing"
        case .recovery: return "Recovery"
        case .retranscription: return "Re-transcribing"
        case .rediarization: return "Analyzing speakers again"
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
        case .rediarization:
            return [.preparingAudio, .preparingDiarizer, .diarizing, .applyingSpeakerLabels, .saving]
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
    /// Immutable effective plan for this run. Optional stages such as local
    /// speaker analysis are captured here instead of being inferred from the
    /// operation name by every UI surface.
    public let phases: [MeetingProcessingPhase]
    public let phaseStartedAt: Date
    public let totalStartedAt: Date

    public var phaseLabel: String { phase.displayLabel }

    private enum CodingKeys: String, CodingKey {
        case runID
        case operation
        case phaseIndex
        case phaseCount
        case phase
        case phases
        case phaseStartedAt
        case totalStartedAt
    }

    public init(
        runID: UUID,
        operation: MeetingProcessingOperation,
        phaseIndex: Int,
        phaseCount: Int,
        phase: MeetingProcessingPhase,
        phases: [MeetingProcessingPhase]? = nil,
        phaseStartedAt: Date,
        totalStartedAt: Date
    ) {
        self.runID = runID
        self.operation = operation
        self.phaseIndex = phaseIndex
        let resolvedPhases = Self.validatedPlan(
            phases,
            operation: operation,
            currentPhase: phase,
            legacyPhaseCount: phaseCount
        )
        self.phaseCount = resolvedPhases.count
        self.phase = phase
        self.phases = resolvedPhases
        self.phaseStartedAt = phaseStartedAt
        self.totalStartedAt = totalStartedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            runID: try container.decode(UUID.self, forKey: .runID),
            operation: try container.decode(MeetingProcessingOperation.self, forKey: .operation),
            phaseIndex: try container.decode(Int.self, forKey: .phaseIndex),
            phaseCount: try container.decode(Int.self, forKey: .phaseCount),
            phase: try container.decode(MeetingProcessingPhase.self, forKey: .phase),
            phases: try container.decodeIfPresent([MeetingProcessingPhase].self, forKey: .phases),
            phaseStartedAt: try container.decode(Date.self, forKey: .phaseStartedAt),
            totalStartedAt: try container.decode(Date.self, forKey: .totalStartedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(operation, forKey: .operation)
        try container.encode(phaseIndex, forKey: .phaseIndex)
        try container.encode(phaseCount, forKey: .phaseCount)
        try container.encode(phase, forKey: .phase)
        try container.encode(phases, forKey: .phases)
        try container.encode(phaseStartedAt, forKey: .phaseStartedAt)
        try container.encode(totalStartedAt, forKey: .totalStartedAt)
    }

    public static func starting(
        operation: MeetingProcessingOperation,
        phases requestedPhases: [MeetingProcessingPhase]? = nil,
        runID: UUID = UUID(),
        now: Date = Date()
    ) -> MeetingProcessingProgress {
        let phases = validatedPlan(
            requestedPhases,
            operation: operation,
            currentPhase: requestedPhases?.first ?? operation.phases[0],
            legacyPhaseCount: requestedPhases?.count ?? operation.phases.count
        )
        precondition(!phases.isEmpty)
        return MeetingProcessingProgress(
            runID: runID,
            operation: operation,
            phaseIndex: 1,
            phaseCount: phases.count,
            phase: phases[0],
            phases: phases,
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
        guard let zeroBasedIndex = phases.firstIndex(of: nextPhase) else { return nil }
        let nextIndex = zeroBasedIndex + 1
        guard nextIndex >= phaseIndex else { return nil }
        return MeetingProcessingProgress(
            runID: runID,
            operation: operation,
            phaseIndex: nextIndex,
            phaseCount: phases.count,
            phase: nextPhase,
            phases: phases,
            phaseStartedAt: nextIndex == phaseIndex ? phaseStartedAt : now,
            totalStartedAt: totalStartedAt
        )
    }

    private static func validatedPlan(
        _ requested: [MeetingProcessingPhase]?,
        operation: MeetingProcessingOperation,
        currentPhase: MeetingProcessingPhase,
        legacyPhaseCount: Int
    ) -> [MeetingProcessingPhase] {
        let candidate = requested?.isEmpty == false ? requested! : operation.phases
        var seen: Set<MeetingProcessingPhase> = []
        let unique = candidate.filter { seen.insert($0).inserted }
        if unique.contains(currentPhase), !unique.isEmpty {
            return unique
        }
        // A progress row from an older build may contain only its current
        // phase/count. Prefer the known operation plan, but never drop the
        // persisted phase if a future/partially migrated row reaches us.
        if operation.phases.contains(currentPhase) {
            return operation.phases
        }
        return [currentPhase] + Array(
            repeating: .saving,
            count: max(0, legacyPhaseCount - 1)
        )
    }
}
