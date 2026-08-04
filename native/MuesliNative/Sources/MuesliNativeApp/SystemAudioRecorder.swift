import AVFoundation
import Foundation
import ScreenCaptureKit
import MuesliCore
import os

final class SystemAudioRecorder: NSObject, SCStreamOutput, SystemAudioCapturing, SystemAudioDiagnosticsProviding {
    var onPCMSamples: (([Int16]) -> Void)?
    var onNativeAudioChunk: ((CapturedAudioChunk) -> Void)?
    var emitsProcessedAudio: Bool {
        get { processedAudioLock.withLock { $0 } }
        set { processedAudioLock.withLock { $0 = newValue } }
    }

    private var stream: SCStream?
    private var outputFile: FileHandle?
    private var outputURL: URL?
    private var totalBytesWritten = 0
    private(set) var isRecording = false
    private(set) var isPaused = false

    private static let captureSampleRate: Double = 48_000
    private static let captureChannels: Int = 2
    private static let processingSampleRate: Double = 16_000
    private var resampler: AVAudioConverter?
    private var resamplerInputFormat: AVAudioFormat?
    private var resamplerOutputFormat: AVAudioFormat?
    private let diagnosticsLock = OSAllocatedUnfairLock(initialState: DiagnosticsState())
    private let processedAudioLock = OSAllocatedUnfairLock(initialState: true)

    private struct DiagnosticsState {
        var callbackCount = 0
        var bufferCount = 0
        var emptyBufferCount = 0
        var unsupportedFormatCount = 0
        var inputByteCount = 0
        var bytesWritten = 0
        var sourceSampleRate: Double = 0
        var sourceChannels: UInt32 = 0
        var preConversion = AudioSampleStats()
        var postConversion = AudioSampleStats()
    }

    var diagnosticsSnapshot: SystemAudioCaptureDiagnosticsSnapshot {
        diagnosticsLock.withLock { state in
            SystemAudioCaptureDiagnosticsSnapshot(
                backend: "ScreenCaptureKit",
                callbackCount: state.callbackCount,
                bufferCount: state.bufferCount,
                emptyBufferCount: state.emptyBufferCount,
                unsupportedFormatCount: state.unsupportedFormatCount,
                inputByteCount: state.inputByteCount,
                bytesWritten: state.bytesWritten,
                sourceSampleRate: state.sourceSampleRate,
                sourceChannels: state.sourceChannels,
                preConversion: state.preConversion.snapshot(),
                postConversion: state.postConversion.snapshot()
            )
        }
    }

    override init() {
        super.init()
    }

    func start() async throws {
        guard !isRecording else { return }

        // Create output WAV file
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: url.path) else {
            throw NSError(domain: "SystemAudio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open output file",
            ])
        }
        file.write(WavWriter.header(dataSize: 0))
        outputFile = file
        outputURL = url
        totalBytesWritten = 0
        isRecording = true
        isPaused = false

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.startStream()
                    fputs("[system-audio] SCStream capture started\n", stderr)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw NSError(domain: "SystemAudio", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "Timed out while starting system audio capture",
                    ])
                }

                guard let _ = try await group.next() else {
                    throw NSError(domain: "SystemAudio", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "System audio startup ended unexpectedly",
                    ])
                }
                group.cancelAll()
            }
        } catch {
            fputs("[system-audio] SCStream start failed: \(error)\n", stderr)
            cleanupFailedStart()
            throw error
        }
    }

    func stop() -> URL? {
        guard isRecording || outputFile != nil || outputURL != nil else { return nil }
        isRecording = false
        isPaused = false
        onPCMSamples = nil
        onNativeAudioChunk = nil

        if let stream {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                try? await stream.stopCapture()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 3)
        }
        stream = nil
        resampler = nil
        resamplerInputFormat = nil
        resamplerOutputFormat = nil

        // Finalize WAV
        if let outputFile {
            let header = WavWriter.header(dataSize: totalBytesWritten)
            outputFile.seek(toFileOffset: 0)
            outputFile.write(header)
            outputFile.closeFile()
        }
        outputFile = nil
        let writtenBytes = totalBytesWritten
        let completedURL = outputURL
        outputURL = nil
        totalBytesWritten = 0

        fputs("[system-audio] capture stopped, \(writtenBytes) bytes written\n", stderr)
        return completedURL
    }

    func pause() {
        guard isRecording else { return }
        isPaused = true
    }

    func resume() {
        guard isRecording else { return }
        isPaused = false
    }

    // MARK: - SCStream setup

    private func startStream() async throws {
        // Get shareable content (required to create a filter)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Create a filter that captures all audio — use a display filter with audio only
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudio", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No display found for SCStream",
            ])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        // Audio-only: disable video capture
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum (can't set 0)
        config.showsCursor = false

        // Audio configuration
        config.capturesAudio = true
        config.sampleRate = Int(Self.captureSampleRate)
        config.channelCount = Self.captureChannels
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.muesli.system-audio"))
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRecording, !isPaused else { return }
        diagnosticsLock.withLock { $0.callbackCount += 1 }

        // Get the audio format
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }
        guard let nativeChunk = makeNativeChunk(
            from: sampleBuffer,
            format: asbd
        ) else {
            diagnosticsLock.withLock { $0.emptyBufferCount += 1 }
            return
        }
        let length = nativeChunk.planes.reduce(0) { $0 + $1.data.count }
        diagnosticsLock.withLock { state in
            state.bufferCount += 1
            state.inputByteCount += length
            state.sourceSampleRate = asbd.mSampleRate
            state.sourceChannels = asbd.mChannelsPerFrame
        }

        onNativeAudioChunk?(nativeChunk)
        guard emitsProcessedAudio else { return }

        guard let mono = mixToMonoFloat(nativeChunk),
              let int16Samples = resampleMonoFloatToInt16(
                mono,
                sourceSampleRate: nativeChunk.format.sampleRate
              ) else {
            diagnosticsLock.withLock { $0.unsupportedFormatCount += 1 }
            return
        }
        let int16Data = int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }
        outputFile?.write(int16Data)
        totalBytesWritten += int16Data.count
        diagnosticsLock.withLock { state in
            state.bytesWritten += int16Data.count
            state.preConversion.addFloats(mono)
            state.postConversion.addInt16(int16Samples)
        }
        onPCMSamples?(int16Samples)
    }

    private func makeNativeChunk(
        from sampleBuffer: CMSampleBuffer,
        format: AudioStreamBasicDescription
    ) -> CapturedAudioChunk? {
        guard let capturedFormat = try? CapturedAudioChunk.capturedFormat(
            from: format
        ) else {
            return nil
        }
        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard sizingStatus == noErr, requiredSize >= MemoryLayout<AudioBufferList>.size else {
            return nil
        }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let audioBufferList = storage.assumingMemoryBound(
            to: AudioBufferList.self
        )
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let bytesPerSample = capturedFormat.sampleRepresentation.bytesPerSample
        let planes = UnsafeMutableAudioBufferListPointer(audioBufferList)
            .compactMap { buffer -> CapturedAudioPlane? in
                let channelCount = Int(buffer.mNumberChannels)
                let expectedBytes = frameCount * channelCount * bytesPerSample
                guard channelCount > 0,
                      expectedBytes > 0,
                      Int(buffer.mDataByteSize) >= expectedBytes,
                      let data = buffer.mData else {
                    return nil
                }
                return CapturedAudioPlane(
                    channelCount: channelCount,
                    data: Data(bytes: data, count: expectedBytes)
                )
            }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(
            sampleBuffer
        )
        let timestamp = presentationTime.isValid && presentationTime.isNumeric
            ? CapturedAudioTimestamp(
                monotonicNanoseconds: UInt64(
                    max(0, CMTimeGetSeconds(presentationTime) * 1_000_000_000)
                ),
                origin: .sourceHostClock
            )
            : .hostTime(nil)
        let chunk = CapturedAudioChunk(
            format: capturedFormat,
            frameCount: frameCount,
            timestamp: timestamp,
            planes: planes
        )
        guard (try? chunk.validate()) != nil else { return nil }
        return chunk
    }

    private func mixToMonoFloat(
        _ chunk: CapturedAudioChunk
    ) -> [Float]? {
        guard let data = try? chunk.interleavedPCMData() else { return nil }
        let channels = chunk.format.channelCount
        return data.withUnsafeBytes { rawBuffer -> [Float] in
            var mono = [Float]()
            mono.reserveCapacity(chunk.frameCount)
            switch chunk.format.sampleRepresentation {
            case .float32:
                for frame in 0..<chunk.frameCount {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += rawBuffer.loadUnaligned(
                            fromByteOffset:
                                (frame * channels + channel)
                                    * MemoryLayout<Float>.size,
                            as: Float.self
                        )
                    }
                    mono.append(sum / Float(channels))
                }
            case .signedInt16:
                for frame in 0..<chunk.frameCount {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        let value = rawBuffer.loadUnaligned(
                            fromByteOffset:
                                (frame * channels + channel)
                                    * MemoryLayout<Int16>.size,
                            as: Int16.self
                        )
                        sum += Float(value) / 32768
                    }
                    mono.append(sum / Float(channels))
                }
            }
            return mono
        }
    }

    private func resampleMonoFloatToInt16(
        _ samples: [Float],
        sourceSampleRate: Double
    ) -> [Int16]? {
        guard !samples.isEmpty, sourceSampleRate > 0 else { return nil }
        if abs(sourceSampleRate - Self.processingSampleRate) < 1 {
            return samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        }
        if resampler == nil
            || abs((resamplerInputFormat?.sampleRate ?? 0) - sourceSampleRate) >= 1 {
            guard let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: 1,
                interleaved: false
            ), let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.processingSampleRate,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(
                from: inputFormat,
                to: outputFormat
            ) else {
                return nil
            }
            resamplerInputFormat = inputFormat
            resamplerOutputFormat = outputFormat
            resampler = converter
        }
        guard let converter = resampler,
              let inputFormat = resamplerInputFormat,
              let outputFormat = resamplerOutputFormat,
              let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let inputChannel = input.floatChannelData?[0] else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        inputChannel.update(from: samples, count: samples.count)
        let capacity = AVAudioFrameCount(
            max(
                1,
                Int(
                    ceil(
                        Double(samples.count)
                            * Self.processingSampleRate
                            / sourceSampleRate
                    )
                ) + 32
            )
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            return nil
        }
        var providedInput = false
        var error: NSError?
        let status = converter.convert(
            to: output,
            error: &error
        ) { _, inputStatus in
            if providedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error,
              error == nil,
              let channel = output.floatChannelData?[0] else {
            return nil
        }
        return (0..<Int(output.frameLength)).map {
            Int16(max(-1, min(1, channel[$0])) * 32767)
        }
    }

    private func cleanupFailedStart() {
        isRecording = false
        isPaused = false
        stream = nil
        onPCMSamples = nil
        onNativeAudioChunk = nil
        resampler = nil
        resamplerInputFormat = nil
        resamplerOutputFormat = nil

        if let outputFile {
            outputFile.closeFile()
        }
        outputFile = nil

        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        totalBytesWritten = 0
    }
}
