import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting recording source bundles")
struct MeetingRecordingBundleTests {
    @Test("schema v1 loads both validated sources")
    func loadsValidatedSources() throws {
        let fixture = try MeetingRecordingBundleTestSupport()
        defer { fixture.cleanup() }
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let directory = fixture.bundleDirectory(sessionID: sessionID)
        let microphoneURL = directory.appendingPathComponent("mic-cleaned.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        let microphone = MeetingAudioTestFixtures.microphoneOnly().microphone
        let system = MeetingAudioTestFixtures.systemOnly().system
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(samples: microphone, to: microphoneURL)
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(samples: system, to: systemURL)
        try writeManifest(
            manifest(
                sessionID: sessionID,
                microphoneSamples: microphone.count,
                systemSamples: system.count
            ),
            to: directory
        )

        let bundle = try MeetingRecordingBundle.load(
            directoryURL: directory,
            supportDirectory: fixture.supportDirectory
        )

        #expect(bundle.manifest.schemaVersion == 1)
        #expect(bundle.microphoneURL == microphoneURL)
        #expect(bundle.systemURL == systemURL)
        #expect(bundle.degradations.isEmpty)
        #expect(bundle.sourceState == .complete)
    }

    @Test("missing source degrades only that source")
    func missingSourceDegradesIndependently() throws {
        let fixture = try MeetingRecordingBundleTestSupport()
        defer { fixture.cleanup() }
        let sessionID = UUID()
        let directory = fixture.bundleDirectory(sessionID: sessionID)
        let microphoneURL = directory.appendingPathComponent("mic-cleaned.wav")
        let microphone = MeetingAudioTestFixtures.microphoneOnly().microphone
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(samples: microphone, to: microphoneURL)
        try writeManifest(
            manifest(
                sessionID: sessionID,
                microphoneSamples: microphone.count,
                systemSamples: 400
            ),
            to: directory
        )

        let bundle = try MeetingRecordingBundle.load(
            directoryURL: directory,
            supportDirectory: fixture.supportDirectory
        )

        #expect(bundle.microphoneURL == microphoneURL)
        #expect(bundle.systemURL == nil)
        #expect(bundle.degradations.contains(.sourceMissing(.system)))
        #expect(bundle.sourceState == .degraded)
    }

    @Test("corrupt WAV is rejected without hiding its valid peer")
    func corruptSourceIsReported() throws {
        let fixture = try MeetingRecordingBundleTestSupport()
        defer { fixture.cleanup() }
        let sessionID = UUID()
        let directory = fixture.bundleDirectory(sessionID: sessionID)
        let microphoneURL = directory.appendingPathComponent("mic-cleaned.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(samples: [1, 2, 3], to: microphoneURL)
        try MeetingAudioTestFixtures.writeCorruptWAV(to: systemURL)
        try writeManifest(
            manifest(sessionID: sessionID, microphoneSamples: 3, systemSamples: 3),
            to: directory
        )

        let bundle = try MeetingRecordingBundle.load(
            directoryURL: directory,
            supportDirectory: fixture.supportDirectory
        )

        #expect(bundle.microphoneURL == microphoneURL)
        #expect(bundle.systemURL == nil)
        #expect(bundle.degradations.contains(.sourceCorrupt(.system)))
    }

    @Test("manifest source path cannot escape its managed bundle")
    func rejectsRelativePathEscape() throws {
        let fixture = try MeetingRecordingBundleTestSupport()
        defer { fixture.cleanup() }
        let sessionID = UUID()
        let directory = fixture.bundleDirectory(sessionID: sessionID)
        var invalid = manifest(sessionID: sessionID, microphoneSamples: 3, systemSamples: 0)
        invalid.microphone.relativePath = "../outside.wav"
        try writeManifest(invalid, to: directory)

        #expect(throws: MeetingRecordingBundleError.self) {
            try MeetingRecordingBundle.load(
                directoryURL: directory,
                supportDirectory: fixture.supportDirectory
            )
        }
    }

    @Test("schema v1 ignores unknown fields and defaults documented optional metadata")
    func toleratesAdditiveAndOptionalFields() throws {
        let fixture = try MeetingRecordingBundleTestSupport()
        defer { fixture.cleanup() }
        let sessionID = UUID()
        let directory = fixture.bundleDirectory(sessionID: sessionID)
        let microphone = MeetingAudioTestFixtures.microphoneOnly().microphone
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(
            samples: microphone,
            to: directory.appendingPathComponent("mic-cleaned.wav")
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: encodedManifest(manifest(
                    sessionID: sessionID,
                    microphoneSamples: microphone.count,
                    systemSamples: 0
                ))
            ) as? [String: Any]
        )
        object["futureTopLevelField"] = ["enabled": true]
        object.removeValue(forKey: "recordingID")
        object.removeValue(forKey: "captureModelSnapshot")
        object.removeValue(forKey: "playback")
        if var microphoneObject = object["microphone"] as? [String: Any] {
            microphoneObject.removeValue(forKey: "contentDigest")
            microphoneObject["futureSourceField"] = "ignored"
            object["microphone"] = microphoneObject
        }
        try writeManifestObject(object, to: directory)

        let bundle = try MeetingRecordingBundle.load(
            directoryURL: directory,
            supportDirectory: fixture.supportDirectory
        )

        #expect(bundle.microphoneURL?.lastPathComponent == "mic-cleaned.wav")
        #expect(bundle.manifest.recordingID == nil)
        #expect(bundle.manifest.captureModelSnapshot == nil)
        #expect(bundle.manifest.playback == nil)
        #expect(bundle.manifest.microphone.contentDigest == nil)
    }

    @Test("digest mismatch invalidates only the changed source")
    func digestMismatchIsCorrupt() throws {
        let fixture = try MeetingRecordingBundleTestSupport()
        defer { fixture.cleanup() }
        let sessionID = UUID()
        let directory = fixture.bundleDirectory(sessionID: sessionID)
        let microphone = MeetingAudioTestFixtures.microphoneOnly().microphone
        let system = MeetingAudioTestFixtures.systemOnly().system
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(
            samples: microphone,
            to: directory.appendingPathComponent("mic-cleaned.wav")
        )
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(
            samples: system,
            to: directory.appendingPathComponent("system.wav")
        )
        var value = manifest(
            sessionID: sessionID,
            microphoneSamples: microphone.count,
            systemSamples: system.count
        )
        value.microphone.contentDigest = String(repeating: "0", count: 64)
        try writeManifest(value, to: directory)

        let bundle = try MeetingRecordingBundle.load(
            directoryURL: directory,
            supportDirectory: fixture.supportDirectory
        )

        #expect(bundle.microphoneURL == nil)
        #expect(bundle.systemURL != nil)
        #expect(bundle.degradations.contains(.sourceCorrupt(.microphone)))
        #expect(bundle.sourceState == .degraded)
    }

    @Test("future source schema falls back to playable mixed audio")
    func futureSchemaPreservesPlayback() throws {
        let fixture = try MeetingRecordingBundleTestSupport()
        defer { fixture.cleanup() }
        let playback = try fixture.makePlaybackFile(named: "future-playback.wav")
        let recording = MeetingRecordingRecord(
            id: 7,
            meetingID: 42,
            path: playback.path,
            createdAt: Date(timeIntervalSince1970: 1_000),
            deleteAfter: nil
        )
        let source = MeetingRecordingSourceBundleRecord(
            recordingID: recording.id,
            bundlePath: fixture.bundleDirectory(sessionID: UUID()).path,
            schemaVersion: 99,
            sourceState: .recoveryPending,
            createdAt: recording.createdAt
        )

        let inputs = try MeetingRecordingUnitResolver.resolve(
            units: [.init(recording: recording, sourceBundle: source)],
            supportDirectory: fixture.supportDirectory
        )

        guard case .legacyMixed(let legacy) = try #require(inputs.first) else {
            Issue.record("Expected a legacy playback fallback")
            return
        }
        #expect(legacy.playbackURL.standardizedFileURL == playback.standardizedFileURL)
        #expect(
            legacy.degradations.contains(.sourceBundleVersionUnsupported(99))
        )
        fixture.assertExists(playback)
    }

    private func manifest(
        sessionID: UUID,
        microphoneSamples: Int,
        systemSamples: Int
    ) -> MeetingRecordingBundleManifest {
        MeetingRecordingBundleManifest(
            schemaVersion: 1,
            meetingID: 42,
            recordingID: nil,
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_010),
            timelinePolicy: .activeCaptureCompacted,
            sampleRate: 16_000,
            channelsPerSource: 1,
            microphone: MeetingRecordingSourceDescriptor(
                role: .microphone,
                relativePath: "mic-cleaned.wav",
                sampleCount: microphoneSamples,
                encoding: .pcmS16LEWAV,
                availability: microphoneSamples == 0 ? .empty : .available,
                contentDigest: nil
            ),
            system: MeetingRecordingSourceDescriptor(
                role: .system,
                relativePath: "system.wav",
                sampleCount: systemSamples,
                encoding: .pcmS16LEWAV,
                availability: systemSamples == 0 ? .empty : .available,
                contentDigest: nil
            ),
            preprocessing: MeetingRecordingPreprocessingDescriptor.current,
            captureModelSnapshot: nil,
            playback: nil,
            rawAudio: nil
        )
    }

    private func writeManifest(
        _ manifest: MeetingRecordingBundleManifest,
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encodedManifest(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private func encodedManifest(
        _ manifest: MeetingRecordingBundleManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private func writeManifestObject(
        _ object: [String: Any],
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}
