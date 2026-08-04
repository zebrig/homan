import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting recording bundle publisher")
struct MeetingRecordingBundlePublisherTests {
    @Test("publishes a complete bundle atomically and links playback metadata")
    func publishesAtomically() throws {
        let fixture = try PublisherFixture()
        defer { fixture.cleanup() }

        let published = try MeetingRecordingBundlePublisher.publish(
            stagedAudio: fixture.stagedAudio,
            playbackURL: fixture.playbackURL,
            supportDirectory: fixture.support.supportDirectory
        )

        fixture.support.assertExists(published.directoryURL)
        fixture.support.assertExists(published.manifestURL)
        fixture.support.assertExists(try #require(published.microphoneURL))
        fixture.support.assertExists(try #require(published.systemURL))
        fixture.support.assertExists(fixture.stagedAudio.directoryURL)
        #expect(published.manifest.sessionID == fixture.stagedAudio.manifest.sessionID)
        #expect(published.manifest.playback?.relativeOrAbsolutePath == fixture.playbackURL.path)
        #expect(published.manifest.microphone.sampleCount == fixture.microphone.count)
        #expect(published.manifest.system.sampleCount == fixture.system.count)
        #expect(published.sourceState == .complete)

        let sourceRoot = fixture.support.sourceBundlesRoot
        let names = try FileManager.default.contentsOfDirectory(atPath: sourceRoot.path)
        #expect(names == [fixture.stagedAudio.manifest.sessionID.uuidString.lowercased()])
        #expect(!names.contains { $0.hasPrefix(".pending-") })
    }

    @Test("retry is idempotent after a successful promotion")
    func successfulRetryIsIdempotent() throws {
        let fixture = try PublisherFixture()
        defer { fixture.cleanup() }

        let first = try MeetingRecordingBundlePublisher.publish(
            stagedAudio: fixture.stagedAudio,
            playbackURL: fixture.playbackURL,
            supportDirectory: fixture.support.supportDirectory
        )
        let second = try MeetingRecordingBundlePublisher.publish(
            stagedAudio: fixture.stagedAudio,
            playbackURL: fixture.playbackURL,
            supportDirectory: fixture.support.supportDirectory
        )

        #expect(first.directoryURL == second.directoryURL)
        #expect(first.manifest == second.manifest)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: fixture.support.sourceBundlesRoot.path
        ).count == 1)
    }

    @Test("failed promotion preserves staging and can be retried")
    func failedPromotionCanRetry() throws {
        let fixture = try PublisherFixture()
        defer { fixture.cleanup() }
        let destination = fixture.support.bundleDirectory(
            sessionID: fixture.stagedAudio.manifest.sessionID
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try Data("broken".utf8).write(
            to: destination.appendingPathComponent(MeetingRecordingBundle.manifestFilename)
        )

        #expect(throws: Error.self) {
            try MeetingRecordingBundlePublisher.publish(
                stagedAudio: fixture.stagedAudio,
                playbackURL: fixture.playbackURL,
                supportDirectory: fixture.support.supportDirectory
            )
        }
        fixture.support.assertExists(fixture.stagedAudio.microphoneURL)
        fixture.support.assertExists(fixture.stagedAudio.systemURL)

        try FileManager.default.removeItem(at: destination)
        let retried = try MeetingRecordingBundlePublisher.publish(
            stagedAudio: fixture.stagedAudio,
            playbackURL: fixture.playbackURL,
            supportDirectory: fixture.support.supportDirectory
        )
        #expect(retried.sourceState == .complete)
    }

    @Test("publishes native raw epochs without replacing them with processed WAVs")
    func publishesRawEpochs() throws {
        let support = try MeetingRecordingBundleTestSupport(
            testName: "raw-publisher"
        )
        defer { support.cleanup() }
        let sessionID = UUID()
        let capture = try MeetingRawAudioCapture(
            meetingID: 42,
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 1_000),
            timelineAnchorNanoseconds: 10_000,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: support.supportDirectory,
            compactLosslessly: true
        )
        capture.append(
            rawChunk(samples: [100, 200], timestamp: 10_000),
            role: .microphone
        )
        capture.append(
            rawChunk(samples: [300, 400], timestamp: 10_000),
            role: .system
        )
        let staged = try capture.finalize(
            endedAt: Date(timeIntervalSince1970: 1_001)
        )
        let playback = try support.makePlaybackFile()

        let published = try MeetingRecordingBundlePublisher.publish(
            stagedRawAudio: staged,
            playbackURL: playback,
            supportDirectory: support.supportDirectory
        )

        #expect(published.manifest.schemaVersion == 2)
        #expect(published.microphoneURL == nil)
        #expect(published.systemURL == nil)
        let raw = try #require(published.rawAudio)
        #expect(raw.manifest.microphoneEpochs.count == 1)
        #expect(raw.manifest.systemEpochs.count == 1)
        #expect(
            raw.manifest.microphoneEpochs.allSatisfy {
                $0.relativePath.hasPrefix("raw/microphone/")
            }
        )
        #expect(
            raw.manifest.systemEpochs.allSatisfy {
                $0.relativePath.hasPrefix("raw/system/")
            }
        )
        for epoch in raw.epochs {
            support.assertExists(raw.payloadURL(for: epoch))
        }
        #expect(published.sourceState == .complete)
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
}

private struct PublisherFixture {
    let support: MeetingRecordingBundleTestSupport
    let stagedAudio: MeetingStagedAudio
    let playbackURL: URL
    let microphone: [Int16]
    let system: [Int16]

    init() throws {
        support = try MeetingRecordingBundleTestSupport(testName: "publisher")
        microphone = MeetingAudioTestFixtures.microphoneOnly().microphone
        system = MeetingAudioTestFixtures.systemOnly().system
        let capture = try MeetingProcessingCapture(
            meetingID: 42,
            sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            startedAt: Date(timeIntervalSince1970: 1_000),
            finalModelID: BackendOption.parakeetMultilingual.asrModelID,
            supportDirectory: support.supportDirectory
        )
        capture.appendMicrophone(microphone)
        capture.appendSystem(system)
        stagedAudio = try capture.finalize(endedAt: Date(timeIntervalSince1970: 1_010))
        playbackURL = try support.makePlaybackFile()
    }

    func cleanup() {
        support.cleanup()
    }
}
