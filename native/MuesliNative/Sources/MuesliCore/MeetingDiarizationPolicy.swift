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

    public init(enabled: Bool, profileID: MeetingDiarizationProfileID) {
        self.enabled = enabled
        self.profileID = profileID
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
            profileID: preference?.preferredProfileID ?? globalProfileID
        )
    }

    public static func resolveCaptured(
        enabled: Bool?,
        profileRawValue: String?,
        safeFallbackProfile: MeetingDiarizationProfileID = .automatic
    ) -> ResolvedMeetingDiarizationPolicy {
        ResolvedMeetingDiarizationPolicy(
            enabled: enabled ?? false,
            profileID: profileRawValue.flatMap(MeetingDiarizationProfileID.init(rawValue:))
                ?? safeFallbackProfile
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
            var result: [MeetingProcessingPhase] = [.preparingAudio, .transcribing]
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
