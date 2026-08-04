import FluidAudio
import Foundation
import MuesliCore
import os
import Testing
@testable import MuesliNativeApp

@Suite("Meeting re-transcription", .serialized)
struct MeetingRetranscriptionTests {
    @Test("one retained two-channel file re-transcribes microphone and system independently")
    func separatedFileRetranscriptionPreservesRoles() async throws {
        let support = try MeetingRecordingBundleTestSupport(
            testName: "separated-retranscription"
        )
        defer { support.cleanup() }
        let databaseURL = support.supportDirectory.appendingPathComponent("muesli.sqlite")
        let store = DictationStore(databaseURL: databaseURL)
        try store.migrateIfNeeded()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let meetingID = try store.insertMeeting(
            title: "Separated",
            calendarEventID: nil,
            startTime: startedAt,
            endTime: startedAt.addingTimeInterval(10),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let microphoneURL = support.supportDirectory.appendingPathComponent("mic.wav")
        let systemURL = support.supportDirectory.appendingPathComponent("system.wav")
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(
            samples: Array(repeating: 4_000, count: 16_000),
            to: microphoneURL
        )
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(
            samples: Array(repeating: -4_000, count: 16_000),
            to: systemURL
        )
        let temporary = try #require(
            try MeetingRecordingWriter.makeTemporarySeparatedRecording(
                microphoneURL: microphoneURL,
                systemURL: systemURL
            )
        )
        let recordingsDirectory = support.supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )
        let retained = recordingsDirectory.appendingPathComponent("separated.wav")
        try FileManager.default.moveItem(at: temporary, to: retained)
        _ = try store.registerMeetingRecordingWithSeparatedChannels(
            meetingID: meetingID,
            path: retained.path,
            createdAt: startedAt,
            deleteAfter: nil,
            sourceLayout: .separateStereoMicrophoneAndSystem
        )

        let reopened = DictationStore(databaseURL: databaseURL)
        try reopened.migrateIfNeeded()
        let inputs = try MeetingRecordingUnitResolver.resolve(
            meetingID: meetingID,
            store: reopened,
            supportDirectory: support.supportDirectory
        )
        let result = try await MeetingTranscriptionPipeline(
            provider: SignalRoleRetranscriptionProvider()
        ).process(MeetingTranscriptionRequest(
            units: inputs,
            backend: .whisperSmall,
            languages: .init(),
            purpose: .retranscribe,
            systemDiarization: .disabled
        ))

        #expect(result.attributedTurns.map(\.sourceRole) == [.you, .others])
        #expect(result.attributedTurns.map(\.text) == ["local source", "remote source"])
        #expect(result.formattedTranscript.contains("You: local source"))
        #expect(result.formattedTranscript.contains("Others: remote source"))
    }

    @Test("source-aware sessions survive reopen and use one run-scoped backend")
    func sourceAwareMultiSessionRetranscription() async throws {
        let fixture = try RetranscriptionFixture()
        defer { fixture.cleanup() }
        let first = try fixture.addSession(
            sessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = try fixture.addSession(
            sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        let provider = RetranscriptionProvider(results: [
            first.sessionID.uuidString.lowercased(): (
                local: "first local",
                remote: "first remote"
            ),
            second.sessionID.uuidString.lowercased(): (
                local: "second local",
                remote: "second remote"
            ),
        ])
        var config = AppConfig()
        config.meetingTranscriptionBackend = BackendOption.parakeetMultilingual.backend
        config.meetingTranscriptionModel = BackendOption.parakeetMultilingual.model
        let configuredBefore = (
            config.meetingTranscriptionBackend,
            config.meetingTranscriptionModel
        )

        let reopened = DictationStore(databaseURL: fixture.databaseURL)
        try reopened.migrateIfNeeded()
        let units = try MeetingRecordingUnitResolver.resolve(
            meetingID: fixture.meetingID,
            store: reopened,
            supportDirectory: fixture.support.supportDirectory
        )
        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: units,
                backend: .whisperSmall,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .disabled
            )
        )

        #expect(result.attributedTurns.map(\.text) == [
            "first local",
            "first remote",
            "second local",
            "second remote",
        ])
        #expect(result.attributedTurns.map(\.sourceRole) == [
            .you,
            .others,
            .you,
            .others,
        ])
        #expect(provider.backends == Array(repeating: .whisperSmall, count: 4))
        #expect((
            config.meetingTranscriptionBackend,
            config.meetingTranscriptionModel
        ) == configuredBefore)
    }

    @Test("failed processing leaves the prior transcript and status unchanged")
    func failedProcessingDoesNotCommit() async throws {
        let fixture = try RetranscriptionFixture(rawTranscript: "prior transcript")
        defer { fixture.cleanup() }
        _ = try fixture.addSession(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let original = try #require(try fixture.store.meeting(id: fixture.meetingID))
        let provider = RetranscriptionProvider(results: [:], shouldFail: true)
        let units = try MeetingRecordingUnitResolver.resolve(
            meetingID: fixture.meetingID,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )

        await #expect(throws: Error.self) {
            _ = try await MeetingTranscriptionPipeline(provider: provider).process(
                MeetingTranscriptionRequest(
                    units: units,
                    backend: .whisperSmall,
                    languages: .init(),
                    purpose: .retranscribe,
                    systemDiarization: .disabled
                )
            )
        }

        let after = try #require(try fixture.store.meeting(id: fixture.meetingID))
        #expect(after.rawTranscript == original.rawTranscript)
        #expect(after.status == original.status)
    }

    @Test("legacy mixed recording remains playable and never fabricates You")
    func legacyMixedFallbackHasUnknownRole() async throws {
        let support = try MeetingRecordingBundleTestSupport(testName: "legacy-retranscription")
        defer { support.cleanup() }
        let playback = try support.makePlaybackFile(named: "legacy.wav")
        let store = DictationStore(
            databaseURL: support.supportDirectory.appendingPathComponent("muesli.sqlite")
        )
        try store.migrateIfNeeded()
        let start = Date(timeIntervalSince1970: 1_000)
        let meetingID = try store.insertMeeting(
            title: "Legacy",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(10),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: playback.path
        )
        let units = try MeetingRecordingUnitResolver.resolve(
            meetingID: meetingID,
            store: store,
            supportDirectory: support.supportDirectory
        )
        let provider = RetranscriptionProvider(
            results: [:],
            legacyResults: [playback.lastPathComponent: "two mixed voices"]
        )

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: units,
                backend: .whisperSmall,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .optionalPost
            )
        )

        #expect(result.attributedTurns.map(\.sourceRole) == [.legacyUnknown])
        #expect(result.formattedTranscript.contains("Speaker: two mixed voices"))
        #expect(!result.formattedTranscript.contains("You:"))
        #expect(result.degradations.contains(.legacySourceIdentityUnavailable))
        support.assertExists(playback)
    }
}

private struct SignalRoleRetranscriptionProvider: MeetingTranscriptionProviding {
    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        let samples = try WavReader.readFloatMonoWAV(from: url).samples
        let mean = samples.isEmpty ? 0 : samples.reduce(0, +) / Float(samples.count)
        let text = mean >= 0 ? "local source" : "remote source"
        return SpeechTranscriptionResult(
            text: text,
            segments: [.init(start: 0, end: 1, text: text)]
        )
    }

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]? {
        nil
    }
}

private enum RetranscriptionTestError: Error {
    case failed
    case missingSession(String)
}

private final class RetranscriptionProvider: MeetingTranscriptionProviding, @unchecked Sendable {
    private struct State {
        var backends: [BackendOption] = []
    }

    private let results: [String: (local: String, remote: String)]
    private let legacyResults: [String: String]
    private let shouldFail: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        results: [String: (local: String, remote: String)],
        legacyResults: [String: String] = [:],
        shouldFail: Bool = false
    ) {
        self.results = results
        self.legacyResults = legacyResults
        self.shouldFail = shouldFail
    }

    var backends: [BackendOption] {
        state.withLock { $0.backends }
    }

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        state.withLock { $0.backends.append(backend) }
        if shouldFail { throw RetranscriptionTestError.failed }
        if let text = legacyResults[url.lastPathComponent] {
            return SpeechTranscriptionResult(
                text: text,
                segments: [.init(start: 0, end: 0.1, text: text)]
            )
        }
        let session = url.deletingLastPathComponent().lastPathComponent
        guard let result = results[session] else {
            throw RetranscriptionTestError.missingSession(url.path)
        }
        let text = url.lastPathComponent == "mic-cleaned.wav"
            ? result.local
            : result.remote
        return SpeechTranscriptionResult(
            text: text,
            segments: [.init(start: 0, end: 0.1, text: text)]
        )
    }

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]? {
        nil
    }
}

private struct RetranscriptionFixture {
    let support: MeetingRecordingBundleTestSupport
    let databaseURL: URL
    let store: DictationStore
    let meetingID: Int64

    init(rawTranscript: String = "") throws {
        support = try MeetingRecordingBundleTestSupport(testName: "retranscription")
        databaseURL = support.supportDirectory.appendingPathComponent("muesli.sqlite")
        store = DictationStore(databaseURL: databaseURL)
        try store.migrateIfNeeded()
        let start = Date(timeIntervalSince1970: 900)
        meetingID = try store.insertMeeting(
            title: "Retained meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: rawTranscript,
            formattedNotes: "prior notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    func addSession(
        sessionID: UUID,
        startedAt: Date
    ) throws -> MeetingRecordingBundleManifest {
        let capture = try MeetingProcessingCapture(
            meetingID: meetingID,
            sessionID: sessionID,
            startedAt: startedAt,
            finalModelID: BackendOption.parakeetMultilingual.asrModelID,
            supportDirectory: support.supportDirectory
        )
        capture.appendMicrophone(MeetingAudioTestFixtures.microphoneOnly().microphone)
        capture.appendSystem(MeetingAudioTestFixtures.systemOnly().system)
        let staged = try capture.finalize(endedAt: startedAt.addingTimeInterval(10))
        let playbackURL = try support.makePlaybackFile(
            named: "\(sessionID.uuidString.lowercased()).wav"
        )
        let bundle = try MeetingRecordingBundlePublisher.publish(
            stagedAudio: staged,
            playbackURL: playbackURL,
            supportDirectory: support.supportDirectory
        )
        _ = try store.registerMeetingRecordingWithSourceBundle(
            meetingID: meetingID,
            playbackPath: playbackURL.path,
            createdAt: startedAt,
            deleteAfter: nil,
            bundlePath: bundle.directoryURL.path,
            schemaVersion: bundle.manifest.schemaVersion,
            sourceState: bundle.sourceState
        )
        return bundle.manifest
    }

    func cleanup() {
        support.cleanup()
    }
}
