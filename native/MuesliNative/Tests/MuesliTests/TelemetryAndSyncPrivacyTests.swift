import CloudKit
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting source-media privacy boundary", .serialized)
struct TelemetryAndSyncPrivacyTests {
    @Test("CloudKit text sync excludes local audio ownership and bytes")
    func cloudKitExcludesSourceMedia() throws {
        let support = try MeetingRecordingBundleTestSupport(testName: "sync-privacy")
        defer { support.cleanup() }
        let databaseURL = support.supportDirectory.appendingPathComponent("muesli.sqlite")
        let store = DictationStore(databaseURL: databaseURL)
        try store.migrateIfNeeded()
        let playback = try support.makePlaybackFile(
            named: "PRIVATE_PLAYBACK_PATH_SENTINEL.wav"
        )
        let sourceBundlePath = support.sourceBundlesRoot
            .appendingPathComponent("PRIVATE_SOURCE_BUNDLE_SENTINEL")
            .path
        let transcript = "PRIVATE_TRANSCRIPT_TEXT_SENTINEL"
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let meetingID = try store.insertMeeting(
            title: "Privacy",
            calendarEventID: nil,
            startTime: startedAt,
            endTime: startedAt.addingTimeInterval(10),
            rawTranscript: transcript,
            formattedNotes: "PRIVATE_SUMMARY_SENTINEL",
            micAudioPath: "PRIVATE_MIC_PATH_SENTINEL",
            systemAudioPath: "PRIVATE_SYSTEM_PATH_SENTINEL",
            savedRecordingPath: playback.path
        )
        let recording = try #require(
            try store.meetingRecordings(meetingID: meetingID).first
        )
        _ = try store.registerMeetingRecordingWithSourceBundle(
            meetingID: meetingID,
            playbackPath: playback.path,
            createdAt: startedAt,
            deleteAfter: nil,
            bundlePath: sourceBundlePath,
            schemaVersion: 1,
            sourceState: .recoveryPending
        )
        #expect(recording.path == playback.path)

        let sync = try #require(
            try store.textRecordsNeedingSync().first { $0.kind == .meeting }
        )
        let encodedSync = try #require(
            String(data: JSONEncoder().encode(sync), encoding: .utf8)
        )
        let cloud = MuesliICloudSyncEngine.syncZoneCloudRecord(from: sync)
        let cloudValues = cloud.allKeys().compactMap { key -> String? in
            guard let value = cloud[key] else { return nil }
            return String(describing: value)
        }.joined(separator: "\n")

        // Meeting text is intentionally synced when iCloud text sync is on.
        #expect(cloud["text"] as? String == transcript)
        for privateValue in [
            playback.path,
            sourceBundlePath,
            "PRIVATE_MIC_PATH_SENTINEL",
            "PRIVATE_SYSTEM_PATH_SENTINEL",
            MeetingRecordingBundle.manifestFilename,
            Data([0x00, 0x01, 0x02, 0x03]).base64EncodedString(),
        ] {
            #expect(!encodedSync.contains(privateValue))
            #expect(!cloudValues.contains(privateValue))
        }
        let keys = Set(cloud.allKeys())
        #expect(!keys.contains("savedRecordingPath"))
        #expect(!keys.contains("sourceBundlePath"))
        #expect(!keys.contains("manifest"))
        #expect(!keys.contains("audio"))
        #expect(!keys.contains("audioBytes"))
    }

    @Test("meeting telemetry calls contain event names only")
    func telemetryExcludesMeetingContent() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MuesliNativeApp/MuesliController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let meetingCalls = source
            .split(separator: "\n")
            .filter { $0.contains("TelemetryDeck.signal(\"meeting.") }
            .map(String.init)

        #expect(Set(meetingCalls.map {
            $0.trimmingCharacters(in: .whitespaces)
        }) == [
            "TelemetryDeck.signal(\"meeting.imported\")",
            "TelemetryDeck.signal(\"meeting.completed\")",
        ])
        for call in meetingCalls {
            #expect(!call.contains("parameters:"))
            #expect(!call.contains("transcript"))
            #expect(!call.contains("path"))
            #expect(!call.contains("manifest"))
            #expect(!call.contains("audio"))
        }
    }
}
