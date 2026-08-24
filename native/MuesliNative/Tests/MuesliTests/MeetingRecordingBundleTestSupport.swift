import Foundation
import Testing
@testable import MuesliNativeApp

struct MeetingRecordingBundleTestSupport {
    let supportDirectory: URL

    init(testName: String = "meeting-recording-bundle") throws {
        supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(testName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
    }

    var processingRoot: URL {
        supportDirectory.appendingPathComponent("Meeting Processing", isDirectory: true)
    }

    var rawProcessingRoot: URL {
        supportDirectory.appendingPathComponent(
            MeetingRawAudioCapture.directoryName,
            isDirectory: true
        )
    }

    var recordingsRoot: URL {
        supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
    }

    var sourceBundlesRoot: URL {
        recordingsRoot.appendingPathComponent("sources", isDirectory: true)
    }

    func bundleDirectory(sessionID: UUID) -> URL {
        sourceBundlesRoot.appendingPathComponent(
            sessionID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    func makePlaybackFile(named name: String = "playback.wav") throws -> URL {
        let url = recordingsRoot.appendingPathComponent(name)
        return try MeetingAudioTestFixtures.writeMonoPCM16WAV(
            samples: MeetingAudioTestFixtures.tone(
                sampleCount: 320,
                amplitude: 2_000,
                period: 32
            ),
            to: url
        )
    }

    func makeSeparatedPlaybackFile(
        named name: String = "separated-playback.wav"
    ) throws -> URL {
        let microphoneURL = supportDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased())-microphone.wav"
        )
        let systemURL = supportDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased())-system.wav"
        )
        defer {
            try? FileManager.default.removeItem(at: microphoneURL)
            try? FileManager.default.removeItem(at: systemURL)
        }
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
        let destination = recordingsRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: recordingsRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    func assertExists(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(FileManager.default.fileExists(atPath: url.path), sourceLocation: sourceLocation)
    }

    func assertMissing(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!FileManager.default.fileExists(atPath: url.path), sourceLocation: sourceLocation)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: supportDirectory)
    }
}
