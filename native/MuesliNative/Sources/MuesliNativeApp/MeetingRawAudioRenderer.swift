@preconcurrency import AVFoundation
import Foundation

struct MeetingRenderedRawAudio: Sendable {
    let microphoneURL: URL?
    let systemURL: URL?
    let timelineFrameCount: Int
    let microphoneSourceFrameCount: Int
    let systemSourceFrameCount: Int
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

/// A disposable system-only render used by the meeting-global diarization
/// timeline. Keeping this separate avoids running microphone AEC (or even
/// decoding microphone epochs) merely to analyze remote speakers.
struct MeetingRenderedRawSystemAudio: Sendable {
    let url: URL?
    let timelineFrameCount: Int
    let sourceFrameCount: Int
    let sampleRate: Int

    func removeTemporaryFile(fileManager: FileManager = .default) {
        if let url {
            try? fileManager.removeItem(at: url)
        }
    }
}

enum MeetingRawAudioRendererError: Error, LocalizedError {
    case unsafePayloadPath(String)
    case missingPayload(String)
    case incompletePCMFrame(String)
    case unsupportedFormat(String)
    case writerFailure(String)

    var errorDescription: String? {
        switch self {
        case .unsafePayloadPath(let path):
            return "The raw meeting payload path is unsafe: \(path)"
        case .missingPayload(let path):
            return "The raw meeting payload is missing: \(path)"
        case .incompletePCMFrame(let path):
            return "The raw meeting PCM payload ends with an incomplete frame: \(path)"
        case .unsupportedFormat(let reason):
            return "The raw meeting audio format is unsupported: \(reason)"
        case .writerFailure(let reason):
            return "Could not create derived meeting audio: \(reason)"
        }
    }
}

/// Renders immutable raw source epochs into disposable mono PCM16 views for
/// AEC, ASR, playback, or export. Canonical payloads are opened read-only.
enum MeetingRawAudioRenderer {
    static let targetSampleRate = 16_000

    static func renderForProcessing(
        _ stagedAudio: MeetingStagedRawAudio,
        fileManager: FileManager = .default
    ) throws -> MeetingRenderedRawAudio {
        let targetFrames = max(
            0,
            Int(
                (
                    Double(stagedAudio.manifest.timelineDurationNanoseconds)
                        / 1_000_000_000
                        * Double(targetSampleRate)
                ).rounded(.up)
            )
        )
        let microphone = try render(
            epochs: stagedAudio.manifest.microphoneEpochs,
            directoryURL: stagedAudio.directoryURL,
            targetTimelineFrames: targetFrames,
            role: .microphone,
            fileManager: fileManager
        )
        do {
            let system = try render(
                epochs: stagedAudio.manifest.systemEpochs,
                directoryURL: stagedAudio.directoryURL,
                targetTimelineFrames: targetFrames,
                role: .system,
                fileManager: fileManager
            )
            return MeetingRenderedRawAudio(
                microphoneURL: microphone.url,
                systemURL: system.url,
                timelineFrameCount: targetFrames,
                microphoneSourceFrameCount: microphone.sourceFrameCount,
                systemSourceFrameCount: system.sourceFrameCount,
                sampleRate: targetSampleRate
            )
        } catch {
            if let url = microphone.url {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    static func renderSystemForProcessing(
        _ stagedAudio: MeetingStagedRawAudio,
        fileManager: FileManager = .default
    ) throws -> MeetingRenderedRawSystemAudio {
        let targetFrames = max(
            0,
            Int(
                (
                    Double(stagedAudio.manifest.timelineDurationNanoseconds)
                        / 1_000_000_000
                        * Double(targetSampleRate)
                ).rounded(.up)
            )
        )
        let system = try render(
            epochs: stagedAudio.manifest.systemEpochs,
            directoryURL: stagedAudio.directoryURL,
            targetTimelineFrames: targetFrames,
            role: .system,
            fileManager: fileManager
        )
        return MeetingRenderedRawSystemAudio(
            url: system.url,
            timelineFrameCount: targetFrames,
            sourceFrameCount: system.sourceFrameCount,
            sampleRate: targetSampleRate
        )
    }

    static func decodeEpochToMonoFloat(
        _ epoch: MeetingRawAudioEpoch,
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> [Float] {
        let url = try payloadURL(
            epoch: epoch,
            directoryURL: directoryURL,
            fileManager: fileManager
        )
        switch epoch.encoding {
        case .pcmJournal:
            return try decodePCMToMono(epoch: epoch, url: url)
        case .appleLossless:
            return try decodeAudioFileToMono(epoch: epoch, url: url)
        }
    }

    private struct RenderedRole {
        let url: URL?
        let sourceFrameCount: Int
    }

    private static func render(
        epochs: [MeetingRawAudioEpoch],
        directoryURL: URL,
        targetTimelineFrames: Int,
        role: MeetingAudioSourceRole,
        fileManager: FileManager
    ) throws -> RenderedRole {
        let validEpochs = epochs
            .filter { $0.frameCount > 0 }
            .sorted {
                if $0.startOffsetNanoseconds == $1.startOffsetNanoseconds {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.startOffsetNanoseconds < $1.startOffsetNanoseconds
            }
        guard !validEpochs.isEmpty else {
            return RenderedRole(url: nil, sourceFrameCount: 0)
        }

        let writer = try PCM16WAVWriter(
            directoryName: "muesli-meeting-raw-render",
            sampleRate: targetSampleRate
        )
        var outputFrame = 0
        var sourceFrames = 0
        do {
            for epoch in validEpochs {
                let mono = try decodeEpochToMonoFloat(
                    epoch,
                    in: directoryURL,
                    fileManager: fileManager
                )
                let resampled = linearResample(
                    mono,
                    from: epoch.format.sampleRate,
                    to: Double(targetSampleRate)
                )
                sourceFrames += resampled.count
                let desiredStart = max(
                    0,
                    Int(
                        (
                            Double(epoch.startOffsetNanoseconds)
                                / 1_000_000_000
                                * Double(targetSampleRate)
                        ).rounded()
                    )
                )
                if desiredStart > outputFrame {
                    try writer.appendSilence(
                        frames: desiredStart - outputFrame
                    )
                    outputFrame = desiredStart
                }
                let overlap = max(0, outputFrame - desiredStart)
                if overlap < resampled.count {
                    let samples = resampled.dropFirst(overlap).map(pcm16Sample)
                    try writer.append(samples: samples)
                    outputFrame += samples.count
                }
            }
            if targetTimelineFrames > outputFrame {
                try writer.appendSilence(
                    frames: targetTimelineFrames - outputFrame
                )
            }
            return RenderedRole(
                url: try writer.finish(),
                sourceFrameCount: sourceFrames
            )
        } catch {
            writer.cancel()
            throw error
        }
    }

    private static func payloadURL(
        epoch: MeetingRawAudioEpoch,
        directoryURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let relativePath = epoch.relativePath
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              URL(fileURLWithPath: relativePath)
                .pathComponents
                .allSatisfy({ $0 != ".." }) else {
            throw MeetingRawAudioRendererError.unsafePayloadPath(relativePath)
        }
        let directory = directoryURL.standardizedFileURL
        let url = directory.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/") else {
            throw MeetingRawAudioRendererError.unsafePayloadPath(relativePath)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw MeetingRawAudioRendererError.missingPayload(relativePath)
        }
        return url
    }

    private static func decodePCMToMono(
        epoch: MeetingRawAudioEpoch,
        url: URL
    ) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let bytesPerFrame = epoch.format.bytesPerFrame
        guard bytesPerFrame > 0, data.count.isMultiple(of: bytesPerFrame) else {
            throw MeetingRawAudioRendererError.incompletePCMFrame(
                epoch.relativePath
            )
        }
        let frameCount = min(epoch.frameCount, data.count / bytesPerFrame)
        let channels = epoch.format.channelCount
        guard channels > 0 else {
            throw MeetingRawAudioRendererError.unsupportedFormat(
                "zero channels in \(epoch.relativePath)"
            )
        }
        return data.withUnsafeBytes { rawBuffer -> [Float] in
            var mono = [Float]()
            mono.reserveCapacity(frameCount)
            switch epoch.format.sampleRepresentation {
            case .float32:
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        let index = frame * channels + channel
                        sum += rawBuffer.loadUnaligned(
                            fromByteOffset: index * MemoryLayout<Float>.size,
                            as: Float.self
                        )
                    }
                    mono.append(sum / Float(channels))
                }
            case .signedInt16:
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        let index = frame * channels + channel
                        let sample = rawBuffer.loadUnaligned(
                            fromByteOffset: index * MemoryLayout<Int16>.size,
                            as: Int16.self
                        )
                        sum += Float(sample) / 32768
                    }
                    mono.append(sum / Float(channels))
                }
            }
            return mono
        }
    }

    private static func decodeAudioFileToMono(
        epoch: MeetingRawAudioEpoch,
        url: URL
    ) throws -> [Float] {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        guard format.channelCount > 0 else {
            throw MeetingRawAudioRendererError.unsupportedFormat(
                "zero channels in \(epoch.relativePath)"
            )
        }
        var mono = [Float]()
        mono.reserveCapacity(Int(file.length))
        let capacity: AVAudioFrameCount = 16_384
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: capacity
            ) else {
                throw MeetingRawAudioRendererError.unsupportedFormat(
                    "could not allocate decoder buffer"
                )
            }
            try file.read(
                into: buffer,
                frameCount: AVAudioFrameCount(
                    min(Int64(capacity), file.length - file.framePosition)
                )
            )
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            guard let channelData = buffer.floatChannelData else {
                throw MeetingRawAudioRendererError.unsupportedFormat(
                    "decoder did not provide Float32 channels"
                )
            }
            let channels = Int(format.channelCount)
            for frame in 0..<count {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += channelData[channel][frame]
                }
                mono.append(sum / Float(channels))
            }
        }
        if mono.count > epoch.frameCount {
            mono.removeLast(mono.count - epoch.frameCount)
        }
        return mono
    }

    private static func linearResample(
        _ samples: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        if abs(sourceRate - targetRate) < 0.5 {
            return samples
        }
        let outputCount = max(
            1,
            Int((Double(samples.count) * targetRate / sourceRate).rounded())
        )
        let step = sourceRate / targetRate
        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = min(
                Double(samples.count - 1),
                Double(index) * step
            )
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            output[index] = samples[lower]
                + (samples[upper] - samples[lower]) * fraction
        }
        return output
    }

    private static func pcm16Sample(_ sample: Float) -> Int16 {
        let clamped = max(-1, min(1, sample))
        if clamped <= -1 { return .min }
        return Int16((clamped * Float(Int16.max)).rounded())
    }

    private final class PCM16WAVWriter {
        let url: URL
        private var handle: FileHandle?
        private var bytesWritten = 0

        init(directoryName: String, sampleRate: Int) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            url = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav")
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Self.wavHeader(dataSize: 0, sampleRate: sampleRate),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw MeetingRawAudioRendererError.writerFailure(
                    "could not create \(url.lastPathComponent)"
                )
            }
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
            self.sampleRate = sampleRate
        }

        private let sampleRate: Int

        func append(samples: [Int16]) throws {
            guard !samples.isEmpty else { return }
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            guard let handle else {
                throw MeetingRawAudioRendererError.writerFailure(
                    "the derived writer was already closed"
                )
            }
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        }

        func appendSilence(frames: Int) throws {
            guard frames > 0 else { return }
            let block = [Int16](repeating: 0, count: min(frames, 16_384))
            var remaining = frames
            while remaining > 0 {
                try append(
                    samples: Array(
                        block.prefix(min(remaining, block.count))
                    )
                )
                remaining -= min(remaining, block.count)
            }
        }

        func finish() throws -> URL {
            guard let handle else { return url }
            try handle.seek(toOffset: 0)
            try handle.write(
                contentsOf: Self.wavHeader(
                    dataSize: UInt32(clamping: bytesWritten),
                    sampleRate: sampleRate
                )
            )
            try handle.synchronize()
            try handle.close()
            self.handle = nil
            return url
        }

        func cancel() {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
        }

        deinit {
            try? handle?.close()
        }

        private static func wavHeader(dataSize: UInt32, sampleRate: Int) -> Data {
            var data = Data()
            func append<T>(_ value: T) {
                withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: "RIFF".utf8)
            append((dataSize &+ 36).littleEndian)
            data.append(contentsOf: "WAVEfmt ".utf8)
            append(UInt32(16).littleEndian)
            append(UInt16(1).littleEndian)
            append(UInt16(1).littleEndian)
            append(UInt32(sampleRate).littleEndian)
            append(UInt32(sampleRate * 2).littleEndian)
            append(UInt16(2).littleEndian)
            append(UInt16(16).littleEndian)
            data.append(contentsOf: "data".utf8)
            append(dataSize.littleEndian)
            return data
        }
    }
}
