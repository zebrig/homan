import FluidAudio
import Foundation
import MuesliCore
import os
import Testing
@testable import MuesliNativeApp

@Suite("Meeting re-transcription", .serialized)
struct MeetingRetranscriptionTests {
    @Test("complete raw source bundle outranks separated playback metadata")
    func completeRawBundleOutranksSeparatedPlayback() throws {
        let fixture = try RetranscriptionFixture()
        defer { fixture.cleanup() }
        let bundle = try fixture.addRawSession(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000),
            sourceLayout: .separateStereoMicrophoneAndSystem
        )

        let reopened = DictationStore(databaseURL: fixture.databaseURL)
        try reopened.migrateIfNeeded()
        let inputs = try MeetingRecordingUnitResolver.resolve(
            meetingID: fixture.meetingID,
            store: reopened,
            supportDirectory: fixture.support.supportDirectory
        )

        guard case .sourceBundle(let input) = try #require(inputs.first) else {
            Issue.record("Expected complete raw source bundle to outrank playback")
            return
        }
        #expect(input.bundle.manifest.sessionID == bundle.manifest.sessionID)
        #expect(input.bundle.rawAudio != nil)
        #expect(MeetingTranscriptionProvenance.audioSource(for: inputs) == "raw_source_bundle")
        #expect(
            MeetingTranscriptionProvenance.requestedAECModel(
                for: inputs,
                requested: .localVQEV12
            ) == MeetingAecModel.localVQEV12.rawValue
        )
    }

    @Test("degraded raw bundle falls back to separated playback when usable")
    func degradedRawBundleFallsBackToSeparatedPlayback() throws {
        let fixture = try RetranscriptionFixture()
        defer { fixture.cleanup() }
        let bundle = try fixture.addRawSession(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000),
            sourceLayout: .separateStereoMicrophoneAndSystem
        )
        let systemEpoch = try #require(bundle.rawAudio?.manifest.systemEpochs.first)
        try FileManager.default.removeItem(
            at: try #require(bundle.rawAudio).payloadURL(for: systemEpoch)
        )

        var inputs = try MeetingRecordingUnitResolver.resolve(
            meetingID: fixture.meetingID,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )
        guard case .separatedChannels = try #require(inputs.first) else {
            Issue.record("Expected usable separated playback fallback")
            return
        }
        #expect(MeetingTranscriptionProvenance.audioSource(for: inputs) == "separated_playback")
        #expect(
            MeetingTranscriptionProvenance.requestedAECModel(
                for: inputs,
                requested: .localVQEV12
            ) == nil
        )

        let playbackURL = URL(
            fileURLWithPath: try #require(
                fixture.store.meetingRecordingUnits(meetingID: fixture.meetingID).first
            ).recording.path
        )
        try FileManager.default.removeItem(at: playbackURL)
        inputs = try MeetingRecordingUnitResolver.resolve(
            meetingID: fixture.meetingID,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )
        guard case .sourceBundle(let degraded) = try #require(inputs.first) else {
            Issue.record("Expected usable degraded bundle when playback is missing")
            return
        }
        #expect(degraded.bundle.sourceState == .degraded)
        #expect(degraded.bundle.rawAudio?.manifest.microphoneEpochs.isEmpty == false)
    }

    @Test("degraded source-aware bundle outranks legacy mixed playback")
    func degradedBundleOutranksLegacyPlayback() throws {
        let fixture = try RetranscriptionFixture()
        defer { fixture.cleanup() }
        let bundle = try fixture.addRawSession(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000),
            sourceLayout: nil
        )
        let rawAudio = try #require(bundle.rawAudio)
        let systemEpoch = try #require(rawAudio.manifest.systemEpochs.first)
        try FileManager.default.removeItem(at: rawAudio.payloadURL(for: systemEpoch))

        let inputs = try MeetingRecordingUnitResolver.resolve(
            meetingID: fixture.meetingID,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )

        guard case .sourceBundle(let input) = try #require(inputs.first) else {
            Issue.record("Expected source-aware degraded bundle before mixed playback")
            return
        }
        #expect(input.bundle.sourceState == .degraded)
        #expect(input.bundle.rawAudio?.manifest.microphoneEpochs.isEmpty == false)
    }

    @Test("unsupported bundle version preserves separated playback fallback")
    func unsupportedBundlePreservesSeparatedPlayback() throws {
        let support = try MeetingRecordingBundleTestSupport(
            testName: "unsupported-separated-fallback"
        )
        defer { support.cleanup() }
        let playback = try support.makeSeparatedPlaybackFile()
        let recording = MeetingRecordingRecord(
            id: 7,
            meetingID: 42,
            path: playback.path,
            createdAt: Date(timeIntervalSince1970: 1_000),
            deleteAfter: nil,
            sourceLayout: .separateStereoMicrophoneAndSystem
        )
        let source = MeetingRecordingSourceBundleRecord(
            recordingID: recording.id,
            bundlePath: support.bundleDirectory(sessionID: UUID()).path,
            schemaVersion: 99,
            sourceState: .complete,
            createdAt: recording.createdAt
        )

        let inputs = try MeetingRecordingUnitResolver.resolve(
            units: [.init(recording: recording, sourceBundle: source)],
            supportDirectory: support.supportDirectory
        )

        guard case .separatedChannels(let separated) = try #require(inputs.first) else {
            Issue.record("Expected separated playback for unsupported bundle")
            return
        }
        #expect(separated.recordingURL == playback)
    }

    @Test("missing or malformed bundle manifest preserves separated playback")
    func unreadableBundlePreservesSeparatedPlayback() throws {
        let fixture = try RetranscriptionFixture()
        defer { fixture.cleanup() }
        let bundle = try fixture.addRawSession(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000),
            sourceLayout: .separateStereoMicrophoneAndSystem
        )
        let originalManifest = try Data(contentsOf: bundle.manifestURL)

        try FileManager.default.removeItem(at: bundle.manifestURL)
        var inputs = try MeetingRecordingUnitResolver.resolve(
            meetingID: fixture.meetingID,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )
        #expect(inputs.first?.transcriptionAudioSource == .separatedPlayback)

        try originalManifest.write(to: bundle.manifestURL, options: .atomic)
        try Data("not-json".utf8).write(to: bundle.manifestURL, options: .atomic)
        inputs = try MeetingRecordingUnitResolver.resolve(
            meetingID: fixture.meetingID,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )
        #expect(inputs.first?.transcriptionAudioSource == .separatedPlayback)
    }

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

    func addRawSession(
        sessionID: UUID,
        startedAt: Date,
        sourceLayout: MeetingRecordingSourceLayout? = nil
    ) throws -> MeetingRecordingBundle {
        let capture = try MeetingRawAudioCapture(
            meetingID: meetingID,
            sessionID: sessionID,
            startedAt: startedAt,
            timelineAnchorNanoseconds: 10_000,
            finalModelID: BackendOption.parakeetMultilingual.asrModelID,
            supportDirectory: support.supportDirectory,
            compactLosslessly: true
        )
        capture.append(
            rawChunk(samples: [8_000, 8_000, 8_000, 8_000], timestamp: 10_000),
            role: .microphone
        )
        capture.append(
            rawChunk(samples: [4_000, 4_000, 4_000, 4_000], timestamp: 10_000),
            role: .system
        )
        let staged = try capture.finalize(
            endedAt: startedAt.addingTimeInterval(1)
        )
        let playbackURL = try support.makeSeparatedPlaybackFile(
            named: "\(sessionID.uuidString.lowercased()).wav"
        )
        let bundle = try MeetingRecordingBundlePublisher.publish(
            stagedRawAudio: staged,
            playbackURL: playbackURL,
            supportDirectory: support.supportDirectory
        )
        if let sourceLayout {
            _ = try store.registerMeetingRecordingWithSeparatedChannels(
                meetingID: meetingID,
                path: playbackURL.path,
                createdAt: startedAt,
                deleteAfter: nil,
                sourceLayout: sourceLayout
            )
        }
        _ = try store.registerMeetingRecordingWithSourceBundle(
            meetingID: meetingID,
            playbackPath: playbackURL.path,
            createdAt: startedAt,
            deleteAfter: nil,
            bundlePath: bundle.directoryURL.path,
            schemaVersion: bundle.manifest.schemaVersion,
            sourceState: bundle.sourceState
        )
        return bundle
    }

    private func rawChunk(
        samples: [Int16],
        timestamp: UInt64
    ) -> CapturedAudioChunk {
        CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: 16_000,
                channelCount: 1,
                sampleRepresentation: .signedInt16,
                interleaved: true
            ),
            frameCount: samples.count,
            timestamp: CapturedAudioTimestamp(
                monotonicNanoseconds: timestamp,
                origin: .sourceHostClock
            ),
            planes: [
                CapturedAudioPlane(
                    channelCount: 1,
                    data: samples.withUnsafeBufferPointer { Data(buffer: $0) }
                ),
            ]
        )
    }

    func cleanup() {
        support.cleanup()
    }
}
