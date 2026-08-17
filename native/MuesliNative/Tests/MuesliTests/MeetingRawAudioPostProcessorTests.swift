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

    @Test("cancellation stops post-AEC processing and leaves raw capture recoverable")
    func cancellationStopsPostProcessing() async throws {
        let support = try temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let capture = try MeetingRawAudioCapture(
            meetingID: 92,
            startedAt: Date(),
            timelineAnchorNanoseconds: 1_000,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: support,
            compactLosslessly: false
        )
        let samples = [Int16](repeating: 4_096, count: 16_000 * 4)
        capture.append(chunk(samples: samples, timestamp: 1_000), role: .microphone)
        capture.append(chunk(samples: samples, timestamp: 1_000), role: .system)
        let raw = try capture.finalize(endedAt: Date())
        let processor = SlowCancellationAecProcessor()

        let task = Task {
            try await MeetingRawAudioPostProcessor.prepare(
                raw,
                aec: MeetingNeuralAec(preloadedProcessor: processor),
                supportDirectory: support
            )
        }
        while processor.processedFrameCount == 0 {
            await Task.yield()
        }
        task.cancel()

        do {
            let staged = try await task.value
            MeetingProcessingCapture.discard(staged)
            Issue.record("Expected post-processing cancellation")
        } catch is CancellationError {
            // Expected: cancellation is observed between bounded AEC blocks.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(processor.processedFrameCount < samples.count / processor.frameSize)
        #expect(FileManager.default.fileExists(atPath: raw.manifestURL.path))
    }

    @Test("a new capture preempts post-AEC before native inference starts")
    func capturePreemptsPostProcessing() async throws {
        let support = try temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let capture = try MeetingRawAudioCapture(
            meetingID: 93,
            startedAt: Date(),
            timelineAnchorNanoseconds: 1_000,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: support,
            compactLosslessly: false
        )
        let samples = [Int16](repeating: 4_096, count: 16_000)
        capture.append(chunk(samples: samples, timestamp: 1_000), role: .microphone)
        capture.append(chunk(samples: samples, timestamp: 1_000), role: .system)
        let raw = try capture.finalize(endedAt: Date())
        let processor = SlowCancellationAecProcessor()
        let scheduler = MeetingInferenceScheduler()
        let captureOwner = UUID()
        scheduler.beginCapture(ownerID: captureOwner)

        let task = Task {
            try await MeetingRawAudioPostProcessor.prepare(
                raw,
                aec: MeetingNeuralAec(preloadedProcessor: processor),
                supportDirectory: support,
                inferenceScheduler: scheduler
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(processor.processedFrameCount == 0)

        scheduler.endCapture(ownerID: captureOwner)
        let staged = try await task.value
        MeetingProcessingCapture.discard(staged)
        #expect(processor.processedFrameCount > 0)
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

private final class SlowCancellationAecProcessor: MeetingAecProcessor, @unchecked Sendable {
    let name = "test-slow-cancellation"
    let frameSize = 256
    let sampleRate = 16_000
    private let lock = NSLock()
    private var _processedFrameCount = 0

    var processedFrameCount: Int {
        lock.withLock { _processedFrameCount }
    }

    func reset() {}

    func processFrame(mic: [Float], reference: [Float]) throws -> [Float] {
        lock.withLock { _processedFrameCount += 1 }
        Thread.sleep(forTimeInterval: 0.001)
        return mic
    }
}
