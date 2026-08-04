import AudioToolbox
import AVFoundation
import Foundation

enum CapturedAudioSampleRepresentation: String, Codable, Sendable {
    case signedInt16 = "signed_int16"
    case float32

    var bytesPerSample: Int {
        switch self {
        case .signedInt16: return MemoryLayout<Int16>.size
        case .float32: return MemoryLayout<Float>.size
        }
    }
}

struct CapturedAudioFormat: Codable, Equatable, Sendable {
    let sampleRate: Double
    let channelCount: Int
    let sampleRepresentation: CapturedAudioSampleRepresentation
    let interleaved: Bool

    var bytesPerFrame: Int {
        channelCount * sampleRepresentation.bytesPerSample
    }

    var isValid: Bool {
        sampleRate.isFinite
            && sampleRate > 0
            && channelCount > 0
            && channelCount <= 64
    }

    func persistedInterleaved() -> CapturedAudioFormat {
        CapturedAudioFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            sampleRepresentation: sampleRepresentation,
            interleaved: true
        )
    }
}

enum CapturedAudioTimestampOrigin: String, Codable, Sendable {
    case sourceHostClock = "source_host_clock"
    case estimatedAtCallback = "estimated_at_callback"
}

struct CapturedAudioTimestamp: Codable, Equatable, Sendable {
    let monotonicNanoseconds: UInt64
    let origin: CapturedAudioTimestampOrigin

    func offsetNanoseconds(since anchor: UInt64) -> Int64 {
        guard monotonicNanoseconds >= anchor else {
            let delta = anchor - monotonicNanoseconds
            return delta > UInt64(Int64.max) ? Int64.min : -Int64(delta)
        }
        let delta = monotonicNanoseconds - anchor
        return delta > UInt64(Int64.max) ? Int64.max : Int64(delta)
    }

    static func hostTime(
        _ hostTime: UInt64?,
        fallbackHostTime: UInt64 = AudioGetCurrentHostTime()
    ) -> CapturedAudioTimestamp {
        if let hostTime, hostTime > 0 {
            return CapturedAudioTimestamp(
                monotonicNanoseconds: AudioConvertHostTimeToNanos(hostTime),
                origin: .sourceHostClock
            )
        }
        return CapturedAudioTimestamp(
            monotonicNanoseconds: AudioConvertHostTimeToNanos(fallbackHostTime),
            origin: .estimatedAtCallback
        )
    }
}

struct CapturedAudioPlane: Equatable, Sendable {
    let channelCount: Int
    let data: Data
}

enum CapturedAudioChunkError: Error, Equatable {
    case invalidFormat
    case invalidFrameCount
    case invalidPlaneChannelCount
    case channelCountMismatch(expected: Int, actual: Int)
    case payloadSizeMismatch(expected: Int, actual: Int)
}

/// A content-preserving audio callback value.
///
/// Capture backends may deliver one interleaved plane or multiple planar channel
/// buffers. `interleavedPCMData()` changes only byte layout: it never mixes
/// channels, resamples, applies gain, or runs signal processing.
struct CapturedAudioChunk: Equatable, Sendable {
    let format: CapturedAudioFormat
    let frameCount: Int
    let timestamp: CapturedAudioTimestamp
    let planes: [CapturedAudioPlane]

    func validate() throws {
        guard format.isValid else {
            throw CapturedAudioChunkError.invalidFormat
        }
        guard frameCount >= 0 else {
            throw CapturedAudioChunkError.invalidFrameCount
        }
        guard planes.allSatisfy({ $0.channelCount > 0 }) else {
            throw CapturedAudioChunkError.invalidPlaneChannelCount
        }
        let actualChannels = planes.reduce(0) { $0 + $1.channelCount }
        guard actualChannels == format.channelCount else {
            throw CapturedAudioChunkError.channelCountMismatch(
                expected: format.channelCount,
                actual: actualChannels
            )
        }
        let bytesPerSample = format.sampleRepresentation.bytesPerSample
        let expectedBytes = frameCount * format.channelCount * bytesPerSample
        let actualBytes = planes.reduce(0) { $0 + $1.data.count }
        guard actualBytes == expectedBytes else {
            throw CapturedAudioChunkError.payloadSizeMismatch(
                expected: expectedBytes,
                actual: actualBytes
            )
        }
        for plane in planes {
            let expectedPlaneBytes = frameCount * plane.channelCount * bytesPerSample
            guard plane.data.count == expectedPlaneBytes else {
                throw CapturedAudioChunkError.payloadSizeMismatch(
                    expected: expectedPlaneBytes,
                    actual: plane.data.count
                )
            }
        }
    }

    func interleavedPCMData() throws -> Data {
        try validate()
        guard frameCount > 0 else { return Data() }
        if planes.count == 1 {
            return planes[0].data
        }

        let bytesPerSample = format.sampleRepresentation.bytesPerSample
        var result = Data()
        result.reserveCapacity(frameCount * format.bytesPerFrame)
        for frame in 0..<frameCount {
            for plane in planes {
                let bytesPerPlaneFrame = plane.channelCount * bytesPerSample
                let start = frame * bytesPerPlaneFrame
                result.append(plane.data[start..<(start + bytesPerPlaneFrame)])
            }
        }
        return result
    }

    /// Returns true once the input has produced a real signal rather than a
    /// stream of digital silence. This is deliberately much more sensitive
    /// than speech detection: ordinary microphone self-noise is sufficient,
    /// while exact-zero buffers from a stalled CoreAudio route are rejected.
    func containsInputSignal(floatThreshold: Float = 0.000_000_1) -> Bool {
        guard frameCount > 0 else { return false }
        switch format.sampleRepresentation {
        case .signedInt16:
            return planes.contains { plane in
                plane.data.withUnsafeBytes { rawBuffer in
                    for offset in stride(
                        from: 0,
                        to: rawBuffer.count,
                        by: MemoryLayout<Int16>.size
                    ) where rawBuffer.loadUnaligned(
                        fromByteOffset: offset,
                        as: Int16.self
                    ) != 0 {
                        return true
                    }
                    return false
                }
            }
        case .float32:
            return planes.contains { plane in
                plane.data.withUnsafeBytes { rawBuffer in
                    for offset in stride(
                        from: 0,
                        to: rawBuffer.count,
                        by: MemoryLayout<Float>.size
                    ) {
                        let sample = rawBuffer.loadUnaligned(
                            fromByteOffset: offset,
                            as: Float.self
                        )
                        if sample.isFinite, abs(sample) >= floatThreshold {
                            return true
                        }
                    }
                    return false
                }
            }
        }
    }

    static func copying(
        buffer: AVAudioPCMBuffer,
        at time: AVAudioTime?
    ) throws -> CapturedAudioChunk {
        let streamDescription = buffer.format.streamDescription.pointee
        let format = try capturedFormat(from: streamDescription)
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let frameCount = Int(buffer.frameLength)
        let bytesPerSample = format.sampleRepresentation.bytesPerSample
        let planes = try audioBuffers.map { audioBuffer -> CapturedAudioPlane in
            let channelCount = Int(audioBuffer.mNumberChannels)
            let expectedBytes = frameCount * channelCount * bytesPerSample
            guard expectedBytes == 0 || audioBuffer.mData != nil,
                  Int(audioBuffer.mDataByteSize) >= expectedBytes else {
                throw CapturedAudioChunkError.payloadSizeMismatch(
                    expected: expectedBytes,
                    actual: Int(audioBuffer.mDataByteSize)
                )
            }
            let data = expectedBytes > 0
                ? Data(bytes: audioBuffer.mData!, count: expectedBytes)
                : Data()
            return CapturedAudioPlane(channelCount: channelCount, data: data)
        }
        return CapturedAudioChunk(
            format: format,
            frameCount: frameCount,
            timestamp: .hostTime(time?.isHostTimeValid == true ? time?.hostTime : nil),
            planes: planes
        )
    }

    static func capturedFormat(
        from streamDescription: AudioStreamBasicDescription
    ) throws -> CapturedAudioFormat {
        guard streamDescription.mFormatID == kAudioFormatLinearPCM else {
            throw CapturedAudioChunkError.invalidFormat
        }
        let flags = streamDescription.mFormatFlags
        let sampleRepresentation: CapturedAudioSampleRepresentation
        if (flags & kAudioFormatFlagIsFloat) != 0,
           streamDescription.mBitsPerChannel == 32 {
            sampleRepresentation = .float32
        } else if (flags & kAudioFormatFlagIsFloat) == 0,
                  streamDescription.mBitsPerChannel == 16 {
            sampleRepresentation = .signedInt16
        } else {
            throw CapturedAudioChunkError.invalidFormat
        }
        let format = CapturedAudioFormat(
            sampleRate: streamDescription.mSampleRate,
            channelCount: Int(streamDescription.mChannelsPerFrame),
            sampleRepresentation: sampleRepresentation,
            interleaved: (flags & kAudioFormatFlagIsNonInterleaved) == 0
        )
        guard format.isValid else {
            throw CapturedAudioChunkError.invalidFormat
        }
        return format
    }
}

protocol NativeAudioChunkProviding: AnyObject {
    var onNativeAudioChunk: ((CapturedAudioChunk) -> Void)? { get set }
}

/// Lets a capture owner keep native source delivery active while suspending
/// derived 16 kHz callbacks and temporary processed-file writes.
protocol ProcessedAudioEmissionControlling: AnyObject {
    var emitsProcessedAudio: Bool { get set }
}
