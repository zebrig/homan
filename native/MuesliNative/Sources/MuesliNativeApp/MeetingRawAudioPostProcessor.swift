@preconcurrency import AVFoundation
import Foundation
import MuesliCore

enum MeetingRawAudioPostProcessorError: Error, LocalizedError {
    case unsupportedDerivedFormat(String)
    case unreadableDerivedAudio(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDerivedFormat(let path):
            return "The derived raw meeting audio has an unsupported format: \(path)"
        case .unreadableDerivedAudio(let path):
            return "The derived raw meeting audio could not be read: \(path)"
        }
    }
}

struct MeetingPreparedRawAudio: Sendable {
    let microphoneURL: URL?
    let systemURL: URL?
    let microphoneSampleCount: Int
    let systemSampleCount: Int
    let sampleRate: Int

    func removeTemporaryFiles(fileManager: FileManager = .default) {
        if let microphoneURL {
            try? fileManager.removeItem(at: microphoneURL)
        }
        if let systemURL {
            try? fileManager.removeItem(at: systemURL)
        }
    }
}

/// Builds disposable 16 kHz processing sources from immutable raw capture.
///
/// The system source is used only as the far-end reference. AEC may change the
/// microphone-derived source, but it never changes the system-derived source or
/// any canonical raw payload.
enum MeetingRawAudioPostProcessor {
    /// Keep post-capture AEC work interruptible. 4,096 frames are exactly
    /// divisible by both bundled processor frame sizes (256 and 512), while
    /// limiting the interval before a newly-started recording can preempt this
    /// background work to roughly a quarter second of source audio.
    private static let processingBlockFrames: AVAudioFrameCount = 4_096

    static func prepare(
        _ rawAudio: MeetingStagedRawAudio,
        aec: MeetingNeuralAec,
        supportDirectory: URL,
        inferenceScheduler: MeetingInferenceScheduler = .shared
    ) async throws -> MeetingStagedAudio {
        let manifest = rawAudio.manifest
        let prepared = try await renderProcessingView(
            rawAudio,
            aec: aec,
            inferenceScheduler: inferenceScheduler
        )
        defer { prepared.removeTemporaryFiles() }
        let derived = try MeetingProcessingCapture(
            meetingID: manifest.meetingID,
            sessionID: manifest.sessionID,
            startedAt: manifest.startedAt,
            finalModelID: manifest.finalModelID,
            cohereLanguage: manifest.cohereLanguage.flatMap(CohereTranscribeLanguage.init(rawValue:)),
            indicASRLanguage: manifest.indicASRLanguage.flatMap(IndicASRLanguage.init(rawValue:)),
            nemotron35Language: manifest.nemotron35Language.flatMap(Nemotron35Language.init(rawValue:)),
            finalDiarizationEnabled: manifest.finalDiarizationEnabled,
            finalDiarizationProfileID: manifest.finalDiarizationProfileID,
            supportDirectory: supportDirectory
        )

        do {
            try appendPCM16WAV(
                at: prepared.microphoneURL,
                expectedSamples: prepared.microphoneSampleCount,
                append: derived.appendMicrophone
            )
            try appendPCM16WAV(
                at: prepared.systemURL,
                expectedSamples: prepared.systemSampleCount,
                append: derived.appendSystem
            )
            return try derived.finalize(
                endedAt: manifest.endedAt ?? Date()
            )
        } catch {
            derived.discard()
            throw error
        }
    }

    static func renderProcessingView(
        _ rawAudio: MeetingStagedRawAudio,
        aec: MeetingNeuralAec,
        inferenceScheduler: MeetingInferenceScheduler = .shared
    ) async throws -> MeetingPreparedRawAudio {
        try await inferenceScheduler.waitUntilCaptureAllowsInference()
        try Task.checkCancellation()
        let rendered = try MeetingRawAudioRenderer.renderForProcessing(rawAudio)
        var microphoneWriter: PCMChunkRecorder?
        do {
            try await inferenceScheduler.waitUntilCaptureAllowsInference()
            await aec.preload()
            try await inferenceScheduler.waitUntilCaptureAllowsInference()
            try Task.checkCancellation()
            aec.resetForStreaming()

            let microphoneReader = try rendered.microphoneURL.map(MonoFloatReader.init(url:))
            let systemReader = try rendered.systemURL.map(MonoFloatReader.init(url:))
            if microphoneReader != nil {
                microphoneWriter = try PCMChunkRecorder(
                    directoryName: "muesli-meeting-post-aec"
                )
            }
            let targetFrames = rendered.timelineFrameCount
            var processedFrames = 0
            var microphoneSamplesWritten = 0

            while processedFrames < targetFrames {
                try await inferenceScheduler.waitUntilCaptureAllowsInference()
                try Task.checkCancellation()
                let requestedFrames = min(
                    Int(processingBlockFrames),
                    targetFrames - processedFrames
                )
                let systemSamples = try readPadded(
                    from: systemReader,
                    count: requestedFrames
                )
                aec.feedSystemSamples(systemSamples)

                if let microphoneReader {
                    let microphoneSamples = try readPadded(
                        from: microphoneReader,
                        count: requestedFrames
                    )
                    let cleaned = aec.processStreamingMic(microphoneSamples)
                    let int16 = cleaned.map(pcm16Sample)
                    microphoneWriter?.append(int16)
                    microphoneSamplesWritten += int16.count
                }
                processedFrames += requestedFrames
            }

            if microphoneReader != nil {
                try await inferenceScheduler.waitUntilCaptureAllowsInference()
                try Task.checkCancellation()
                let flushed = aec.flushStreamingMic().map(pcm16Sample)
                microphoneWriter?.append(flushed)
                microphoneSamplesWritten += flushed.count
            }
            let microphoneURL = microphoneWriter?.stop()
            microphoneWriter = nil
            if let rawMicrophoneURL = rendered.microphoneURL {
                try? FileManager.default.removeItem(at: rawMicrophoneURL)
            }
            return MeetingPreparedRawAudio(
                microphoneURL: microphoneURL,
                systemURL: rendered.systemURL,
                microphoneSampleCount: microphoneSamplesWritten,
                systemSampleCount: systemReader == nil ? 0 : targetFrames,
                sampleRate: rendered.sampleRate
            )
        } catch {
            microphoneWriter?.cancel()
            rendered.removeTemporaryFiles()
            throw error
        }
    }

    private static func readPadded(
        from reader: MonoFloatReader?,
        count: Int
    ) throws -> [Float] {
        guard let reader else {
            return [Float](repeating: 0, count: count)
        }
        var samples = try reader.read(maximumFrameCount: count)
        if samples.count < count {
            samples.append(
                contentsOf: repeatElement(0, count: count - samples.count)
            )
        }
        return samples
    }

    private static func pcm16Sample(_ sample: Float) -> Int16 {
        let clamped = max(-1, min(1, sample))
        if clamped <= -1 { return .min }
        return Int16((clamped * Float(Int16.max)).rounded())
    }

    private static func appendPCM16WAV(
        at url: URL?,
        expectedSamples: Int,
        append: ([Int16]) -> Void
    ) throws {
        guard expectedSamples > 0, let url else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 44)
        var appendedSamples = 0
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
                throw MeetingRawAudioPostProcessorError.unreadableDerivedAudio(
                    url.lastPathComponent
                )
            }
            let samples = data.withUnsafeBytes {
                Array($0.bindMemory(to: Int16.self))
            }
            append(samples)
            appendedSamples += samples.count
        }
        guard appendedSamples == expectedSamples else {
            throw MeetingRawAudioPostProcessorError.unreadableDerivedAudio(
                url.lastPathComponent
            )
        }
    }

    private final class MonoFloatReader {
        private let file: AVAudioFile
        private let format: AVAudioFormat

        init(url: URL) throws {
            file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            format = file.processingFormat
            guard format.channelCount == 1,
                  abs(format.sampleRate - Double(MeetingRawAudioRenderer.targetSampleRate)) < 0.5 else {
                throw MeetingRawAudioPostProcessorError.unsupportedDerivedFormat(
                    url.lastPathComponent
                )
            }
        }

        func read(maximumFrameCount: Int) throws -> [Float] {
            guard maximumFrameCount > 0, file.framePosition < file.length else {
                return []
            }
            let frameCount = AVAudioFrameCount(
                min(Int64(maximumFrameCount), file.length - file.framePosition)
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            ) else {
                throw MeetingRawAudioPostProcessorError.unreadableDerivedAudio(
                    file.url.lastPathComponent
                )
            }
            try file.read(into: buffer, frameCount: frameCount)
            guard let channel = buffer.floatChannelData?[0] else {
                throw MeetingRawAudioPostProcessorError.unreadableDerivedAudio(
                    file.url.lastPathComponent
                )
            }
            return Array(UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            ))
        }
    }
}
