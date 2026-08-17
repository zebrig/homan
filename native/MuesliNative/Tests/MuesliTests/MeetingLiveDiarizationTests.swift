import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting Live diarization")
struct MeetingLiveDiarizationTests {
    @Test("a clear dominant remote speaker receives its provisional label")
    func dominantSpeakerWins() {
        let activity = [
            MeetingDiarizationActivitySegment(
                speakerKey: "Speaker 1",
                startSeconds: 10,
                endSeconds: 12
            ),
            MeetingDiarizationActivitySegment(
                speakerKey: "Speaker 2",
                startSeconds: 11.8,
                endSeconds: 12.2
            ),
        ]

        #expect(MeetingLiveSpeakerResolver.label(
            forStart: 10.2,
            end: 11.7,
            activity: activity
        ) == "Speaker 1")
    }

    @Test("ambiguous overlap remains Others")
    func ambiguousOverlapRemainsOthers() {
        let activity = [
            MeetingDiarizationActivitySegment(
                speakerKey: "Speaker 1",
                startSeconds: 3,
                endSeconds: 4
            ),
            MeetingDiarizationActivitySegment(
                speakerKey: "Speaker 2",
                startSeconds: 3,
                endSeconds: 4
            ),
        ]

        #expect(MeetingLiveSpeakerResolver.label(
            forStart: 3,
            end: 4,
            activity: activity
        ) == "Others")
    }

    @Test("missing, invalid, or non-public speaker evidence remains Others")
    func invalidEvidenceRemainsOthers() {
        let internalLabel = [
            MeetingDiarizationActivitySegment(
                speakerKey: "slot-0",
                startSeconds: 0,
                endSeconds: 2
            )
        ]

        #expect(MeetingLiveSpeakerResolver.label(
            forStart: 0,
            end: 1,
            activity: []
        ) == "Others")
        #expect(MeetingLiveSpeakerResolver.label(
            forStart: 1,
            end: 1,
            activity: internalLabel
        ) == "Others")
        #expect(MeetingLiveSpeakerResolver.label(
            forStart: 0,
            end: 1,
            activity: internalLabel
        ) == "Others")
    }

    @Test("only the Sortformer adapter is accepted for Live preparation")
    func livePreparationRequiresSortformerAdapter() {
        #expect(
            MeetingDiarizationProfiles.resolve(.stableFourSpeaker).engineID
                == .sortformerBalanced
        )
        #expect(
            MeetingDiarizationProfiles.resolve(.offlineQuality).engineID
                != .sortformerBalanced
        )
    }

    @Test("Final-only models throw the typed unsupported-Live error")
    func finalOnlyModelRejectedForLive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-live-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MeetingLiveDiarizationEngine(
            assets: MeetingDiarizationAssetStore(rootURL: root)
        )

        do {
            try await engine.prepare(profileID: .offlineQuality)
            Issue.record("expected unsupportedLiveModel")
        } catch let error as MeetingDiarizationAssetError {
            guard case .unsupportedLiveModel(let name) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(name == "Offline quality")
            #expect(
                error.localizedDescription
                    == "This model doesn't support Live speaker diarization: Offline quality."
            )
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
