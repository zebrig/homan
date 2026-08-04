import AVFoundation
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Raw meeting audio capture")
struct MeetingRawAudioCaptureTests {
    @Test("Preserves source formats and starts epochs at timeline gaps")
    func preservesFormatsAndTimelineGaps() throws {
        let support = try temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let capture = try makeCapture(
            support: support,
            anchor: 1_000_000_000,
            compactLosslessly: false
        )

        capture.append(
            floatChunk(
                frames: [[0.1, 0.2], [0.3, 0.4]],
                sampleRate: 48_000,
                timestamp: 1_000_000_000
            ),
            role: .microphone
        )
        capture.append(
            int16Chunk(
                samples: [10, 20, 30],
                sampleRate: 16_000,
                timestamp: 1_000_000_000
            ),
            role: .system
        )
        capture.append(
            floatChunk(
                frames: [[0.5, 0.6], [0.7, 0.8]],
                sampleRate: 48_000,
                timestamp: 2_000_000_000
            ),
            role: .microphone
        )

        let staged = try capture.finalize(endedAt: Date(timeIntervalSince1970: 2))
        #expect(staged.manifest.schemaVersion == 2)
        #expect(staged.manifest.microphoneEpochs.count == 2)
        #expect(staged.manifest.systemEpochs.count == 1)
        #expect(staged.manifest.microphoneEpochs[0].format.channelCount == 2)
        #expect(staged.manifest.microphoneEpochs[0].format.sampleRate == 48_000)
        #expect(staged.manifest.microphoneEpochs[1].startOffsetNanoseconds == 1_000_000_000)
        #expect(staged.manifest.systemEpochs[0].format.sampleRepresentation == .signedInt16)

        let firstMic = try Data(
            contentsOf: staged.payloadURL(for: staged.manifest.microphoneEpochs[0])
        )
        let samples = firstMic.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        #expect(samples == [0.1, 0.2, 0.3, 0.4])
    }

    @Test("Recovers complete PCM frames after interruption")
    func recoversInterruptedPCM() throws {
        let support = try temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let capture = try makeCapture(
            support: support,
            anchor: 5_000,
            compactLosslessly: false
        )
        capture.append(
            int16Chunk(
                samples: [1, 2, 3, 4],
                sampleRate: 16_000,
                timestamp: 5_000
            ),
            role: .microphone
        )
        let checkpoint = try capture.checkpoint()
        capture.interruptForTesting()

        let recovered = try MeetingRawAudioCapture.recover(
            directoryURL: checkpoint.directoryURL,
            supportDirectory: support
        )
        #expect(recovered.manifest.state == .captureComplete)
        #expect(recovered.manifest.microphoneEpochs.count == 1)
        #expect(recovered.manifest.microphoneEpochs[0].frameCount == 4)
        #expect(recovered.manifest.microphoneEpochs[0].state == .closedPCM)
    }

    @Test("Compacts a closed PCM segment to verified Apple Lossless")
    func compactsToALAC() throws {
        let support = try temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let capture = try makeCapture(
            support: support,
            anchor: 100,
            compactLosslessly: true
        )
        let samples = (0..<8_000).map {
            Int16(sin(Double($0) / 20) * Double(Int16.max) * 0.2)
        }
        capture.append(
            int16Chunk(samples: samples, sampleRate: 16_000, timestamp: 100),
            role: .microphone
        )

        let staged = try capture.finalize(endedAt: Date())
        let epoch = try #require(staged.manifest.microphoneEpochs.first)
        #expect(epoch.encoding == .appleLossless)
        #expect(epoch.state == .verifiedALAC)
        #expect(epoch.frameCount == samples.count)
        #expect(epoch.relativePath.hasSuffix(".caf"))
        #expect(FileManager.default.fileExists(atPath: staged.payloadURL(for: epoch).path))

        let file = try AVAudioFile(forReading: staged.payloadURL(for: epoch))
        #expect(
            file.fileFormat.streamDescription.pointee.mFormatID
                == kAudioFormatAppleLossless
        )
        #expect(file.length == AVAudioFramePosition(samples.count))
    }

    private func makeCapture(
        support: URL,
        anchor: UInt64,
        compactLosslessly: Bool
    ) throws -> MeetingRawAudioCapture {
        try MeetingRawAudioCapture(
            meetingID: 42,
            startedAt: Date(timeIntervalSince1970: 1),
            timelineAnchorNanoseconds: anchor,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: support,
            compactLosslessly: compactLosslessly
        )
    }

    private func int16Chunk(
        samples: [Int16],
        sampleRate: Double,
        timestamp: UInt64
    ) -> CapturedAudioChunk {
        CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: sampleRate,
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

    private func floatChunk(
        frames: [[Float]],
        sampleRate: Double,
        timestamp: UInt64
    ) -> CapturedAudioChunk {
        let channelCount = frames.first?.count ?? 0
        let interleaved = frames.flatMap { $0 }
        return CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: sampleRate,
                channelCount: channelCount,
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
                    channelCount: channelCount,
                    data: interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
                ),
            ]
        )
    }

    private func temporarySupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-raw-capture-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
