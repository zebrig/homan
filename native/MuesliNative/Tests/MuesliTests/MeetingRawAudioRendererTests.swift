import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Raw meeting audio renderer")
struct MeetingRawAudioRendererTests {
    @Test("Renders source gaps as silence without compacting the timeline")
    func preservesGaps() throws {
        let support = try temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let capture = try MeetingRawAudioCapture(
            meetingID: 1,
            startedAt: Date(),
            timelineAnchorNanoseconds: 1_000,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: support,
            compactLosslessly: false
        )
        capture.append(
            int16Chunk(
                samples: [1_000, 2_000],
                timestamp: 1_000
            ),
            role: .microphone
        )
        capture.append(
            int16Chunk(
                samples: [3_000, 4_000],
                timestamp: 1_000_001_000
            ),
            role: .microphone
        )
        let staged = try capture.finalize(endedAt: Date())
        let rendered = try MeetingRawAudioRenderer.renderForProcessing(staged)
        defer { rendered.removeTemporaryFiles() }
        let samples = try wavSamples(try #require(rendered.microphoneURL))

        #expect(samples[0] == 1_000)
        #expect(samples[1] == 2_000)
        #expect(samples[2..<16_000].allSatisfy { $0 == 0 })
        #expect(samples[16_000] == 3_000)
        #expect(samples[16_001] == 4_000)
    }

    @Test("Downmixes channels only in the disposable processing view")
    func downmixesDerivedView() throws {
        let support = try temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let capture = try MeetingRawAudioCapture(
            meetingID: 2,
            startedAt: Date(),
            timelineAnchorNanoseconds: 5_000,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: support,
            compactLosslessly: true
        )
        capture.append(
            stereoFloatChunk(
                frames: [[0.4, 0.2], [-0.4, -0.2]],
                timestamp: 5_000
            ),
            role: .system
        )
        let staged = try capture.finalize(endedAt: Date())
        let canonical = try Data(
            contentsOf: staged.payloadURL(
                for: try #require(staged.manifest.systemEpochs.first)
            )
        )
        let rendered = try MeetingRawAudioRenderer.renderForProcessing(staged)
        defer { rendered.removeTemporaryFiles() }
        let samples = try wavSamples(try #require(rendered.systemURL))
        let canonicalAfter = try Data(
            contentsOf: staged.payloadURL(
                for: try #require(staged.manifest.systemEpochs.first)
            )
        )

        #expect(abs(Int(samples[0]) - 9_830) <= 2)
        #expect(abs(Int(samples[1]) + 9_830) <= 2)
        #expect(canonicalAfter == canonical)
    }

    private func int16Chunk(
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

    private func stereoFloatChunk(
        frames: [[Float]],
        timestamp: UInt64
    ) -> CapturedAudioChunk {
        let samples = frames.flatMap { $0 }
        return CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: 16_000,
                channelCount: 2,
                sampleRepresentation: .float32,
                interleaved: true
            ),
            frameCount: frames.count,
            timestamp: CapturedAudioTimestamp(
                monotonicNanoseconds: timestamp,
                origin: .sourceHostClock
            ),
            planes: [
                CapturedAudioPlane(
                    channelCount: 2,
                    data: samples.withUnsafeBufferPointer { Data(buffer: $0) }
                ),
            ]
        )
    }

    private func wavSamples(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        return data.dropFirst(44).withUnsafeBytes {
            Array($0.bindMemory(to: Int16.self))
        }
    }

    private func temporarySupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-raw-renderer-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
