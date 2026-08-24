import AVFoundation
import Foundation
import MuesliCore

enum MeetingRecordingFileFormat: String, CaseIterable, Sendable {
    case m4a
    case wav

    var displayName: String {
        switch self {
        case .m4a:
            return "M4A (AAC, smaller)"
        case .wav:
            return "WAV (lossless)"
        }
    }

    var fileExtension: String {
        switch self {
        case .m4a:
            return "m4a"
        case .wav:
            return "wav"
        }
    }

    static func resolved(_ rawValue: String) -> MeetingRecordingFileFormat {
        MeetingRecordingFileFormat(rawValue: rawValue) ?? .m4a
    }
}

struct MeetingSeparatedChannelFiles: Sendable {
    let microphoneURL: URL?
    let systemURL: URL?
    let microphoneSampleCount: Int
    let systemSampleCount: Int

    func removeTemporaryFiles(fileManager: FileManager = .default) {
        if let microphoneURL {
            try? fileManager.removeItem(at: microphoneURL)
        }
        if let systemURL {
            try? fileManager.removeItem(at: systemURL)
        }
    }
}

enum MeetingRecordingWriter {
    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    private final class TemporaryPCM16Writer {
        let url: URL
        let sampleRate: UInt32
        let channels: UInt16
        private var fileHandle: FileHandle?
        private(set) var frameCount = 0
        private var bytesWritten = 0

        init(
            directoryName: String,
            sampleRate: UInt32,
            channels: UInt16
        ) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            url = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav")
            self.sampleRate = sampleRate
            self.channels = channels
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: MeetingRecordingWriter.wavHeader(
                    dataSize: 0,
                    channels: channels,
                    sampleRate: sampleRate
                )
            ),
            let fileHandle = FileHandle(forWritingAtPath: url.path) else {
                throw NSError(
                    domain: "MeetingRecordingWriter",
                    code: 10,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not create a temporary meeting audio file."
                    ]
                )
            }
            self.fileHandle = fileHandle
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            fileHandle.seekToEndOfFile()
        }

        func append(interleaved samples: [Int16]) {
            guard !samples.isEmpty, samples.count.isMultiple(of: Int(channels)) else {
                return
            }
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            fileHandle?.write(data)
            bytesWritten += data.count
            frameCount += samples.count / Int(channels)
        }

        func finish() throws -> URL {
            guard let fileHandle else { return url }
            fileHandle.seek(toFileOffset: 0)
            fileHandle.write(MeetingRecordingWriter.wavHeader(
                dataSize: UInt32(clamping: bytesWritten),
                channels: channels,
                sampleRate: sampleRate
            ))
            try fileHandle.close()
            self.fileHandle = nil
            return url
        }

        func cancel() {
            try? fileHandle?.close()
            fileHandle = nil
            try? FileManager.default.removeItem(at: url)
        }

        deinit {
            try? fileHandle?.close()
        }
    }

    private struct MonoPCM16WAV {
        let sampleRate: UInt32
        let data: Data
        let dataRange: Range<Int>

        var sampleCount: Int {
            dataRange.count / MemoryLayout<Int16>.size
        }

        func sample(at index: Int) -> Int16 {
            let offset = dataRange.lowerBound + index * MemoryLayout<Int16>.size
            let bits = UInt16(data[offset])
                | (UInt16(data[offset + 1]) << 8)
            return Int16(bitPattern: bits)
        }
    }

    /// Creates a role-preserving playback/export artifact. Canonical raw source
    /// epochs live in the recording bundle; this file stores microphone on the
    /// left and system on the right. Shorter or unavailable sources are padded
    /// with silence, and the two roles are never summed or averaged.
    static func makeTemporarySeparatedRecording(
        microphoneURL: URL?,
        systemURL: URL?
    ) throws -> URL? {
        let microphone = try microphoneURL.map(readMonoPCM16WAV) ?? nil
        let system = try systemURL.map(readMonoPCM16WAV) ?? nil
        guard microphone != nil || system != nil else { return nil }

        let sampleRate = try resolvedSampleRate(
            microphone: microphone,
            system: system
        )
        let microphoneSampleCount = microphone?.sampleCount ?? 0
        let systemSampleCount = system?.sampleCount ?? 0
        let frameCount = max(microphoneSampleCount, systemSampleCount)
        guard frameCount > 0 else { return nil }

        let writer = try TemporaryPCM16Writer(
            directoryName: "muesli-meeting-recordings",
            sampleRate: sampleRate,
            channels: 2
        )
        do {
            let framesPerChunk = 16_384
            var frameStart = 0
            while frameStart < frameCount {
                let frameEnd = min(frameStart + framesPerChunk, frameCount)
                var interleaved = [Int16]()
                interleaved.reserveCapacity((frameEnd - frameStart) * 2)
                for frame in frameStart..<frameEnd {
                    interleaved.append(
                        frame < microphoneSampleCount
                            ? microphone?.sample(at: frame) ?? 0
                            : 0
                    )
                    interleaved.append(
                        frame < systemSampleCount
                            ? system?.sample(at: frame) ?? 0
                            : 0
                    )
                }
                writer.append(interleaved: interleaved)
                frameStart = frameEnd
            }
            return try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// Extracts role-preserving mono inputs from a retained two-channel file.
    /// This supports both WAV and M4A storage and is used only for processing;
    /// the extracted files are temporary and owned by the caller.
    static func extractSeparatedChannels(
        from recordingURL: URL,
        sourceLayout: MeetingRecordingSourceLayout,
        cancellationCheck: () throws -> Void = {}
    ) throws -> MeetingSeparatedChannelFiles {
        try cancellationCheck()
        let file = try AVAudioFile(
            forReading: recordingURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        guard format.channelCount >= 2,
              format.sampleRate > 0,
              format.sampleRate <= Double(UInt32.max) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 11,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The retained meeting recording does not contain two source channels."
                ]
            )
        }

        let sampleRate = UInt32(format.sampleRate.rounded())
        let microphoneWriter = sourceLayout.hasMicrophone
            ? try TemporaryPCM16Writer(
                directoryName: "muesli-meeting-channel-extraction",
                sampleRate: sampleRate,
                channels: 1
            )
            : nil
        let systemWriter = sourceLayout.hasSystem
            ? try TemporaryPCM16Writer(
                directoryName: "muesli-meeting-channel-extraction",
                sampleRate: sampleRate,
                channels: 1
            )
            : nil

        do {
            let capacity: AVAudioFrameCount = 16_384
            while file.framePosition < file.length {
                try cancellationCheck()
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: capacity
                ) else {
                    throw NSError(
                        domain: "MeetingRecordingWriter",
                        code: 12,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Could not allocate a meeting channel buffer."
                        ]
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
                    throw NSError(
                        domain: "MeetingRecordingWriter",
                        code: 13,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Could not decode retained meeting channels."
                        ]
                    )
                }
                if let microphoneWriter {
                    microphoneWriter.append(
                        interleaved: pcm16Samples(channelData[0], count: count)
                    )
                }
                if let systemWriter {
                    systemWriter.append(
                        interleaved: pcm16Samples(channelData[1], count: count)
                    )
                }
            }

            try cancellationCheck()
            let microphoneURL = try microphoneWriter?.finish()
            let systemURL = try systemWriter?.finish()
            return MeetingSeparatedChannelFiles(
                microphoneURL: microphoneURL,
                systemURL: systemURL,
                microphoneSampleCount: microphoneWriter?.frameCount ?? 0,
                systemSampleCount: systemWriter?.frameCount ?? 0
            )
        } catch {
            microphoneWriter?.cancel()
            systemWriter?.cancel()
            throw error
        }
    }

    /// Produces a temporary centered stereo rendering for the player. The
    /// retained recording is opened read-only and is never replaced.
    static func makeTemporaryCenteredPlayback(from recordingURL: URL) throws -> URL {
        let file = try AVAudioFile(
            forReading: recordingURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        guard format.channelCount >= 2,
              format.sampleRate > 0,
              format.sampleRate <= Double(UInt32.max) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 14,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Center mix is available only for two-channel meeting recordings."
                ]
            )
        }
        let writer = try TemporaryPCM16Writer(
            directoryName: "muesli-meeting-center-playback",
            sampleRate: UInt32(format.sampleRate.rounded()),
            channels: 2
        )

        do {
            let capacity: AVAudioFrameCount = 16_384
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: capacity
                ) else {
                    throw NSError(
                        domain: "MeetingRecordingWriter",
                        code: 15,
                        userInfo: [NSLocalizedDescriptionKey: "Could not allocate a playback buffer."]
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
                guard let channels = buffer.floatChannelData else {
                    throw NSError(
                        domain: "MeetingRecordingWriter",
                        code: 16,
                        userInfo: [NSLocalizedDescriptionKey: "Could not decode playback channels."]
                    )
                }
                var centered = [Int16]()
                centered.reserveCapacity(count * 2)
                for index in 0..<count {
                    let sample = pcm16Sample(
                        (channels[0][index] + channels[1][index]) * 0.5
                    )
                    centered.append(sample)
                    centered.append(sample)
                }
                writer.append(interleaved: centered)
            }
            return try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
    }

    static func persistTemporaryRecordingAsync(
        from tempURL: URL,
        meetingTitle: String,
        startedAt: Date,
        supportDirectory: URL,
        fileFormat: MeetingRecordingFileFormat = .m4a
    ) async throws -> URL {
        let recordingsDirectory = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = availableDestinationURL(
            in: recordingsDirectory,
            fileNamePrefix: fileNamePrefix(for: startedAt, title: meetingTitle),
            fileExtension: fileFormat.fileExtension
        )
        switch fileFormat {
        case .m4a:
            do {
                try await transcodeWAVToM4AAsync(
                    sourceURL: tempURL,
                    destinationURL: destinationURL
                )
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        case .wav:
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
        return destinationURL
    }

    private static func resolvedSampleRate(
        microphone: MonoPCM16WAV?,
        system: MonoPCM16WAV?
    ) throws -> UInt32 {
        if let microphone, let system, microphone.sampleRate != system.sampleRate {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 17,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Microphone and system meeting sources use different sample rates."
                ]
            )
        }
        return microphone?.sampleRate ?? system?.sampleRate ?? WavWriter.sampleRate
    }

    private static func availableDestinationURL(
        in directory: URL,
        fileNamePrefix: String,
        fileExtension: String
    ) -> URL {
        let fileManager = FileManager.default
        var suffix = 1
        while true {
            let numberedSuffix = suffix == 1 ? "" : "-\(suffix)"
            let candidate = directory.appendingPathComponent(
                "\(fileNamePrefix)\(numberedSuffix).\(fileExtension)"
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func fileNamePrefix(for date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let timestamp = formatter.string(from: date)

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let normalized = title.unicodeScalars.map {
            allowed.contains($0) ? String($0) : " "
        }.joined()
        let slug = normalized
            .split(whereSeparator: \.isWhitespace)
            .prefix(6)
            .joined(separator: "-")
            .lowercased()

        return slug.isEmpty ? timestamp : "\(timestamp)-\(slug)"
    }

    private static func readMonoPCM16WAV(from url: URL) throws -> MonoPCM16WAV {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 12,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw invalidCanonicalWAVError()
        }

        var sampleRate: UInt32?
        var channels: UInt16?
        var audioFormat: UInt16?
        var bitsPerSample: UInt16?
        var dataRange: Range<Int>?
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            guard let chunkSize = readUInt32(data, at: offset + 4) else { break }
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + Int(chunkSize)
            guard payloadEnd <= data.count else {
                throw NSError(
                    domain: "MeetingRecordingWriter",
                    code: 18,
                    userInfo: [NSLocalizedDescriptionKey: "The canonical meeting WAV is truncated."]
                )
            }
            if chunkID == "fmt ", Int(chunkSize) >= 16 {
                audioFormat = readUInt16(data, at: payloadStart)
                channels = readUInt16(data, at: payloadStart + 2)
                sampleRate = readUInt32(data, at: payloadStart + 4)
                bitsPerSample = readUInt16(data, at: payloadStart + 14)
            } else if chunkID == "data" {
                dataRange = payloadStart..<payloadEnd
            }
            offset = payloadEnd + (Int(chunkSize) % 2)
        }

        guard audioFormat == 1,
              channels == 1,
              bitsPerSample == 16,
              let sampleRate,
              let dataRange,
              dataRange.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw invalidCanonicalWAVError()
        }
        return MonoPCM16WAV(
            sampleRate: sampleRate,
            data: data,
            dataRange: dataRange
        )
    }

    private static func invalidCanonicalWAVError() -> NSError {
        NSError(
            domain: "MeetingRecordingWriter",
            code: 19,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The canonical meeting source is not a mono PCM16 WAV file."
            ]
        )
    }

    private static func pcm16Samples(
        _ samples: UnsafePointer<Float>,
        count: Int
    ) -> [Int16] {
        (0..<count).map { pcm16Sample(samples[$0]) }
    }

    private static func pcm16Sample(_ sample: Float) -> Int16 {
        let clamped = max(-1, min(1, sample))
        if clamped <= -1 {
            return .min
        }
        return Int16((clamped * Float(Int16.max)).rounded())
    }

    private static func transcodeWAVToM4AAsync(
        sourceURL: URL,
        destinationURL: URL
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not create M4A export session for meeting recording."
                ]
            )
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .m4a
        let exportSessionBox = ExportSessionBox(exportSession)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            exportSessionBox.session.exportAsynchronously {
                guard exportSessionBox.session.status == .completed else {
                    continuation.resume(throwing: exportSessionBox.session.error ?? NSError(
                        domain: "MeetingRecordingWriter",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Could not export meeting recording as M4A."
                        ]
                    ))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private static func wavHeader(
        dataSize: UInt32,
        channels: UInt16,
        sampleRate: UInt32
    ) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let (chunkSize, overflow) = dataSize.addingReportingOverflow(36)

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(
            of: (overflow ? UInt32.max : chunkSize).littleEndian
        ) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        return header
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
