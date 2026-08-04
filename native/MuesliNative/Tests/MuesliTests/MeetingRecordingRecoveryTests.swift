import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting recording recovery", .serialized)
struct MeetingRecordingRecoveryTests {
    @Test("published but unregistered bundle is linked and reconciliation is idempotent")
    func registersPublishedBundle() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let published = try fixture.publishSession()

        let first = try MeetingRecordingRecoveryService.reconcile(
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )
        let second = try MeetingRecordingRecoveryService.reconcile(
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )

        #expect(first.registeredPublishedBundles == 1)
        #expect(first.removedRedundantStagingSessions == 1)
        #expect(second.didChange == false)
        let units = try fixture.store.meetingRecordingUnits(
            meetingID: fixture.meetingID
        )
        #expect(units.count == 1)
        #expect(
            units.first.map {
                URL(fileURLWithPath: $0.sourceBundle?.bundlePath ?? "")
                    .standardizedFileURL.path
            }
                == published.bundle.directoryURL.standardizedFileURL.path
        )
    }

    @Test("dangling source link is marked invalid without hiding playback")
    func marksDanglingLink() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let published = try fixture.publishSession()
        let unit = try fixture.store.registerMeetingRecordingWithSourceBundle(
            meetingID: fixture.meetingID,
            playbackPath: published.playbackURL.path,
            createdAt: published.bundle.manifest.startedAt,
            deleteAfter: nil,
            bundlePath: published.bundle.directoryURL.path,
            schemaVersion: published.bundle.manifest.schemaVersion,
            sourceState: .complete
        )
        try FileManager.default.removeItem(at: published.bundle.directoryURL)

        let report = try MeetingRecordingRecoveryService.reconcile(
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )

        #expect(report.markedDanglingLinks == 1)
        #expect(try fixture.store.meetingRecordingSourceBundle(
            recordingID: unit.recording.id
        )?.sourceState == .invalid)
        fixture.support.assertExists(published.playbackURL)
    }

    @Test("stale pending and proven unreferenced bundles are cleaned")
    func cleansPendingAndUnreferenced() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let published = try fixture.publishSession()
        try FileManager.default.removeItem(at: published.playbackURL)
        let pending = fixture.support.sourceBundlesRoot
            .appendingPathComponent(".pending-stale", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pending,
            withIntermediateDirectories: true
        )

        let report = try MeetingRecordingRecoveryService.reconcile(
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )

        #expect(report.removedPendingDirectories == 1)
        #expect(report.removedUnreferencedBundles == 1)
        fixture.support.assertMissing(pending)
        fixture.support.assertMissing(published.bundle.directoryURL)
        fixture.support.assertExists(published.staged.directoryURL)
    }

    @Test("published raw bundle is registered and redundant raw staging is removed")
    func registersRawBundle() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let capture = try MeetingRawAudioCapture(
            meetingID: fixture.meetingID,
            startedAt: Date(timeIntervalSince1970: 1_000),
            timelineAnchorNanoseconds: 1_000,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: fixture.support.supportDirectory,
            compactLosslessly: true
        )
        capture.append(
            recoveryRawChunk(samples: [1_000, 2_000], timestamp: 1_000),
            role: .microphone
        )
        capture.append(
            recoveryRawChunk(samples: [3_000, 4_000], timestamp: 1_000),
            role: .system
        )
        let staged = try capture.finalize(
            endedAt: Date(timeIntervalSince1970: 1_001)
        )
        let playback = try fixture.support.makePlaybackFile()
        let bundle = try MeetingRecordingBundlePublisher.publish(
            stagedRawAudio: staged,
            playbackURL: playback,
            supportDirectory: fixture.support.supportDirectory
        )

        let report = try MeetingRecordingRecoveryService.reconcile(
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory
        )

        #expect(report.registeredPublishedBundles == 1)
        #expect(report.removedRedundantStagingSessions == 1)
        fixture.support.assertMissing(staged.directoryURL)
        let bundlePath = try #require(
            try fixture.store.meetingRecordingUnits(
                meetingID: fixture.meetingID
            ).first?.sourceBundle?.bundlePath
        )
        #expect(
            URL(fileURLWithPath: bundlePath).standardizedFileURL
                == bundle.directoryURL.standardizedFileURL
        )
    }
}

private func recoveryRawChunk(
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

private struct RecoveryFixture {
    struct Published {
        let staged: MeetingStagedAudio
        let playbackURL: URL
        let bundle: MeetingRecordingBundle
    }

    let support: MeetingRecordingBundleTestSupport
    let store: DictationStore
    let meetingID: Int64

    init() throws {
        support = try MeetingRecordingBundleTestSupport(testName: "recording-recovery")
        store = DictationStore(
            databaseURL: support.supportDirectory.appendingPathComponent("muesli.sqlite")
        )
        try store.migrateIfNeeded()
        meetingID = try store.insertMeeting(
            title: "Recovery",
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_000),
            endTime: Date(timeIntervalSince1970: 1_010),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    func publishSession() throws -> Published {
        let capture = try MeetingProcessingCapture(
            meetingID: meetingID,
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000),
            finalModelID: BackendOption.parakeetMultilingual.asrModelID,
            supportDirectory: support.supportDirectory
        )
        capture.appendMicrophone(MeetingAudioTestFixtures.microphoneOnly().microphone)
        capture.appendSystem(MeetingAudioTestFixtures.systemOnly().system)
        let staged = try capture.finalize(endedAt: Date(timeIntervalSince1970: 1_010))
        let playback = try support.makePlaybackFile(
            named: "\(staged.manifest.sessionID.uuidString.lowercased()).wav"
        )
        let bundle = try MeetingRecordingBundlePublisher.publish(
            stagedAudio: staged,
            playbackURL: playback,
            supportDirectory: support.supportDirectory
        )
        return Published(staged: staged, playbackURL: playback, bundle: bundle)
    }

    func cleanup() {
        support.cleanup()
    }
}
