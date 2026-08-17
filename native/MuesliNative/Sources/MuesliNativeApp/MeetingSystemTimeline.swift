@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import MuesliCore

enum MeetingSystemTimelineError: Error, LocalizedError {
    case noSystemAudio
    case invalidAudio(String)
    case timelineTooLong

    var errorDescription: String? {
        switch self {
        case .noSystemAudio:
            return "No retained system audio is available for speaker analysis."
        case .invalidAudio(let name):
            return "The system audio could not be rendered for speaker analysis: \(name)"
        case .timelineTooLong:
            return "The meeting system-audio timeline is too long for a WAV processing view."
        }
    }
}

struct MeetingSystemTimelineAudioSource: Sendable {
    let unitID: String
    let startedAt: Date
    let url: URL
    let sourceFingerprint: String
}

struct MeetingRenderedSystemTimeline: Sendable {
    let url: URL
    let map: MeetingSystemTimelineMap

    func removeTemporaryFile(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }
}

/// Creates one sparse, file-backed system-only clock for an entire meeting.
/// Canonical media is opened read-only. Gaps are represented as sparse zero
/// ranges, so a long pause does not allocate an equivalent in-memory buffer.
enum MeetingSystemTimelineRenderer {
    static let sampleRate = 16_000

    static func render(
        units: [MeetingRecordingUnitInput],
        meetingStart: Date,
        leaseRegistry: MeetingRecordingLeaseRegistry = .shared
    ) throws -> MeetingRenderedSystemTimeline {
        let ordered = units.sorted {
            if $0.createdAt == $1.createdAt { return $0.stableOrder < $1.stableOrder }
            return $0.createdAt < $1.createdAt
        }
        let writer = try SparsePCM16WAVWriter()
        var entries: [MeetingSystemTimelineMapEntry] = []

        do {
            for (index, unit) in ordered.enumerated() {
                try Task.checkCancellation()
                let prepared = try prepare(unit, leaseRegistry: leaseRegistry)
                guard let prepared else { continue }

                let requestedStart = max(
                    0,
                    Int((unit.createdAt.timeIntervalSince(meetingStart) * Double(sampleRate)).rounded())
                )
                let previousEnd = writer.frameCount
                let actualStart = max(previousEnd, requestedStart)
                if actualStart > previousEnd {
                    try writer.appendSparseSilence(frames: actualStart - previousEnd)
                }
                let appended: Int
                do {
                    appended = try writer.appendAudioFile(at: prepared.url)
                    prepared.cleanup()
                } catch {
                    prepared.cleanup()
                    throw error
                }
                guard appended > 0 else { continue }
                let actualEnd = actualStart + appended
                let boundary: MeetingSystemTimelineMapEntry.BoundaryKind
                if entries.isEmpty {
                    boundary = .first
                } else if requestedStart > previousEnd {
                    boundary = .explicitGap
                } else if requestedStart < previousEnd {
                    boundary = .overlapCompacted
                } else {
                    boundary = .continuous
                }
                entries.append(MeetingSystemTimelineMapEntry(
                    unitID: prepared.unitID.isEmpty
                        ? String(format: "unit-%04d", index)
                        : prepared.unitID,
                    sourceFingerprint: prepared.sourceFingerprint,
                    unitStartSeconds: 0,
                    unitEndSeconds: Double(appended) / Double(sampleRate),
                    globalStartSeconds: Double(actualStart) / Double(sampleRate),
                    globalEndSeconds: Double(actualEnd) / Double(sampleRate),
                    boundaryKind: boundary
                ))
            }
            guard !entries.isEmpty else {
                writer.cancel()
                throw MeetingSystemTimelineError.noSystemAudio
            }
            let url = try writer.finish()
            return MeetingRenderedSystemTimeline(
                url: url,
                map: MeetingSystemTimelineMap(
                    totalDurationSeconds: Double(writer.frameCount) / Double(sampleRate),
                    entries: entries
                )
            )
        } catch {
            writer.cancel()
            throw error
        }
    }

    static func render(
        sources: [MeetingSystemTimelineAudioSource],
        meetingStart: Date
    ) throws -> MeetingRenderedSystemTimeline {
        let writer = try SparsePCM16WAVWriter()
        var entries: [MeetingSystemTimelineMapEntry] = []
        do {
            for source in sources.sorted(by: {
                if $0.startedAt == $1.startedAt { return $0.unitID < $1.unitID }
                return $0.startedAt < $1.startedAt
            }) {
                try Task.checkCancellation()
                let requestedStart = max(
                    0,
                    Int((source.startedAt.timeIntervalSince(meetingStart) * Double(sampleRate)).rounded())
                )
                let actualStart = max(writer.frameCount, requestedStart)
                if actualStart > writer.frameCount {
                    try writer.appendSparseSilence(frames: actualStart - writer.frameCount)
                }
                let appended = try writer.appendAudioFile(at: source.url)
                guard appended > 0 else { continue }
                let boundary: MeetingSystemTimelineMapEntry.BoundaryKind
                if entries.isEmpty { boundary = .first }
                else if requestedStart > entries.lastGlobalEndFrame { boundary = .explicitGap }
                else if requestedStart < actualStart { boundary = .overlapCompacted }
                else { boundary = .continuous }
                entries.append(MeetingSystemTimelineMapEntry(
                    unitID: source.unitID,
                    sourceFingerprint: source.sourceFingerprint,
                    unitStartSeconds: 0,
                    unitEndSeconds: Double(appended) / Double(sampleRate),
                    globalStartSeconds: Double(actualStart) / Double(sampleRate),
                    globalEndSeconds: Double(actualStart + appended) / Double(sampleRate),
                    boundaryKind: boundary
                ))
            }
            guard !entries.isEmpty else {
                writer.cancel()
                throw MeetingSystemTimelineError.noSystemAudio
            }
            let url = try writer.finish()
            return MeetingRenderedSystemTimeline(
                url: url,
                map: MeetingSystemTimelineMap(
                    totalDurationSeconds: Double(writer.frameCount) / Double(sampleRate),
                    entries: entries
                )
            )
        } catch {
            writer.cancel()
            throw error
        }
    }

    static func fingerprintFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct PreparedSource {
        let unitID: String
        let url: URL
        let sourceFingerprint: String
        let cleanup: () -> Void
    }

    private static func prepare(
        _ unit: MeetingRecordingUnitInput,
        leaseRegistry: MeetingRecordingLeaseRegistry
    ) throws -> PreparedSource? {
        switch unit {
        case .sourceBundle(let input):
            let bundle = input.bundle
            let unitID = bundle.manifest.sessionID.uuidString.lowercased()
            let leaseKey = input.recording.map { MeetingRecordingLeaseKey.recordingID($0.id) }
                ?? .sessionID(bundle.manifest.sessionID)
            guard let lease = leaseRegistry.acquireRead(for: leaseKey) else { return nil }
            if let raw = bundle.rawAudio {
                do {
                    let rendered = try MeetingRawAudioRenderer.renderSystemForProcessing(raw)
                    guard let url = rendered.url, rendered.sourceFrameCount > 0 else {
                        rendered.removeTemporaryFile()
                        lease.release()
                        return nil
                    }
                    let fingerprint = rawSystemFingerprint(raw)
                    return PreparedSource(
                        unitID: unitID,
                        url: url,
                        sourceFingerprint: fingerprint,
                        cleanup: {
                            rendered.removeTemporaryFile()
                            lease.release()
                        }
                    )
                } catch {
                    lease.release()
                    throw error
                }
            }
            guard let url = bundle.systemURL,
                  bundle.manifest.system.sampleCount > 0 else {
                lease.release()
                return nil
            }
            let fingerprint: String
            if let recordedDigest = bundle.manifest.system.contentDigest {
                fingerprint = recordedDigest
            } else {
                fingerprint = try fingerprintFile(at: url)
            }
            return PreparedSource(
                unitID: unitID,
                url: url,
                sourceFingerprint: "bundle-v1|\(fingerprint)",
                cleanup: { lease.release() }
            )

        case .separatedChannels(let input):
            guard input.sourceLayout.hasSystem,
                  let lease = leaseRegistry.acquireRead(for: .recordingID(input.recording.id)) else {
                return nil
            }
            do {
                let extracted = try MeetingRecordingWriter.extractSeparatedChannels(
                    from: input.recordingURL,
                    sourceLayout: input.sourceLayout
                )
                guard let url = extracted.systemURL, extracted.systemSampleCount > 0 else {
                    extracted.removeTemporaryFiles()
                    lease.release()
                    return nil
                }
                let fingerprint = try fingerprintFile(at: input.recordingURL)
                return PreparedSource(
                    unitID: "recording-\(input.recording.id)",
                    url: url,
                    sourceFingerprint: "separated-v1|system|\(fingerprint)",
                    cleanup: {
                        extracted.removeTemporaryFiles()
                        lease.release()
                    }
                )
            } catch {
                lease.release()
                throw error
            }

        case .legacyMixed(let input):
            guard let lease = leaseRegistry.acquireRead(for: .recordingID(input.recording.id)) else {
                return nil
            }
            do {
                let fingerprint = try fingerprintFile(at: input.playbackURL)
                return PreparedSource(
                    unitID: "recording-\(input.recording.id)",
                    url: input.playbackURL,
                    sourceFingerprint: "legacy-mixed-v1|\(fingerprint)",
                    cleanup: { lease.release() }
                )
            } catch {
                lease.release()
                throw error
            }
        }
    }

    private static func rawSystemFingerprint(_ raw: MeetingStagedRawAudio) -> String {
        let epochs = raw.manifest.systemEpochs.sorted {
            if $0.startOffsetNanoseconds == $1.startOffsetNanoseconds {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.startOffsetNanoseconds < $1.startOffsetNanoseconds
        }
        let parts = epochs.map { epoch in
            let digest = epoch.contentDigest
                ?? ((try? fingerprintFile(at: raw.payloadURL(for: epoch))) ?? "missing")
            return "\(epoch.id.uuidString.lowercased())|\(epoch.startOffsetNanoseconds)|\(epoch.frameCount)|\(digest)"
        }
        return MeetingTranscriptDigest.text(
            "raw-system-v2|\(raw.manifest.timelineDurationNanoseconds)|\(parts.joined(separator: ";"))"
        )
    }
}

private extension Array where Element == MeetingSystemTimelineMapEntry {
    var lastGlobalEndFrame: Int {
        guard let end = last?.globalEndSeconds else { return 0 }
        return Int((end * Double(MeetingSystemTimelineRenderer.sampleRate)).rounded())
    }
}

private final class SparsePCM16WAVWriter {
    let url: URL
    private var handle: FileHandle?
    private(set) var frameCount = 0

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-meeting-system-timeline", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Self.header(dataBytes: 0),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw MeetingSystemTimelineError.invalidAudio(url.lastPathComponent)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    func appendSparseSilence(frames: Int) throws {
        guard frames > 0, let handle else { return }
        let newFrames = frameCount + frames
        guard Int64(newFrames) * 2 <= Int64(UInt32.max) else {
            throw MeetingSystemTimelineError.timelineTooLong
        }
        let targetOffset = UInt64(44 + newFrames * 2)
        try handle.seek(toOffset: targetOffset - 2)
        try handle.write(contentsOf: Data([0, 0]))
        frameCount = newFrames
    }

    @discardableResult
    func appendAudioFile(at url: URL) throws -> Int {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let inputFormat = file.processingFormat
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw MeetingSystemTimelineError.invalidAudio(url.lastPathComponent)
        }
        if abs(inputFormat.sampleRate - Double(MeetingSystemTimelineRenderer.sampleRate)) < 0.5 {
            return try appendWithoutResampling(file: file, format: inputFormat)
        }
        return try appendWithConverter(file: file, inputFormat: inputFormat)
    }

    func finish() throws -> URL {
        guard let handle else { return url }
        let dataBytes = frameCount * 2
        guard dataBytes <= Int(UInt32.max) else {
            throw MeetingSystemTimelineError.timelineTooLong
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: UInt32(dataBytes)))
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

    deinit { try? handle?.close() }

    private func appendWithoutResampling(
        file: AVAudioFile,
        format: AVAudioFormat
    ) throws -> Int {
        var appended = 0
        let capacity: AVAudioFrameCount = 16_384
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw MeetingSystemTimelineError.invalidAudio(file.url.lastPathComponent)
            }
            try file.read(
                into: buffer,
                frameCount: AVAudioFrameCount(min(Int64(capacity), file.length - file.framePosition))
            )
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            try append(buffer: buffer)
            appended += count
        }
        return appended
    }

    private func appendWithConverter(
        file: AVAudioFile,
        inputFormat: AVAudioFormat
    ) throws -> Int {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(MeetingSystemTimelineRenderer.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MeetingSystemTimelineError.invalidAudio(file.url.lastPathComponent)
        }
        var reachedEnd = false
        var appended = 0
        while true {
            try Task.checkCancellation()
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 16_384
            ) else {
                throw MeetingSystemTimelineError.invalidAudio(file.url.lastPathComponent)
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                requestedPackets, inputStatus in
                if reachedEnd || file.framePosition >= file.length {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let input = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: requestedPackets
                ) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                do {
                    try file.read(
                        into: input,
                        frameCount: AVAudioFrameCount(
                            min(Int64(requestedPackets), file.length - file.framePosition)
                        )
                    )
                    if input.frameLength == 0 {
                        reachedEnd = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return input
                } catch {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
            }
            if let conversionError { throw conversionError }
            if output.frameLength > 0 {
                try append(buffer: output)
                appended += Int(output.frameLength)
            }
            if status == .endOfStream || (reachedEnd && output.frameLength == 0) { break }
            if status == .error {
                throw MeetingSystemTimelineError.invalidAudio(file.url.lastPathComponent)
            }
        }
        return appended
    }

    private func append(buffer: AVAudioPCMBuffer) throws {
        guard let channels = buffer.floatChannelData, let handle else {
            throw MeetingSystemTimelineError.invalidAudio(buffer.format.description)
        }
        let channelCount = Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength)
        var samples = [Int16]()
        samples.reserveCapacity(count)
        for frame in 0..<count {
            var value: Float = 0
            for channel in 0..<channelCount { value += channels[channel][frame] }
            value /= Float(channelCount)
            let clamped = max(-1, min(1, value))
            samples.append(clamped <= -1 ? .min : Int16((clamped * Float(Int16.max)).rounded()))
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let newFrames = frameCount + samples.count
        guard Int64(newFrames) * 2 <= Int64(UInt32.max) else {
            throw MeetingSystemTimelineError.timelineTooLong
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        frameCount = newFrames
    }

    private static func header(dataBytes: UInt32) -> Data {
        var data = Data()
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append((dataBytes &+ 36).littleEndian)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian)
        append(UInt16(1).littleEndian)
        append(UInt32(MeetingSystemTimelineRenderer.sampleRate).littleEndian)
        append(UInt32(MeetingSystemTimelineRenderer.sampleRate * 2).littleEndian)
        append(UInt16(2).littleEndian)
        append(UInt16(16).littleEndian)
        data.append(contentsOf: "data".utf8)
        append(dataBytes.littleEndian)
        return data
    }
}
