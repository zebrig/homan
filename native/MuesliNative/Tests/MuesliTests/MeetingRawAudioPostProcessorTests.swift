import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Raw meeting post processor")
struct MeetingRawAudioPostProcessorTests {
    @Test("AEC changes only the disposable microphone source")
    func directionalAec() async throws {
        let support = try temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let capture = try MeetingRawAudioCapture(
            meetingID: 91,
            startedAt: Date(),
            timelineAnchorNanoseconds: 1_000,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: support,
            compactLosslessly: false
        )
        capture.append(
            chunk(samples: [16_384, 16_384], timestamp: 1_000),
            role: .microphone
        )
        capture.append(
            chunk(samples: [8_192, 8_192], timestamp: 1_000),
            role: .system
        )
        let raw = try capture.finalize(endedAt: Date())
        let processor = DirectionalAecProcessor()
        let staged = try await MeetingRawAudioPostProcessor.prepare(
            raw,
            aec: MeetingNeuralAec(preloadedProcessor: processor),
            supportDirectory: support
        )
        defer { MeetingProcessingCapture.discard(staged) }

        let microphone = try wavSamples(staged.microphoneURL)
        let system = try wavSamples(staged.systemURL)
        #expect(microphone.count == 2)
        #expect(system.count == 2)
        #expect(abs(Int(microphone[0]) - 8_192) <= 2)
        #expect(abs(Int(system[0]) - 8_192) <= 1)
        #expect(processor.nonZeroReferenceFrames == 1)
    }

    private func chunk(
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

    private func wavSamples(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        return data.dropFirst(44).withUnsafeBytes {
            Array($0.bindMemory(to: Int16.self))
        }
    }

    private func temporarySupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-raw-post-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

private final class DirectionalAecProcessor: MeetingAecProcessor {
    let name = "test-directional"
    let frameSize = 2
    let sampleRate = 16_000
    private(set) var nonZeroReferenceFrames = 0

    func reset() {}

    func processFrame(mic: [Float], reference: [Float]) throws -> [Float] {
        if reference.contains(where: { abs($0) > 0.0001 }) {
            nonZeroReferenceFrames += 1
        }
        return zip(mic, reference).map(-)
    }
}
