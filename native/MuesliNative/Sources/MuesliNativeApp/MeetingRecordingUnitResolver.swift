import Foundation
import MuesliCore

enum MeetingRecordingUnitResolverError: Error, LocalizedError {
    case unsupportedSourceBundleVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSourceBundleVersion(let version):
            return "This meeting's source audio uses unsupported format version \(version). The playback recording is still available."
        }
    }
}

enum MeetingRecordingUnitResolver {
    static func resolve(
        meetingID: Int64,
        store: DictationStore,
        supportDirectory: URL
    ) throws -> [MeetingRecordingUnitInput] {
        try resolve(
            units: store.meetingRecordingUnits(meetingID: meetingID),
            supportDirectory: supportDirectory
        )
    }

    static func resolve(
        units: [MeetingRecordingUnitRecord],
        supportDirectory: URL
    ) throws -> [MeetingRecordingUnitInput] {
        units.map { unit in
            let playbackURL = URL(fileURLWithPath: unit.recording.path)
            let fallbackInput = playbackFallback(unit, playbackURL: playbackURL)
            guard let sourceBundle = unit.sourceBundle else {
                return fallbackInput
            }
            let supportedVersions = [
                MeetingRecordingBundleManifest.legacySchemaVersion,
                MeetingRecordingBundleManifest.currentSchemaVersion,
            ]
            guard supportedVersions.contains(sourceBundle.schemaVersion) else {
                return playbackFallback(
                    unit,
                    playbackURL: playbackURL,
                    degradation: .sourceBundleVersionUnsupported(
                        sourceBundle.schemaVersion
                    )
                )
            }
            do {
                let bundle = try MeetingRecordingBundle.load(
                    directoryURL: URL(fileURLWithPath: sourceBundle.bundlePath),
                    supportDirectory: supportDirectory
                )
                let sourceInput = MeetingRecordingUnitInput.sourceBundle(MeetingSourceBundleInput(
                    recording: unit.recording,
                    playbackURL: playbackURL,
                    bundle: bundle
                ))

                if bundle.sourceState == .complete {
                    return sourceInput
                }
                if case .separatedChannels = fallbackInput,
                   fallbackInput.hasUsableAudio() {
                    return fallbackInput
                }
                if sourceInput.hasUsableAudio() {
                    return sourceInput
                }
                return fallbackInput
            } catch MeetingRecordingBundleError.unsupportedSchemaVersion(let version) {
                return playbackFallback(
                    unit,
                    playbackURL: playbackURL,
                    degradation: .sourceBundleVersionUnsupported(version)
                )
            } catch {
                return fallbackInput
            }
        }.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.stableOrder < rhs.stableOrder
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private static func playbackFallback(
        _ unit: MeetingRecordingUnitRecord,
        playbackURL: URL
    ) -> MeetingRecordingUnitInput {
        if let sourceLayout = unit.recording.sourceLayout {
            return .separatedChannels(MeetingSeparatedRecordingInput(
                recording: unit.recording,
                recordingURL: playbackURL,
                sourceLayout: sourceLayout
            ))
        }
        return legacyFallback(unit, playbackURL: playbackURL)
    }

    private static func playbackFallback(
        _ unit: MeetingRecordingUnitRecord,
        playbackURL: URL,
        degradation: MeetingProcessingDegradation
    ) -> MeetingRecordingUnitInput {
        if unit.recording.sourceLayout != nil {
            return playbackFallback(unit, playbackURL: playbackURL)
        }
        return legacyFallback(
            unit,
            playbackURL: playbackURL,
            degradation: degradation
        )
    }

    private static func legacyFallback(
        _ unit: MeetingRecordingUnitRecord,
        playbackURL: URL,
        degradation: MeetingProcessingDegradation? = nil
    ) -> MeetingRecordingUnitInput {
        .legacyMixed(MeetingLegacyRecordingInput(
            recording: unit.recording,
            playbackURL: playbackURL,
            degradations: degradation.map { [$0] } ?? []
        ))
    }
}
