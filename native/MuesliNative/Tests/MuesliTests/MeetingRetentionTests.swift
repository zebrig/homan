import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting recording retention", .serialized)
struct MeetingRetentionTests {
    @Test("per-meeting cleanup removes raw and derived orphan staging")
    func deletesOrphanStagingForOneMeeting() throws {
        let support = try MeetingRecordingBundleTestSupport(testName: "orphan-staging")
        defer { support.cleanup() }
        let meetingID: Int64 = 42
        let otherMeetingID: Int64 = 43
        let targetRaw = support.rawProcessingRoot
            .appendingPathComponent(String(meetingID), isDirectory: true)
        let targetDerived = support.processingRoot
            .appendingPathComponent(String(meetingID), isDirectory: true)
        let otherRaw = support.rawProcessingRoot
            .appendingPathComponent(String(otherMeetingID), isDirectory: true)
        try FileManager.default.createDirectory(at: targetRaw, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDerived, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRaw, withIntermediateDirectories: true)

        try MeetingRecordingRetentionService.deleteStaging(
            meetingID: meetingID,
            supportDirectory: support.supportDirectory
        )

        support.assertMissing(targetRaw)
        support.assertMissing(targetDerived)
        support.assertExists(otherRaw)
    }

    @Test("clear-history cleanup removes both staging roots")
    func deletesAllOrphanStaging() throws {
        let support = try MeetingRecordingBundleTestSupport(testName: "all-orphan-staging")
        defer { support.cleanup() }
        let raw = support.rawProcessingRoot
            .appendingPathComponent("42/session", isDirectory: true)
        let derived = support.processingRoot
            .appendingPathComponent("43/session", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)

        try MeetingRecordingRetentionService.deleteAllStaging(
            supportDirectory: support.supportDirectory
        )

        support.assertMissing(support.rawProcessingRoot)
        support.assertMissing(support.processingRoot)
    }

    @Test("deletion removes one-file separated recording without companion media")
    func deletesSeparatedRecording() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let unit = try fixture.addSeparatedSession()
        let recordingURL = URL(fileURLWithPath: unit.recording.path)
        let waveformURL = try RecordingWaveformCacheFiles.cacheURL(
            for: recordingURL,
            supportDirectory: fixture.support.supportDirectory
        )
        try Data([1, 2, 3]).write(to: waveformURL)

        #expect(try MeetingRecordingRetentionService.delete(
            recording: unit.recording,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory,
            leaseRegistry: fixture.leaseRegistry
        ) == .deleted)

        fixture.support.assertMissing(recordingURL)
        fixture.support.assertMissing(waveformURL)
        #expect(try fixture.store.meetingRecordingUnits(
            meetingID: fixture.meetingID
        ).isEmpty)
    }

    @Test("deletion removes playback, waveform, canonical sources, staging, and row")
    func deletesWholeRecordingUnit() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let unit = try fixture.addSourceAwareSession()
        let waveformURL = try RecordingWaveformCacheFiles.cacheURL(
            for: URL(fileURLWithPath: unit.recording.path),
            supportDirectory: fixture.support.supportDirectory
        )
        try Data([1, 2, 3]).write(to: waveformURL)
        let bundleURL = URL(fileURLWithPath: try #require(unit.sourceBundle?.bundlePath))
        let sessionID = try #require(UUID(uuidString: bundleURL.lastPathComponent))
        let stagingURL = fixture.support.processingRoot
            .appendingPathComponent(String(fixture.meetingID), isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)

        let outcome = try MeetingRecordingRetentionService.delete(
            recording: unit.recording,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory,
            leaseRegistry: fixture.leaseRegistry
        )

        #expect(outcome == .deleted)
        fixture.support.assertMissing(URL(fileURLWithPath: unit.recording.path))
        fixture.support.assertMissing(waveformURL)
        fixture.support.assertMissing(bundleURL)
        fixture.support.assertMissing(stagingURL)
        #expect(try fixture.store.meetingRecordingUnits(
            meetingID: fixture.meetingID
        ).isEmpty)
    }

    @Test("active reader defers automatic deletion and retry succeeds after release")
    func activeReaderDefersDeletion() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let unit = try fixture.addSourceAwareSession()
        let registry = MeetingRecordingLeaseRegistry()
        let reader = try #require(
            registry.acquireRead(for: .recordingID(unit.recording.id))
        )

        #expect(try MeetingRecordingRetentionService.delete(
            recording: unit.recording,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory,
            leaseRegistry: registry
        ) == .deferred)
        fixture.support.assertExists(URL(fileURLWithPath: unit.recording.path))
        #expect(try fixture.store.meetingRecordingUnits(
            meetingID: fixture.meetingID
        ).count == 1)

        reader.release()
        #expect(try MeetingRecordingRetentionService.delete(
            recording: unit.recording,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory,
            leaseRegistry: registry
        ) == .deleted)
    }

    @Test("deletion removes schema-v2 raw bundle and raw staging as one unit")
    func deletesRawRecordingUnit() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let unit = try fixture.addRawSourceAwareSession()
        let bundleURL = URL(
            fileURLWithPath: try #require(unit.sourceBundle?.bundlePath)
        )
        let sessionID = try #require(UUID(
            uuidString: bundleURL.lastPathComponent
        ))
        let rawStagingURL = fixture.support.rawProcessingRoot
            .appendingPathComponent(
                String(fixture.meetingID),
                isDirectory: true
            )
            .appendingPathComponent(
                sessionID.uuidString.lowercased(),
                isDirectory: true
            )
        fixture.support.assertExists(rawStagingURL)

        #expect(try MeetingRecordingRetentionService.delete(
            recording: unit.recording,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory,
            leaseRegistry: fixture.leaseRegistry
        ) == .deleted)

        fixture.support.assertMissing(
            URL(fileURLWithPath: unit.recording.path)
        )
        fixture.support.assertMissing(bundleURL)
        fixture.support.assertMissing(rawStagingURL)
    }

    @Test("shared playback survives per-session deletion")
    func sharedPlaybackSurvives() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let sourceAware = try fixture.addSourceAwareSession()
        let playbackPath = sourceAware.recording.path
        let otherMeetingID = try fixture.store.insertMeeting(
            title: "Shared legacy reference",
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 2_000),
            endTime: Date(timeIntervalSince1970: 2_010),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: playbackPath
        )

        #expect(try MeetingRecordingRetentionService.delete(
            recording: sourceAware.recording,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory,
            leaseRegistry: fixture.leaseRegistry
        ) == .deleted)

        fixture.support.assertExists(URL(fileURLWithPath: playbackPath))
        #expect(try fixture.store.meetingRecordings(meetingID: otherMeetingID).count == 1)
        fixture.support.assertMissing(URL(
            fileURLWithPath: try #require(sourceAware.sourceBundle?.bundlePath)
        ))
    }

    @Test("Keep audio excludes every session from expiry")
    func protectedMeetingDoesNotExpire() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        _ = try fixture.addSourceAwareSession(
            deleteAfter: Date(timeIntervalSince1970: 1_100)
        )
        let now = Date(timeIntervalSince1970: 1_200)
        #expect(try fixture.store.expiredMeetingRecordings(asOf: now).count == 1)

        try fixture.store.setMeetingRecordingRetentionProtected(
            meetingID: fixture.meetingID,
            protected: true
        )

        #expect(try fixture.store.expiredMeetingRecordings(asOf: now).isEmpty)
    }

    @Test("expiry removes the complete unprotected unit")
    func expiryDeletesWholeUnit() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let unit = try fixture.addSourceAwareSession(
            deleteAfter: Date(timeIntervalSince1970: 1_100)
        )
        let bundleURL = URL(
            fileURLWithPath: try #require(unit.sourceBundle?.bundlePath)
        )

        for expired in try fixture.store.expiredMeetingRecordings(
            asOf: Date(timeIntervalSince1970: 1_200)
        ) {
            #expect(try MeetingRecordingRetentionService.delete(
                recording: expired,
                store: fixture.store,
                supportDirectory: fixture.support.supportDirectory,
                leaseRegistry: fixture.leaseRegistry
            ) == .deleted)
        }

        fixture.support.assertMissing(URL(fileURLWithPath: unit.recording.path))
        fixture.support.assertMissing(bundleURL)
        #expect(try fixture.store.meetingRecordings(
            meetingID: fixture.meetingID
        ).isEmpty)
    }

    @Test("per-session deletion leaves every unselected session intact")
    func deletesOnlySelectedSession() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let first = try fixture.addSourceAwareSession(
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = try fixture.addSourceAwareSession(
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        let secondBundle = URL(
            fileURLWithPath: try #require(second.sourceBundle?.bundlePath)
        )

        #expect(try MeetingRecordingRetentionService.delete(
            recording: first.recording,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory,
            leaseRegistry: fixture.leaseRegistry
        ) == .deleted)

        let remaining = try fixture.store.meetingRecordingUnits(
            meetingID: fixture.meetingID
        )
        #expect(remaining.map(\.recording.id) == [second.recording.id])
        fixture.support.assertExists(URL(fileURLWithPath: second.recording.path))
        fixture.support.assertExists(secondBundle)
    }

    @Test("already-missing members do not prevent whole-unit cleanup")
    func missingMembersAreIdempotent() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let unit = try fixture.addSourceAwareSession()
        let bundleURL = URL(
            fileURLWithPath: try #require(unit.sourceBundle?.bundlePath)
        )
        try FileManager.default.removeItem(
            at: bundleURL.appendingPathComponent("system.wav")
        )
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: unit.recording.path)
        )

        #expect(try MeetingRecordingRetentionService.delete(
            recording: unit.recording,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory,
            leaseRegistry: fixture.leaseRegistry
        ) == .deleted)
        #expect(try MeetingRecordingRetentionService.delete(
            recording: unit.recording,
            store: fixture.store,
            supportDirectory: fixture.support.supportDirectory,
            leaseRegistry: fixture.leaseRegistry
        ) == .notFound)

        fixture.support.assertMissing(bundleURL)
        #expect(try fixture.store.meetingRecordingUnits(
            meetingID: fixture.meetingID
        ).isEmpty)
    }

    @Test("delete-all and meeting deletion leave no owned audio")
    func deleteAllThenMeetingLeavesNoMedia() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let first = try fixture.addSourceAwareSession(
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = try fixture.addSourceAwareSession(
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        let ownedURLs = [
            URL(fileURLWithPath: first.recording.path),
            URL(fileURLWithPath: try #require(first.sourceBundle?.bundlePath)),
            URL(fileURLWithPath: second.recording.path),
            URL(fileURLWithPath: try #require(second.sourceBundle?.bundlePath)),
        ]

        for recording in try fixture.store.meetingRecordings(
            meetingID: fixture.meetingID
        ) {
            #expect(try MeetingRecordingRetentionService.delete(
                recording: recording,
                store: fixture.store,
                supportDirectory: fixture.support.supportDirectory,
                leaseRegistry: fixture.leaseRegistry
            ) == .deleted)
        }
        try fixture.store.deleteMeeting(id: fixture.meetingID)

        for url in ownedURLs {
            fixture.support.assertMissing(url)
        }
        #expect(try fixture.store.meeting(id: fixture.meetingID) == nil)
    }

    @Test("meeting transcript retention clears raw transcript older than the window, keeps summary and recent meetings")
    func clearsExpiredMeetingTranscripts() throws {
        let support = try MeetingRecordingBundleTestSupport(testName: "transcript-retention")
        defer { support.cleanup() }
        let store = DictationStore(
            databaseURL: support.supportDirectory.appendingPathComponent("muesli.sqlite")
        )
        try store.migrateIfNeeded()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldMeetingID = try store.insertMeeting(
            title: "Old",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(-90 * 24 * 3_600),
            endTime: now.addingTimeInterval(-90 * 24 * 3_600 + 60),
            rawTranscript: "old transcript text",
            formattedNotes: "Keep summary",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let recentMeetingID = try store.insertMeeting(
            title: "Recent",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(-3_600),
            endTime: now.addingTimeInterval(-3_500),
            rawTranscript: "recent transcript text",
            formattedNotes: "Recent summary",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let cleared = try store.clearExpiredMeetingTranscripts(
            asOf: now,
            retentionDays: 60
        )

        #expect(cleared == 1)
        let old = try #require(try store.meeting(id: oldMeetingID))
        #expect(old.rawTranscript == "")
        #expect(old.formattedNotes == "Keep summary")
        let recent = try #require(try store.meeting(id: recentMeetingID))
        #expect(recent.rawTranscript == "recent transcript text")
        #expect(recent.formattedNotes == "Recent summary")
    }
}

private struct RetentionFixture {
    let support: MeetingRecordingBundleTestSupport
    let store: DictationStore
    let meetingID: Int64
    let leaseRegistry = MeetingRecordingLeaseRegistry()

    init() throws {
        support = try MeetingRecordingBundleTestSupport(testName: "retention")
        store = DictationStore(
            databaseURL: support.supportDirectory.appendingPathComponent("muesli.sqlite")
        )
        try store.migrateIfNeeded()
        meetingID = try store.insertMeeting(
            title: "Retention",
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_000),
            endTime: Date(timeIntervalSince1970: 1_010),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    func addSourceAwareSession(
        sessionID: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        deleteAfter: Date? = nil
    ) throws -> MeetingRecordingUnitRecord {
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
        let playback = try support.makePlaybackFile(
            named: "\(sessionID.uuidString.lowercased()).wav"
        )
        let bundle = try MeetingRecordingBundlePublisher.publish(
            stagedAudio: staged,
            playbackURL: playback,
            supportDirectory: support.supportDirectory
        )
        return try store.registerMeetingRecordingWithSourceBundle(
            meetingID: meetingID,
            playbackPath: playback.path,
            createdAt: startedAt,
            deleteAfter: deleteAfter,
            bundlePath: bundle.directoryURL.path,
            schemaVersion: bundle.manifest.schemaVersion,
            sourceState: bundle.sourceState
        )
    }

    func addSeparatedSession(
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        deleteAfter: Date? = nil
    ) throws -> MeetingRecordingUnitRecord {
        let microphoneURL = support.supportDirectory
            .appendingPathComponent("separated-mic-\(UUID().uuidString).wav")
        let systemURL = support.supportDirectory
            .appendingPathComponent("separated-system-\(UUID().uuidString).wav")
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(
            samples: MeetingAudioTestFixtures.microphoneOnly().microphone,
            to: microphoneURL
        )
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(
            samples: MeetingAudioTestFixtures.systemOnly().system,
            to: systemURL
        )
        let temporary = try #require(
            try MeetingRecordingWriter.makeTemporarySeparatedRecording(
                microphoneURL: microphoneURL,
                systemURL: systemURL
            )
        )
        try FileManager.default.createDirectory(
            at: support.recordingsRoot,
            withIntermediateDirectories: true
        )
        let retained = support.recordingsRoot
            .appendingPathComponent("separated-\(UUID().uuidString).wav")
        try FileManager.default.moveItem(at: temporary, to: retained)
        let recording = try store.registerMeetingRecordingWithSeparatedChannels(
            meetingID: meetingID,
            path: retained.path,
            createdAt: startedAt,
            deleteAfter: deleteAfter,
            sourceLayout: .separateStereoMicrophoneAndSystem
        )
        return MeetingRecordingUnitRecord(
            recording: recording,
            sourceBundle: nil
        )
    }

    func addRawSourceAwareSession(
        sessionID: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        deleteAfter: Date? = nil
    ) throws -> MeetingRecordingUnitRecord {
        let capture = try MeetingRawAudioCapture(
            meetingID: meetingID,
            sessionID: sessionID,
            startedAt: startedAt,
            timelineAnchorNanoseconds: 1_000,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: support.supportDirectory,
            compactLosslessly: true
        )
        capture.append(
            retentionRawChunk(samples: [1_000, 2_000], timestamp: 1_000),
            role: .microphone
        )
        capture.append(
            retentionRawChunk(samples: [3_000, 4_000], timestamp: 1_000),
            role: .system
        )
        let staged = try capture.finalize(
            endedAt: startedAt.addingTimeInterval(1)
        )
        let playback = try support.makePlaybackFile(
            named: "\(sessionID.uuidString.lowercased()).wav"
        )
        let bundle = try MeetingRecordingBundlePublisher.publish(
            stagedRawAudio: staged,
            playbackURL: playback,
            supportDirectory: support.supportDirectory
        )
        return try store.registerMeetingRecordingWithSourceBundle(
            meetingID: meetingID,
            playbackPath: playback.path,
            createdAt: startedAt,
            deleteAfter: deleteAfter,
            bundlePath: bundle.directoryURL.path,
            schemaVersion: bundle.manifest.schemaVersion,
            sourceState: bundle.sourceState
        )
    }

    func cleanup() {
        support.cleanup()
    }
}

private func retentionRawChunk(
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
