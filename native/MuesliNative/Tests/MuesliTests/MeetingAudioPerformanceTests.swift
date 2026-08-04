import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting audio performance contract", .serialized)
struct MeetingAudioPerformanceTests {
    @Test("ten-minute canonical capture stays file-backed with exact sample counts")
    func longCaptureIsFileBacked() throws {
        let support = try MeetingRecordingBundleTestSupport(testName: "audio-performance")
        defer { support.cleanup() }
        let capture = try MeetingProcessingCapture(
            meetingID: 42,
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000),
            finalModelID: BackendOption.parakeetMultilingual.asrModelID,
            supportDirectory: support.supportDirectory
        )
        let oneSecond = MeetingAudioTestFixtures.tone(
            sampleCount: MeetingProcessingCapture.sampleRate,
            amplitude: 1_000,
            period: 80
        )
        let seconds = 10 * 60

        for _ in 0..<seconds {
            capture.appendMicrophone(oneSecond)
            capture.appendSystem(oneSecond)
        }

        // Canonical capture writes directly into two WAVs. It must not create
        // retained media from a real-time callback.
        #expect(!FileManager.default.fileExists(atPath: support.recordingsRoot.path))
        let staged = try capture.finalize(
            endedAt: Date(timeIntervalSince1970: 1_000 + Double(seconds))
        )
        let expectedSamples = seconds * MeetingProcessingCapture.sampleRate
        let expectedFileBytes = 44 + expectedSamples * MemoryLayout<Int16>.size

        #expect(staged.manifest.microphoneSampleCount == expectedSamples)
        #expect(staged.manifest.systemSampleCount == expectedSamples)
        #expect(fileSize(staged.microphoneURL) == expectedFileBytes)
        #expect(fileSize(staged.systemURL) == expectedFileBytes)
        #expect(fileSize(staged.manifestURL) < 4_096)
        let separated = try #require(
            try MeetingRecordingWriter.makeTemporarySeparatedRecording(
                microphoneURL: staged.microphoneURL,
                systemURL: staged.systemURL
            )
        )
        defer { try? FileManager.default.removeItem(at: separated) }
        let header = try Data(contentsOf: separated, options: .mappedIfSafe)
        #expect(UInt16(header[22]) | (UInt16(header[23]) << 8) == 2)
        #expect(fileSize(separated) == 44 + expectedSamples * 2 * MemoryLayout<Int16>.size)
        #expect(
            MeetingChunkedLiveQueue.maximumQueuedChunks == 2,
            "Live preview work must remain bounded independently of capture duration"
        )
    }

    @Test("native stereo journals rotate and compact without retaining PCM")
    func nativeStereoJournalsCompactLosslessly() throws {
        let support = try MeetingRecordingBundleTestSupport(
            testName: "raw-audio-performance"
        )
        defer { support.cleanup() }

        let sampleRate = 48_000
        let channels = 2
        let seconds = 20
        let framesPerChunk = 4_800
        let chunkCount = seconds * sampleRate / framesPerChunk
        let anchor: UInt64 = 10_000_000_000
        let format = CapturedAudioFormat(
            sampleRate: Double(sampleRate),
            channelCount: channels,
            sampleRepresentation: .signedInt16,
            interleaved: true
        )
        var samples: [Int16] = []
        samples.reserveCapacity(framesPerChunk * channels)
        for frame in 0..<framesPerChunk {
            let value = Int16(
                sin(Double(frame) * 2 * .pi / 240) * Double(Int16.max) * 0.2
            )
            samples.append(value)
            samples.append(value / 2)
        }
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let capture = try MeetingRawAudioCapture(
            meetingID: 84,
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 2_000),
            timelineAnchorNanoseconds: anchor,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: support.supportDirectory,
            segmentDuration: 2
        )

        for index in 0..<chunkCount {
            let timestamp = anchor
                + UInt64(index * framesPerChunk) * 1_000_000_000
                    / UInt64(sampleRate)
            let chunk = CapturedAudioChunk(
                format: format,
                frameCount: framesPerChunk,
                timestamp: CapturedAudioTimestamp(
                    monotonicNanoseconds: timestamp,
                    origin: .sourceHostClock
                ),
                planes: [
                    CapturedAudioPlane(
                        channelCount: channels,
                        data: payload
                    ),
                ]
            )
            capture.append(chunk, role: .microphone)
            capture.append(chunk, role: .system)
        }

        let staged = try capture.finalize(
            endedAt: Date(timeIntervalSince1970: 2_000 + Double(seconds))
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let epochs = staged.epochs
        let retainedBytes = epochs.reduce(0) {
            $0 + fileSize(staged.payloadURL(for: $1))
        }
        let uncompressedBytes = seconds * sampleRate * channels
            * MemoryLayout<Int16>.size * 2

        #expect(!epochs.isEmpty)
        #expect(
            epochs.allSatisfy {
                $0.encoding == .appleLossless && $0.state == .verifiedALAC
            }
        )
        #expect(
            epochs.allSatisfy {
                staged.payloadURL(for: $0).pathExtension == "caf"
            }
        )
        #expect(retainedBytes > 0)
        #expect(retainedBytes < uncompressedBytes)
        #expect(
            epochs.reduce(0) { $0 + $1.frameCount }
                == seconds * sampleRate * 2
        )
        print(
            "[raw-audio-performance] duration=\(seconds)s "
                + "elapsed=\(String(format: "%.3f", elapsed))s "
                + "retained=\(retainedBytes)B pcm=\(uncompressedBytes)B "
                + "ratio=\(String(format: "%.3f", Double(retainedBytes) / Double(uncompressedBytes)))"
        )
    }

    private func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes?[.size] as? NSNumber)?.intValue ?? -1
    }
}
