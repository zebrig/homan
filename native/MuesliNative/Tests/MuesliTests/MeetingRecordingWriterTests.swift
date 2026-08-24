import AVFoundation
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("MeetingRecordingWriter")
struct MeetingRecordingWriterTests {
    @Test("retained recording preserves microphone left and system right without mixing")
    func separatedRecordingPreservesSources() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = try writeWAV(
            [1_000, 2_000, 3_000, 4_000],
            named: "mic.wav",
            in: directory
        )
        let system = try writeWAV(
            [3_000, -2_000],
            named: "system.wav",
            in: directory
        )

        let retained = try #require(
            try MeetingRecordingWriter.makeTemporarySeparatedRecording(
                microphoneURL: microphone,
                systemURL: system
            )
        )
        defer { try? FileManager.default.removeItem(at: retained) }

        let channels = try readStereoPCM16WAVSamples(from: retained)
        #expect(channels.left == [1_000, 2_000, 3_000, 4_000])
        #expect(channels.right == [3_000, -2_000, 0, 0])
    }

    @Test("one available source is retained in its assigned channel")
    func separatedRecordingPreservesSingleSourceRole() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = try writeWAV(
            [.max, .min, 0, 1_200],
            named: "mic.wav",
            in: directory
        )

        let retained = try #require(
            try MeetingRecordingWriter.makeTemporarySeparatedRecording(
                microphoneURL: microphone,
                systemURL: nil
            )
        )
        defer { try? FileManager.default.removeItem(at: retained) }

        let channels = try readStereoPCM16WAVSamples(from: retained)
        #expect(channels.left == [.max, .min, 0, 1_200])
        #expect(channels.right == [0, 0, 0, 0])
        #expect(try MeetingRecordingWriter.makeTemporarySeparatedRecording(
            microphoneURL: nil,
            systemURL: nil
        ) == nil)
    }

    @Test("WAV persistence keeps the two source channels bit-for-bit")
    func wavPersistencePreservesSeparatedChannels() async throws {
        let supportDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let microphone = try writeWAV(
            [1_200, -800, 400],
            named: "mic.wav",
            in: supportDirectory
        )
        let system = try writeWAV(
            [-1_000, 700, 200],
            named: "system.wav",
            in: supportDirectory
        )
        let temporary = try #require(
            try MeetingRecordingWriter.makeTemporarySeparatedRecording(
                microphoneURL: microphone,
                systemURL: system
            )
        )

        let saved = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: temporary,
            meetingTitle: "Weekly Product Sync! With Very Long Title Extra Words",
            startedAt: Date(timeIntervalSince1970: 1_711_000_000),
            supportDirectory: supportDirectory,
            fileFormat: .wav
        )

        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(saved.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(saved.lastPathComponent.hasSuffix("-weekly-product-sync-with-very-long.wav"))
        let channels = try readStereoPCM16WAVSamples(from: saved)
        #expect(channels.left == [1_200, -800, 400])
        #expect(channels.right == [-1_000, 700, 200])
    }

    @Test("M4A persistence and extraction retain distinct source roles")
    func m4aPersistencePreservesSeparatedChannels() async throws {
        let supportDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let microphone = try writeWAV(
            Array(repeating: Int16(4_000), count: 16_000),
            named: "mic.wav",
            in: supportDirectory
        )
        let system = try writeWAV(
            Array(repeating: Int16(-4_000), count: 16_000),
            named: "system.wav",
            in: supportDirectory
        )
        let temporary = try #require(
            try MeetingRecordingWriter.makeTemporarySeparatedRecording(
                microphoneURL: microphone,
                systemURL: system
            )
        )

        let saved = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: temporary,
            meetingTitle: "Separated M4A",
            startedAt: Date(timeIntervalSince1970: 1_711_000_000),
            supportDirectory: supportDirectory,
            fileFormat: .m4a
        )
        let audioFile = try AVAudioFile(forReading: saved)
        #expect(audioFile.processingFormat.channelCount == 2)

        let extracted = try MeetingRecordingWriter.extractSeparatedChannels(
            from: saved,
            sourceLayout: .separateStereoMicrophoneAndSystem
        )
        defer { extracted.removeTemporaryFiles() }
        let extractedMicrophone = try #require(extracted.microphoneURL)
        let extractedSystem = try #require(extracted.systemURL)
        let microphoneSamples = try WavReader.readFloatMonoWAV(
            from: extractedMicrophone
        ).samples
        let systemSamples = try WavReader.readFloatMonoWAV(
            from: extractedSystem
        ).samples

        #expect(extracted.microphoneSampleCount > 0)
        #expect(extracted.systemSampleCount > 0)
        #expect(mean(microphoneSamples) > 0.05)
        #expect(mean(systemSamples) < -0.05)
    }

    @Test("separated channel extraction observes cancellation between bounded blocks")
    func separatedExtractionIsCancellable() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = [Int16](repeating: 2_000, count: 40_000)
        let microphone = try writeWAV(samples, named: "mic.wav", in: directory)
        let system = try writeWAV(samples, named: "system.wav", in: directory)
        let retained = try #require(
            try MeetingRecordingWriter.makeTemporarySeparatedRecording(
                microphoneURL: microphone,
                systemURL: system
            )
        )
        defer { try? FileManager.default.removeItem(at: retained) }
        var checkpointCount = 0

        #expect(throws: CancellationError.self) {
            _ = try MeetingRecordingWriter.extractSeparatedChannels(
                from: retained,
                sourceLayout: .separateStereoMicrophoneAndSystem,
                cancellationCheck: {
                    checkpointCount += 1
                    if checkpointCount == 3 {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(checkpointCount == 3)
    }

    @Test("center playback is temporary and leaves retained channels unchanged")
    func centeredPlaybackDoesNotModifySource() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = try writeWAV(
            [1_000, 2_000, 3_000],
            named: "mic.wav",
            in: directory
        )
        let system = try writeWAV(
            [3_000, -2_000, 1_000],
            named: "system.wav",
            in: directory
        )
        let retained = try #require(
            try MeetingRecordingWriter.makeTemporarySeparatedRecording(
                microphoneURL: microphone,
                systemURL: system
            )
        )
        defer { try? FileManager.default.removeItem(at: retained) }
        let sourceBefore = try Data(contentsOf: retained)

        let centered = try MeetingRecordingWriter.makeTemporaryCenteredPlayback(
            from: retained
        )
        defer { try? FileManager.default.removeItem(at: centered) }

        let centeredChannels = try readStereoPCM16WAVSamples(from: centered)
        #expect(centeredChannels.left == centeredChannels.right)
        #expect(try Data(contentsOf: retained) == sourceBefore)
    }

    @Test("persisting the same meeting twice preserves both recordings")
    func duplicateDestinationPreservesBothRecordings() async throws {
        let supportDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        func temporaryRecording(_ value: Int16) throws -> URL {
            let mic = try writeWAV(
                [value, value],
                named: "\(UUID().uuidString).wav",
                in: supportDirectory
            )
            return try #require(
                try MeetingRecordingWriter.makeTemporarySeparatedRecording(
                    microphoneURL: mic,
                    systemURL: nil
                )
            )
        }

        let firstSaved = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: try temporaryRecording(100),
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            supportDirectory: supportDirectory,
            fileFormat: .wav
        )
        let secondSaved = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: try temporaryRecording(300),
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            supportDirectory: supportDirectory,
            fileFormat: .wav
        )

        #expect(firstSaved != secondSaved)
        #expect(secondSaved.deletingPathExtension().lastPathComponent.hasSuffix("-2"))
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-writer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readStereoPCM16WAVSamples(
        from url: URL
    ) throws -> (left: [Int16], right: [Int16]) {
        let data = try Data(contentsOf: url)
        #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        #expect(UInt16(data[22]) | (UInt16(data[23]) << 8) == 2)
        let sampleBytes = data.subdata(in: 44..<data.count)
        let interleaved = sampleBytes.withUnsafeBytes { rawBuffer in
            rawBuffer.bindMemory(to: Int16.self).map(Int16.init(littleEndian:))
        }
        var left: [Int16] = []
        var right: [Int16] = []
        for frame in stride(from: 0, to: interleaved.count - 1, by: 2) {
            left.append(interleaved[frame])
            right.append(interleaved[frame + 1])
        }
        return (left, right)
    }

    private func writeWAV(
        _ samples: [Int16],
        named name: String,
        in directory: URL
    ) throws -> URL {
        try MeetingAudioTestFixtures.writeMonoPCM16WAV(
            samples: samples,
            to: directory.appendingPathComponent(name)
        )
    }

    private func mean(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Float(samples.count)
    }
}
