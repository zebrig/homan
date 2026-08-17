import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// Milestone A (spec 010): characterization of today's shipping behavior.
///
/// These tests document the exact semantics the open catalog and pure
/// selection resolver must preserve while replacing the user-facing
/// Automatic/profile selection. They must keep passing unchanged through the
/// migration; they are the regression net for the whole feature.
@Suite("Meeting diarization selection characterization")
struct MeetingDiarizationSelectionCharacterizationTests {

    // MARK: T001 — `.automatic` resolves to Offline quality

    @Test("global .automatic resolves through the Offline quality definition")
    func automaticResolvesToOfflineQuality() {
        let definition = MeetingDiarizationProfiles.resolve(.automatic)
        #expect(definition.effectiveID == .offlineQuality)
        #expect(definition.engineID == MeetingDiarizationEngineID.offlineCommunity)
        #expect(definition.maximumSpeakers == nil)

        let resolved = MeetingDiarizationPolicyResolver.resolve(
            globalEnabled: true,
            globalProfileID: .automatic,
            preference: nil
        )
        #expect(resolved.enabled)
        #expect(resolved.profileID == .automatic)
    }

    @Test("historical evidence requested as Automatic validates as Offline quality")
    func automaticEvidenceValidatesAsOfflineQuality() {
        let definition = MeetingDiarizationProfiles.resolve(.automatic)
        let snapshot = definition.snapshot(
            modelDigest: "a" + String(repeating: "b", count: 63)
        )

        #expect(MeetingDiarizationProfiles.matchesCurrentDefinition(
            snapshot,
            requestedID: .automatic
        ))
        #expect(!MeetingDiarizationProfiles.matchesCurrentDefinition(
            snapshot,
            requestedID: .offlineQuality
        ))
    }

    // MARK: T002 — Live is hard-coded; Final/Live defaults are independent

    @Test("Live diarization state defaults to Stable up to 4")
    func liveDiarizationDefaultsToStableFour() {
        #expect(MeetingLiveDiarizationRuntimeState.off().profileID == .stableFourSpeaker)
    }

    @Test("Final and Live diarization defaults are independent")
    func finalAndLiveDefaultsAreIndependent() {
        var config = AppConfig()
        #expect(!config.meetingFinalDiarizationEnabledByDefault)
        #expect(!config.meetingLiveDiarizationEnabledByDefault)

        config.meetingFinalDiarizationEnabledByDefault = true
        #expect(!config.meetingLiveDiarizationEnabledByDefault)

        config.meetingLiveDiarizationEnabledByDefault = true
        #expect(config.meetingFinalDiarizationEnabledByDefault)
        #expect(config.meetingLiveDiarizationEnabledByDefault)
    }

    @Test("legacy Final profile defaults to Automatic and unknown IDs fall back safely")
    func legacyFinalProfileFallsBackToAutomatic() throws {
        let config = AppConfig()
        #expect(config.meetingFinalDiarizationProfile == MeetingDiarizationProfileID.automatic.rawValue)
        #expect(config.resolvedMeetingFinalDiarizationProfile == .automatic)

        let json = #"{"meeting_final_diarization_profile":"future_unknown_id"}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.resolvedMeetingFinalDiarizationProfile == .automatic)
    }

    // MARK: T003 — asset-state fixtures for zero/one/many resolver tests

    @Test("asset fixtures cover absent, installing, failed, and ready states")
    func assetFixturesCoverResolverStates() {
        #expect(MeetingDiarizationAssetFixtures.empty.isEmpty)
        #expect(MeetingDiarizationAssetFixtures.onlyOfflineReady.map(\.profileID) == [.offlineQuality])
        #expect(MeetingDiarizationAssetFixtures.onlyStableReady.map(\.profileID) == [.stableFourSpeaker])
        #expect(
            MeetingDiarizationAssetFixtures.bothReady
                .map(\.profileID)
                .sorted { $0.rawValue < $1.rawValue } == [.offlineQuality, .stableFourSpeaker]
        )
        #expect(MeetingDiarizationAssetFixtures.installingOffline.first?.state == .installing)
        #expect(MeetingDiarizationAssetFixtures.failedStable.first?.state == .failed)
    }

    // MARK: T004 — onboarding schema and permission-resume characterization

    @Test("onboarding schema 1 payload decodes with current defaults")
    func onboardingSchema1Decodes() throws {
        let json = """
        {
          "currentStep": 2,
          "userName": "Legacy",
          "selectedBackendKey": "fluidaudio",
          "selectedModelKey": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
          "hotkeyKeyCode": 55,
          "hotkeyLabel": "Left Cmd"
        }
        """

        let progress = try JSONDecoder().decode(
            OnboardingProgress.self,
            from: Data(json.utf8)
        )

        #expect(progress.schemaVersion == 1)
        #expect(progress.onboardingUseCaseRawValue == OnboardingUseCase.dictation.rawValue)
        #expect(!progress.systemAudioRequested)
        #expect(progress.modelDownloadProgress == nil)
    }

    @Test("onboarding schema 4 payload preserves current fields")
    func onboardingSchema4Decodes() throws {
        let json = """
        {
          "schemaVersion": 4,
          "currentStep": 6,
          "userName": "Current",
          "selectedBackendKey": "fluidaudio",
          "selectedModelKey": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
          "hotkeyKeyCode": 55,
          "hotkeyLabel": "Left Cmd",
          "systemAudioRequested": true,
          "onboardingUseCaseRawValue": "dictation_and_meetings",
          "modelDownloadProgress": 0.5,
          "modelDownloadStatus": "50%"
        }
        """

        let progress = try JSONDecoder().decode(
            OnboardingProgress.self,
            from: Data(json.utf8)
        )

        #expect(progress.schemaVersion == 4)
        #expect(progress.onboardingUseCaseRawValue == OnboardingUseCase.dictationAndMeetings.rawValue)
        #expect(progress.systemAudioRequested)
        #expect(progress.modelDownloadProgress == 0.5)
        #expect(progress.modelDownloadStatus == "50%")
    }

    @Test("permission repair resumes at the permissions step for every use case")
    func permissionRepairResumesAtPermissionsStep() {
        let missing = OnboardingPermissionSnapshot(
            microphone: false,
            accessibility: false,
            inputMonitoring: false,
            systemAudio: false,
            screenRecording: false
        )

        for useCase in [OnboardingUseCase.dictation, .voiceNotes, .meetings, .dictationAndMeetings] {
            let step = OnboardingPermissionGate.resumeStep(
                requestedStep: 5,
                permissions: missing,
                useCase: useCase,
                permissionsStep: 3,
                dictationTestStep: 4
            )
            #expect(step == 3)
        }
    }
}

/// Deterministic asset-status fixtures used by characterization and later by
/// the pure selection resolver tests. `ready` fixtures carry a valid digest so
/// resolver rules can be exercised without touching the asset store.
enum MeetingDiarizationAssetFixtures {
    static let empty: [MeetingDiarizationAssetStatus] = []

    static let onlyOfflineReady = [status(profileID: .offlineQuality, state: .ready)]
    static let onlyStableReady = [status(profileID: .stableFourSpeaker, state: .ready)]
    static let bothReady = [
        status(profileID: .offlineQuality, state: .ready),
        status(profileID: .stableFourSpeaker, state: .ready),
    ]
    static let installingOffline = [status(profileID: .offlineQuality, state: .installing)]
    static let failedStable = [status(profileID: .stableFourSpeaker, state: .failed)]

    static func status(
        profileID: MeetingDiarizationProfileID,
        state: MeetingDiarizationAssetState
    ) -> MeetingDiarizationAssetStatus {
        MeetingDiarizationAssetStatus(
            assetID: "fixture-\(profileID.rawValue)",
            profileID: profileID,
            profileRevision: 2,
            modelRevision: "fixture-model",
            modelDigest: state == .ready ? "a" + String(repeating: "b", count: 63) : nil,
            sizeBytes: state == .ready ? 1024 : 0,
            state: state,
            installedAt: state == .ready ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
            lastErrorCategory: state == .failed ? "fixture_error" : nil,
            licenseName: "Fixture license",
            licenseURL: URL(string: "https://example.com/license")!
        )
    }
}
