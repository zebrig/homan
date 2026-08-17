import Foundation

enum MeetingDiarizationRollbackMode: String, Sendable, Equatable {
    case current
    case legacy
}

/// Internal emergency switch for a staged rollout. It is intentionally not a
/// user-facing quality profile: enabling it replaces the selected Final
/// provider with the cached legacy FluidAudio pipeline exactly once. It never
/// runs a second diarizer and never downloads a model in the processing path.
enum MeetingDiarizationRollbackPolicy {
    static let environmentKey = "HOMAN_MEETING_DIARIZATION_PROVIDER"
    static let defaultsKey = "HomanMeetingDiarizationForceLegacyProvider"

    static func resolve(
        environmentValue: String?,
        storedLegacyOverride: Bool?
    ) -> MeetingDiarizationRollbackMode {
        if let value = environmentValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            switch value {
            case "legacy", "1", "true", "on":
                return .legacy
            case "current", "0", "false", "off":
                return .current
            default:
                break
            }
        }
        return storedLegacyOverride == true ? .legacy : .current
    }

    static func current(
        processInfo: ProcessInfo = .processInfo,
        userDefaults: UserDefaults = .standard
    ) -> MeetingDiarizationRollbackMode {
        resolve(
            environmentValue: processInfo.environment[environmentKey],
            storedLegacyOverride: userDefaults.object(forKey: defaultsKey) as? Bool
        )
    }
}
