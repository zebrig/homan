import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting diarization capture compatibility")
struct MeetingDiarizationCaptureCompatibilityTests {

    @Test("new captures persist the concrete stable ID when enabled")
    func capturePersistsConcreteStableID() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try MeetingProcessingCapture(
            meetingID: 1,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finalModelID: .parakeetRealtimeEOU,
            finalDiarizationEnabled: true,
            finalDiarizationProfileID: "homan.diarization.stable-four.v2",
            supportDirectory: root
        )

        let manifest = try readManifest(from: capture)

        #expect(manifest.finalDiarizationEnabled == true)
        #expect(manifest.finalDiarizationProfileID == "homan.diarization.stable-four.v2")
    }

    @Test("disabled captures never record a profile value")
    func disabledCaptureRecordsNoProfile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try MeetingProcessingCapture(
            meetingID: 2,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finalModelID: .parakeetRealtimeEOU,
            finalDiarizationEnabled: false,
            finalDiarizationProfileID: nil,
            supportDirectory: root
        )

        let manifest = try readManifest(from: capture)

        #expect(manifest.finalDiarizationEnabled == false)
        #expect(manifest.finalDiarizationProfileID == nil)
    }

    @Test("captured stable IDs resolve back to their legacy pipeline profile")
    func capturedStableIDMapsToLegacyProfile() {
        let catalog = MeetingDiarizationModelCatalog.loadBundled()

        #expect(
            MeetingDiarizationCompatibility.capturedProfileID(
                profileRawValue: "homan.diarization.stable-four.v2",
                catalog: catalog
            ) == .stableFourSpeaker
        )
        #expect(
            MeetingDiarizationCompatibility.capturedProfileID(
                profileRawValue: "homan.diarization.offline-quality.v2",
                catalog: catalog
            ) == .offlineQuality
        )
        #expect(
            MeetingDiarizationCompatibility.capturedProfileID(
                profileRawValue: "stable_four_speaker",
                catalog: catalog
            ) == .stableFourSpeaker
        )
    }

    @Test("unknown future stable IDs fail safe without rewriting evidence")
    func unknownFutureIDFallsBackSafely() {
        let catalog = MeetingDiarizationModelCatalog.loadBundled()

        let profile = MeetingDiarizationCompatibility.capturedProfileID(
            profileRawValue: "future.unknown.model.v9",
            catalog: catalog
        )
        #expect(profile == .automatic)

        let policy = MeetingDiarizationPolicyResolver.resolveCaptured(
            enabled: true,
            profileRawValue: "future.unknown.model.v9",
            safeFallbackProfile: profile
        )
        #expect(policy.enabled)
        #expect(policy.profileID == .automatic)
        #expect(policy.concreteModelID == "future.unknown.model.v9")
    }

    @Test("legacy captured values keep concreteModelID nil")
    func legacyCapturedValueKeepsConcreteNil() {
        let policy = MeetingDiarizationPolicyResolver.resolveCaptured(
            enabled: true,
            profileRawValue: MeetingDiarizationProfileID.offlineQuality.rawValue
        )

        #expect(policy.profileID == .offlineQuality)
        #expect(policy.concreteModelID == nil)
    }

    @Test("captured policy resolver never crashes on nil manifest value")
    func nilCapturedValueFallsBack() {
        let policy = MeetingDiarizationPolicyResolver.resolveCaptured(
            enabled: nil,
            profileRawValue: nil
        )

        #expect(!policy.enabled)
        #expect(policy.profileID == .automatic)
        #expect(policy.concreteModelID == nil)
    }

    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-capture-compat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func readManifest(
        from capture: MeetingProcessingCapture
    ) throws -> MeetingProcessingManifest {
        let data = try Data(contentsOf: capture.manifestURL)
        return try JSONDecoder().decode(MeetingProcessingManifest.self, from: data)
    }
}
