import Foundation

public enum MeetingFinalDiarizationPolicy: String, Codable, Sendable, Equatable, CaseIterable {
    case followSettings = "follow_settings"
    case enabled
    case disabled
}

public enum MeetingDiarizationProfileID: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case automatic
    case offlineQuality = "offline_quality"
    case stableFourSpeaker = "stable_four_speaker"
}

public struct MeetingDiarizationPreference: Codable, Sendable, Equatable {
    public let meetingID: Int64
    public var finalPolicy: MeetingFinalDiarizationPolicy
    public var preferredProfileID: MeetingDiarizationProfileID?
    public var updatedAt: Date

    public init(
        meetingID: Int64,
        finalPolicy: MeetingFinalDiarizationPolicy = .followSettings,
        preferredProfileID: MeetingDiarizationProfileID? = nil,
        updatedAt: Date = Date()
    ) {
        self.meetingID = meetingID
        self.finalPolicy = finalPolicy
        self.preferredProfileID = preferredProfileID
        self.updatedAt = updatedAt
    }
}

public enum MeetingDiarizationRunMode: Sendable, Equatable {
    case meetingDefault
    case reuseCompatible
    case rerun(MeetingDiarizationProfileID)
    case disabled
}

public struct ResolvedMeetingDiarizationPolicy: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let profileID: MeetingDiarizationProfileID
    /// Open catalog stable ID captured for a new run, when the run was started
    /// by a build with the spec-010 selection model. Nil for legacy runs and
    /// for compatibility-only resolution. Never used to reinterpret evidence.
    public let concreteModelID: String?

    public init(
        enabled: Bool,
        profileID: MeetingDiarizationProfileID,
        concreteModelID: String? = nil
    ) {
        self.enabled = enabled
        self.profileID = profileID
        self.concreteModelID = concreteModelID
    }
}

public enum MeetingDiarizationPolicyResolver {
    public static func resolve(
        globalEnabled: Bool,
        globalProfileID: MeetingDiarizationProfileID,
        preference: MeetingDiarizationPreference?
    ) -> ResolvedMeetingDiarizationPolicy {
        let enabled: Bool
        switch preference?.finalPolicy ?? .followSettings {
        case .followSettings: enabled = globalEnabled
        case .enabled: enabled = true
        case .disabled: enabled = false
        }
        return ResolvedMeetingDiarizationPolicy(
            enabled: enabled,
            profileID: preference?.preferredProfileID ?? globalProfileID,
            concreteModelID: nil
        )
    }

    public static func resolveCaptured(
        enabled: Bool?,
        profileRawValue: String?,
        safeFallbackProfile: MeetingDiarizationProfileID = .automatic
    ) -> ResolvedMeetingDiarizationPolicy {
        let parsed = profileRawValue.flatMap(MeetingDiarizationProfileID.init(rawValue:))
        return ResolvedMeetingDiarizationPolicy(
            enabled: enabled ?? false,
            profileID: parsed ?? safeFallbackProfile,
            concreteModelID: parsed == nil ? profileRawValue : nil
        )
    }
}

public enum MeetingProcessingRunPlan {
    public static func phases(
        operation: MeetingProcessingOperation,
        diarizationMode: MeetingDiarizationRunMode = .disabled,
        resumingAt resumePhase: MeetingProcessingPhase? = nil
    ) -> [MeetingProcessingPhase] {
        let analyzes: Bool
        let appliesLabels: Bool
        switch diarizationMode {
        case .rerun:
            analyzes = true
            appliesLabels = true
        case .reuseCompatible:
            analyzes = false
            appliesLabels = true
        case .meetingDefault:
            analyzes = true
            appliesLabels = true
        case .disabled:
            analyzes = false
            appliesLabels = false
        }

        let fullPlan: [MeetingProcessingPhase]
        switch operation {
        case .finalization, .recovery:
            var result: [MeetingProcessingPhase] = [
                .preparingAudio,
                .processingAudio,
                .preparingRecording,
                .transcribing,
            ]
            if analyzes {
                result += [.preparingDiarizer, .diarizing]
            }
            if appliesLabels {
                result.append(.applyingSpeakerLabels)
            }
            result += [.generatingTitle, .summarizing, .encodingRecording, .saving]
            fullPlan = result
        case .retranscription:
            var result: [MeetingProcessingPhase] = [
                .preparingAudio,
                .processingAudio,
                .transcribing,
            ]
            if analyzes {
                result += [.preparingDiarizer, .diarizing]
            }
            if appliesLabels {
                result.append(.applyingSpeakerLabels)
            }
            result += [.summarizing, .saving]
            fullPlan = result
        case .rediarization:
            fullPlan = [
                .preparingAudio,
                .preparingDiarizer,
                .diarizing,
                .applyingSpeakerLabels,
                .saving,
            ]
        case .resummarization:
            fullPlan = [.summarizing, .saving]
        }
        guard let resumePhase,
              let resumeIndex = fullPlan.firstIndex(of: resumePhase) else {
            return fullPlan
        }
        return Array(fullPlan[resumeIndex...])
    }
}
