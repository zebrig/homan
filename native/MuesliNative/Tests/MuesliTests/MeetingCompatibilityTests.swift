import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting audio compatibility", .serialized)
struct MeetingCompatibilityTests {
    @Test("legacy and single-source recordings coexist without migration or retry-media loss")
    func legacyAndSingleSourceCompatibility() async throws {
        let support = try MeetingRecordingBundleTestSupport(testName: "meeting-compatibility")
        defer { support.cleanup() }
        let store = DictationStore(
            databaseURL: support.supportDirectory.appendingPathComponent("muesli.sqlite")
        )
        try store.migrateIfNeeded()

        let legacyPlayback = try support.makePlaybackFile(named: "legacy.wav")
        let legacyMeetingID = try insertMeeting(
            store: store,
            title: "Legacy",
            playbackPath: legacyPlayback.path,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        let sourceMeetingID = try insertMeeting(
            store: store,
            title: "Microphone only",
            playbackPath: nil,
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        let capture = try MeetingProcessingCapture(
            meetingID: sourceMeetingID,
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 2_000),
            finalModelID: BackendOption.parakeetMultilingual.asrModelID,
            supportDirectory: support.supportDirectory
        )
        capture.appendMicrophone(MeetingAudioTestFixtures.microphoneOnly().microphone)
        let staged = try capture.finalize(
            endedAt: Date(timeIntervalSince1970: 2_010)
        )
        let sourcePlayback = try support.makePlaybackFile(named: "source.wav")
        let bundle = try MeetingRecordingBundlePublisher.publish(
            stagedAudio: staged,
            playbackURL: sourcePlayback,
            supportDirectory: support.supportDirectory
        )
        _ = try store.registerMeetingRecordingWithSourceBundle(
            meetingID: sourceMeetingID,
            playbackPath: sourcePlayback.path,
            createdAt: bundle.manifest.startedAt,
            deleteAfter: nil,
            bundlePath: bundle.directoryURL.path,
            schemaVersion: bundle.manifest.schemaVersion,
            sourceState: bundle.sourceState
        )

        let provider = CompatibilityProvider(results: [
            legacyPlayback.lastPathComponent: "mixed legacy",
            "mic-cleaned.wav": "local source",
        ])
        let legacyResult = try await process(
            meetingID: legacyMeetingID,
            store: store,
            supportDirectory: support.supportDirectory,
            provider: provider
        )
        let sourceResult = try await process(
            meetingID: sourceMeetingID,
            store: store,
            supportDirectory: support.supportDirectory,
            provider: provider
        )

        #expect(legacyResult.attributedTurns.map(\.sourceRole) == [.legacyUnknown])
        #expect(!legacyResult.formattedTranscript.contains("You:"))
        #expect(sourceResult.attributedTurns.map(\.sourceRole) == [.you])
        #expect(sourceResult.degradations.contains(.sourceEmpty(.system)))

        await #expect(throws: Error.self) {
            _ = try await process(
                meetingID: sourceMeetingID,
                store: store,
                supportDirectory: support.supportDirectory,
                provider: CompatibilityProvider(results: [:])
            )
        }

        support.assertExists(legacyPlayback)
        support.assertExists(sourcePlayback)
        support.assertExists(bundle.directoryURL)
        support.assertExists(bundle.microphoneURL!)
    }

    private func insertMeeting(
        store: DictationStore,
        title: String,
        playbackPath: String?,
        startedAt: Date
    ) throws -> Int64 {
        try store.insertMeeting(
            title: title,
            calendarEventID: nil,
            startTime: startedAt,
            endTime: startedAt.addingTimeInterval(10),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: playbackPath
        )
    }

    private func process(
        meetingID: Int64,
        store: DictationStore,
        supportDirectory: URL,
        provider: CompatibilityProvider
    ) async throws -> MeetingTranscriptionResult {
        let units = try MeetingRecordingUnitResolver.resolve(
            meetingID: meetingID,
            store: store,
            supportDirectory: supportDirectory
        )
        return try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: units,
                backend: .whisperSmall,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .disabled
            )
        )
    }
}

private enum CompatibilityTestError: Error {
    case missingResult(String)
}

private struct CompatibilityProvider: MeetingTranscriptionProviding {
    let results: [String: String]

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        guard let text = results[url.lastPathComponent] else {
            throw CompatibilityTestError.missingResult(url.path)
        }
        return SpeechTranscriptionResult(
            text: text,
            segments: [.init(start: 0, end: 1, text: text)]
        )
    }

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]? {
        nil
    }
}
