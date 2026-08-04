import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Captured audio chunks")
struct CapturedAudioChunkTests {
    @Test("Planar channels interleave without changing samples")
    func planarInterleave() throws {
        let left: [Int16] = [1, 2, 3]
        let right: [Int16] = [101, 102, 103]
        let chunk = CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: 48_000,
                channelCount: 2,
                sampleRepresentation: .signedInt16,
                interleaved: false
            ),
            frameCount: 3,
            timestamp: CapturedAudioTimestamp(
                monotonicNanoseconds: 10_000,
                origin: .sourceHostClock
            ),
            planes: [
                CapturedAudioPlane(channelCount: 1, data: data(left)),
                CapturedAudioPlane(channelCount: 1, data: data(right)),
            ]
        )

        let interleaved = try chunk.interleavedPCMData()
        let samples = interleaved.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples == [1, 101, 2, 102, 3, 103])
    }

    @Test("One interleaved plane is returned unchanged")
    func interleavedPassThrough() throws {
        let samples: [Float] = [0.1, -0.1, 0.2, -0.2]
        let payload = data(samples)
        let chunk = CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: 44_100,
                channelCount: 2,
                sampleRepresentation: .float32,
                interleaved: true
            ),
            frameCount: 2,
            timestamp: CapturedAudioTimestamp(
                monotonicNanoseconds: 2_000,
                origin: .estimatedAtCallback
            ),
            planes: [CapturedAudioPlane(channelCount: 2, data: payload)]
        )

        #expect(try chunk.interleavedPCMData() == payload)
    }

    @Test("Invalid payload size is rejected")
    func invalidPayload() {
        let chunk = CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: 48_000,
                channelCount: 1,
                sampleRepresentation: .signedInt16,
                interleaved: true
            ),
            frameCount: 2,
            timestamp: CapturedAudioTimestamp(
                monotonicNanoseconds: 0,
                origin: .sourceHostClock
            ),
            planes: [CapturedAudioPlane(channelCount: 1, data: Data([1, 2]))]
        )

        #expect(throws: CapturedAudioChunkError.payloadSizeMismatch(expected: 4, actual: 2)) {
            try chunk.validate()
        }
    }

    @Test("Timestamp offsets preserve early and late callbacks")
    func timestampOffsets() {
        let late = CapturedAudioTimestamp(
            monotonicNanoseconds: 1_250,
            origin: .sourceHostClock
        )
        let early = CapturedAudioTimestamp(
            monotonicNanoseconds: 750,
            origin: .sourceHostClock
        )

        #expect(late.offsetNanoseconds(since: 1_000) == 250)
        #expect(early.offsetNanoseconds(since: 1_000) == -250)
    }

    @Test("Input signal detection rejects digital silence and accepts microphone noise")
    func inputSignalDetection() {
        let timestamp = CapturedAudioTimestamp(
            monotonicNanoseconds: 1_000,
            origin: .sourceHostClock
        )
        let silent = CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: 48_000,
                channelCount: 1,
                sampleRepresentation: .float32,
                interleaved: true
            ),
            frameCount: 3,
            timestamp: timestamp,
            planes: [CapturedAudioPlane(channelCount: 1, data: data([Float](repeating: 0, count: 3)))]
        )
        let noisy = CapturedAudioChunk(
            format: silent.format,
            frameCount: 3,
            timestamp: timestamp,
            planes: [CapturedAudioPlane(channelCount: 1, data: data([Float(0), Float(0.0002), Float(0)]))]
        )

        #expect(!silent.containsInputSignal())
        #expect(noisy.containsInputSignal())
    }

    private func data<T>(_ values: [T]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
