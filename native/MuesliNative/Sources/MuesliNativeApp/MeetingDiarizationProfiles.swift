import Foundation
import MuesliCore

enum MeetingDiarizationEngineID: String, Sendable {
    case offlineCommunity = "offline-community-vbx"
    case sortformerBalanced = "sortformer-balanced-v2.1"
}

struct MeetingDiarizationProfileDefinition: Sendable, Equatable {
    let requestedID: MeetingDiarizationProfileID
    let effectiveID: MeetingDiarizationProfileID
    let revision: Int
    let engineID: MeetingDiarizationEngineID
    let engineVersion: String
    let modelAssetID: String
    let modelRevision: String
    let configurationDigest: String
    let maximumSpeakers: Int?
    let displayName: String
    let detail: String
    let licenseName: String
    let licenseURL: URL

    func snapshot(modelDigest: String) -> MeetingDiarizationProfileSnapshot {
        MeetingDiarizationProfileSnapshot(
            profileID: requestedID.rawValue,
            profileRevision: revision,
            engineID: engineID.rawValue,
            engineVersion: engineVersion,
            modelRevision: modelRevision,
            modelDigest: modelDigest,
            effectiveConfigurationDigest: configurationDigest,
            maximumSpeakers: maximumSpeakers
        )
    }
}

enum MeetingDiarizationProfiles {
    /// Exact dependency version selected for this profile revision. Bump the
    /// profile revision when this changes so completed evidence remains auditable.
    static let fluidAudioVersion = "0.15.2"
    static let legacyEngineID = "fluidaudio-legacy-pyannote"
    static let legacyModelRevision = "pyannote_segmentation+wespeaker_v2"

    static func resolve(
        _ id: MeetingDiarizationProfileID
    ) -> MeetingDiarizationProfileDefinition {
        switch id {
        case .automatic:
            let effective = offlineQuality
            return MeetingDiarizationProfileDefinition(
                requestedID: .automatic,
                effectiveID: effective.effectiveID,
                revision: effective.revision,
                engineID: effective.engineID,
                engineVersion: effective.engineVersion,
                modelAssetID: effective.modelAssetID,
                modelRevision: effective.modelRevision,
                configurationDigest: effective.configurationDigest,
                maximumSpeakers: effective.maximumSpeakers,
                displayName: "Automatic — Offline quality",
                detail: effective.detail,
                licenseName: effective.licenseName,
                licenseURL: effective.licenseURL
            )
        case .offlineQuality:
            return offlineQuality
        case .stableFourSpeaker:
            return stableFourSpeaker
        }
    }

    /// Concrete models that are validated and can be selected for a new run.
    /// `automatic` is a legacy compatibility alias, not a separately installed
    /// model, so it must never appear beside the concrete asset it resolves to.
    static func installedConcreteProfiles(
        from statuses: [MeetingDiarizationAssetStatus]
    ) -> [MeetingDiarizationProfileID] {
        MeetingDiarizationProfileID.allCases.filter { profile in
            guard profile != .automatic else { return false }
            return statuses.contains {
                $0.profileID == profile && $0.state == .ready
            }
        }
    }

    static let offlineQuality = MeetingDiarizationProfileDefinition(
        requestedID: .offlineQuality,
        effectiveID: .offlineQuality,
        revision: 2,
        engineID: .offlineCommunity,
        engineVersion: fluidAudioVersion,
        modelAssetID: "fluidaudio-community1-vbx",
        modelRevision: "speaker-diarization-offline/community-1-v1",
        configurationDigest: MeetingTranscriptDigest.text(
            "offline-community-v1|OfflineDiarizerConfig.default|system-only|16k"
        ),
        maximumSpeakers: nil,
        displayName: "Offline quality",
        detail: "Best Final quality for an unknown number of remote speakers.",
        licenseName: "FluidAudio and model licenses",
        licenseURL: URL(string: "https://github.com/FluidInference/FluidAudio")!
    )

    static let stableFourSpeaker = MeetingDiarizationProfileDefinition(
        requestedID: .stableFourSpeaker,
        effectiveID: .stableFourSpeaker,
        revision: 2,
        engineID: .sortformerBalanced,
        engineVersion: fluidAudioVersion,
        modelAssetID: "fluidaudio-sortformer-balanced-v2-1",
        modelRevision: "SortformerNvidiaLow_v2.1",
        configurationDigest: MeetingTranscriptDigest.text(
            "sortformer-v2.1|balancedV2_1|fp16|system-only|16k|max4|streaming-final-v1"
        ),
        maximumSpeakers: 4,
        displayName: "Stable up to 4",
        detail: "Low-latency stable identities for meetings with at most four remote speakers.",
        licenseName: "FluidAudio and NVIDIA Sortformer model licenses",
        licenseURL: URL(string: "https://github.com/FluidInference/FluidAudio")!
    )

    static func legacyRollbackSnapshot(
        requestedID: MeetingDiarizationProfileID,
        modelDigest: String,
        runtimePolicy: DiarizerRuntimePolicy
    ) -> MeetingDiarizationProfileSnapshot {
        MeetingDiarizationProfileSnapshot(
            profileID: requestedID.rawValue,
            profileRevision: 1,
            engineID: legacyEngineID,
            engineVersion: fluidAudioVersion,
            modelRevision: legacyModelRevision,
            modelDigest: modelDigest,
            effectiveConfigurationDigest: MeetingTranscriptDigest.text(
                "legacy-diarizer-v1|DiarizerConfig.default|system-only|16k|\(runtimePolicy.compatibilityRule)"
            ),
            maximumSpeakers: nil
        )
    }

    static func isLegacyRollbackSnapshot(
        _ snapshot: MeetingDiarizationProfileSnapshot
    ) -> Bool {
        snapshot.engineID == legacyEngineID
            && snapshot.engineVersion == fluidAudioVersion
            && snapshot.modelRevision == legacyModelRevision
            && !snapshot.modelDigest.isEmpty
    }

    /// Verifies every immutable correctness input that the application owns.
    /// `modelDigest` is the digest captured by the completed run; it must be
    /// present, while a currently installed marker (when available) is checked
    /// separately by `matchesInstalledSnapshot`.
    static func matchesCurrentDefinition(
        _ snapshot: MeetingDiarizationProfileSnapshot,
        requestedID: MeetingDiarizationProfileID
    ) -> Bool {
        let definition = resolve(requestedID)
        let acceptedProfileIDs: Set<String> = [
            requestedID.rawValue,
            definition.effectiveID.rawValue,
        ]
        return acceptedProfileIDs.contains(snapshot.profileID)
            && snapshot.profileRevision == definition.revision
            && snapshot.engineID == definition.engineID.rawValue
            && snapshot.engineVersion == definition.engineVersion
            && snapshot.modelRevision == definition.modelRevision
            && !snapshot.modelDigest.isEmpty
            && snapshot.effectiveConfigurationDigest == definition.configurationDigest
            && snapshot.maximumSpeakers == definition.maximumSpeakers
    }

    /// Matches evidence against the one provider that is actually active for
    /// this process. Legacy rollback is deliberately isolated: its artifacts
    /// are reusable while rollback remains selected, but never masquerade as
    /// evidence from a current shipping profile (or vice versa).
    static func matchesActiveProvider(
        _ snapshot: MeetingDiarizationProfileSnapshot,
        requestedID: MeetingDiarizationProfileID,
        providerMode: MeetingDiarizationRollbackMode = MeetingDiarizationRollbackPolicy.current()
    ) -> Bool {
        switch providerMode {
        case .current:
            return matchesCurrentDefinition(snapshot, requestedID: requestedID)
        case .legacy:
            let definition = resolve(requestedID)
            let acceptedProfileIDs: Set<String> = [
                requestedID.rawValue,
                definition.effectiveID.rawValue,
            ]
            return acceptedProfileIDs.contains(snapshot.profileID)
                && isLegacyRollbackSnapshot(snapshot)
        }
    }

    static func matchesInstalledSnapshot(
        _ snapshot: MeetingDiarizationProfileSnapshot,
        installed: MeetingDiarizationProfileSnapshot
    ) -> Bool {
        snapshot.profileRevision == installed.profileRevision
            && snapshot.engineID == installed.engineID
            && snapshot.engineVersion == installed.engineVersion
            && snapshot.modelRevision == installed.modelRevision
            && snapshot.modelDigest == installed.modelDigest
            && snapshot.effectiveConfigurationDigest
                == installed.effectiveConfigurationDigest
            && snapshot.maximumSpeakers == installed.maximumSpeakers
    }
}
