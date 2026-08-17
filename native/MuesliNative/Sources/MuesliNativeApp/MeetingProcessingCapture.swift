import Foundation
import MuesliCore
import os

enum MeetingProcessingCaptureError: Error, LocalizedError {
    case alreadyFinalized
    case writerFailed(source: String, underlying: Error)
    case invalidStagingDirectory
    case missingManifest
    case invalidAudioFile(URL)

    var errorDescription: String? {
        switch self {
        case .alreadyFinalized:
            return "The meeting processing capture has already been finalized."
        case .writerFailed(let source, let underlying):
            return "Could not preserve \(source) audio for final transcription: \(underlying.localizedDescription)"
        case .invalidStagingDirectory:
            return "The meeting processing directory is outside Homan's private storage."
        case .missingManifest:
            return "The meeting processing manifest is missing."
        case .invalidAudioFile(let url):
            return "The staged audio file is invalid: \(url.lastPathComponent)"
        }
    }
}

enum MeetingProcessingCaptureState: String, Codable, Sendable {
    case capturing
    case captureComplete = "capture_complete"
    case transcribing
    case diarizing
    case summarizing
    case committing
    case completed
    case failed
    case discarded
}

struct MeetingProcessingManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let meetingID: Int64
    let sessionID: UUID
    let startedAt: Date
    var endedAt: Date?
    let sampleRate: Int
    let channels: Int
    let finalModelID: ASRModelID
    var microphoneSampleCount: Int
    var systemSampleCount: Int
    var state: MeetingProcessingCaptureState
    var lastError: String?
    var attemptCount: Int?
    var cohereLanguage: String?
    var indicASRLanguage: String?
    var nemotron35Language: String?
    var finalDiarizationEnabled: Bool?
    var finalDiarizationProfileID: String?
    var timelinePolicy: MeetingRecordingTimelinePolicy?
    var preprocessing: MeetingRecordingPreprocessingDescriptor?
    var sampleFormat: String?
}

struct MeetingStagedAudio: Equatable, Sendable {
    let directoryURL: URL
    let manifestURL: URL
    let microphoneURL: URL
    let systemURL: URL
    let manifest: MeetingProcessingManifest
}

/// Full-session, append-safe audio capture used only as the source of truth for
/// post-meeting processing and crash recovery. Files are ordinary 16 kHz mono
/// WAVs whose headers can be reconstructed from file length after a crash.
final class MeetingProcessingCapture: @unchecked Sendable {
    static let directoryName = "Meeting Processing"
    static let sampleRate = 16_000
    static let channels = 1

    private static let headerSize = 44
    private static let manifestFilename = "manifest.json"
    private static let microphoneFilename = "mic-cleaned.wav"
    private static let systemFilename = "system.wav"
    private static let manifestCheckpointSamples = sampleRate * 5

    private struct WriterState {
        var microphoneHandle: FileHandle?
        var systemHandle: FileHandle?
        var manifest: MeetingProcessingManifest
        var lastCheckpointedMicrophoneSamples = 0
        var lastCheckpointedSystemSamples = 0
        var firstError: (source: String, error: Error)?
        var isFinalized = false
    }

    let directoryURL: URL
    let manifestURL: URL
    let microphoneURL: URL
    let systemURL: URL

    private let lock: OSAllocatedUnfairLock<WriterState>
    var onFailure: (@Sendable (Error) -> Void)?

    init(
        meetingID: Int64,
        sessionID: UUID = UUID(),
        startedAt: Date,
        finalModelID: ASRModelID,
        cohereLanguage: CohereTranscribeLanguage? = nil,
        indicASRLanguage: IndicASRLanguage? = nil,
        nemotron35Language: Nemotron35Language? = nil,
        finalDiarizationEnabled: Bool? = nil,
        finalDiarizationProfileID: String? = nil,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) throws {
        let root = supportDirectory
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        let meetingDirectory = root
            .appendingPathComponent(String(meetingID), isDirectory: true)
        directoryURL = meetingDirectory
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        manifestURL = directoryURL.appendingPathComponent(Self.manifestFilename)
        microphoneURL = directoryURL.appendingPathComponent(Self.microphoneFilename)
        systemURL = directoryURL.appendingPathComponent(Self.systemFilename)

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let microphoneHandle = try Self.createWAV(at: microphoneURL)
        do {
            let systemHandle = try Self.createWAV(at: systemURL)
            let manifest = MeetingProcessingManifest(
                schemaVersion: MeetingProcessingManifest.currentSchemaVersion,
                meetingID: meetingID,
                sessionID: sessionID,
                startedAt: startedAt,
                endedAt: nil,
                sampleRate: Self.sampleRate,
                channels: Self.channels,
                finalModelID: finalModelID,
                microphoneSampleCount: 0,
                systemSampleCount: 0,
                state: .capturing,
                lastError: nil,
                attemptCount: 0,
                cohereLanguage: cohereLanguage?.rawValue,
                indicASRLanguage: indicASRLanguage?.rawValue,
                nemotron35Language: nemotron35Language?.rawValue,
                finalDiarizationEnabled: finalDiarizationEnabled,
                finalDiarizationProfileID: finalDiarizationProfileID,
                timelinePolicy: .activeCaptureCompacted,
                preprocessing: .current,
                sampleFormat: MeetingRecordingPreprocessingDescriptor.current.sampleFormat
            )
            lock = OSAllocatedUnfairLock(initialState: WriterState(
                microphoneHandle: microphoneHandle,
                systemHandle: systemHandle,
                manifest: manifest
            ))
            try writeManifest(manifest)
        } catch {
            try? microphoneHandle.close()
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    var sessionID: UUID {
        lock.withLock { $0.manifest.sessionID }
    }

    func appendMicrophone(_ samples: [Int16]) {
        append(samples, source: "microphone")
    }

    func appendSystem(_ samples: [Int16]) {
        append(samples, source: "system")
    }

    func finalize(endedAt: Date) throws -> MeetingStagedAudio {
        let manifest = try lock.withLock { state -> MeetingProcessingManifest in
            guard !state.isFinalized else {
                throw MeetingProcessingCaptureError.alreadyFinalized
            }
            state.isFinalized = true
            try Self.finishWAV(
                handle: state.microphoneHandle,
                at: microphoneURL,
                sampleCount: state.manifest.microphoneSampleCount
            )
            state.microphoneHandle = nil
            try Self.finishWAV(
                handle: state.systemHandle,
                at: systemURL,
                sampleCount: state.manifest.systemSampleCount
            )
            state.systemHandle = nil
            if let firstError = state.firstError {
                state.manifest.state = .failed
                state.manifest.lastError = firstError.error.localizedDescription
                state.manifest.endedAt = endedAt
                return state.manifest
            }
            state.manifest.endedAt = endedAt
            state.manifest.state = .captureComplete
            return state.manifest
        }
        try writeManifest(manifest)
        if manifest.state == .failed {
            let writerError = lock.withLock { $0.firstError }
            throw MeetingProcessingCaptureError.writerFailed(
                source: writerError?.source ?? "meeting",
                underlying: writerError?.error ?? CocoaError(.fileWriteUnknown)
            )
        }
        return MeetingStagedAudio(
            directoryURL: directoryURL,
            manifestURL: manifestURL,
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            manifest: manifest
        )
    }

    /// Startup recovery closes an interrupted WAV by deriving its data size from
    /// the append-only file. Live transcript text is not involved.
    static func recover(
        directoryURL: URL,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        endedAt: Date = Date()
    ) throws -> MeetingStagedAudio {
        let root = supportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        let standardizedDirectory = directoryURL.standardizedFileURL
        guard standardizedDirectory.path == root.path
            || standardizedDirectory.path.hasPrefix(root.path + "/") else {
            throw MeetingProcessingCaptureError.invalidStagingDirectory
        }

        let manifestURL = standardizedDirectory.appendingPathComponent(manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MeetingProcessingCaptureError.missingManifest
        }
        var manifest = try JSONDecoder().decode(
            MeetingProcessingManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let microphoneURL = standardizedDirectory.appendingPathComponent(microphoneFilename)
        let systemURL = standardizedDirectory.appendingPathComponent(systemFilename)
        manifest.microphoneSampleCount = try repairWAVHeader(at: microphoneURL)
        manifest.systemSampleCount = try repairWAVHeader(at: systemURL)
        manifest.endedAt = manifest.endedAt ?? endedAt
        if manifest.state == .capturing {
            manifest.state = .captureComplete
        }
        try writeManifest(manifest, to: manifestURL)
        return MeetingStagedAudio(
            directoryURL: standardizedDirectory,
            manifestURL: manifestURL,
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            manifest: manifest
        )
    }

    func discard() {
        lock.withLock { state in
            state.isFinalized = true
            try? state.microphoneHandle?.close()
            try? state.systemHandle?.close()
            state.microphoneHandle = nil
            state.systemHandle = nil
        }
        try? FileManager.default.removeItem(at: directoryURL)
        Self.removeEmptyParents(startingAt: directoryURL.deletingLastPathComponent())
    }

    static func discard(_ stagedAudio: MeetingStagedAudio) {
        try? FileManager.default.removeItem(at: stagedAudio.directoryURL)
        removeEmptyParents(startingAt: stagedAudio.directoryURL.deletingLastPathComponent())
    }

    static func recoverableSessions(
        meetingID: Int64? = nil,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) -> [MeetingStagedAudio] {
        let root = supportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        let fileManager = FileManager.default
        guard let meetingDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var recovered: [MeetingStagedAudio] = []
        for meetingDirectory in meetingDirectories {
            if let meetingID,
               meetingDirectory.lastPathComponent != String(meetingID) {
                continue
            }
            guard let sessionDirectories = try? fileManager.contentsOfDirectory(
                at: meetingDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for sessionDirectory in sessionDirectories {
                guard let staged = try? recover(
                    directoryURL: sessionDirectory,
                    supportDirectory: supportDirectory
                ) else {
                    continue
                }
                guard staged.manifest.state != .completed,
                      staged.manifest.state != .discarded else {
                    continue
                }
                recovered.append(staged)
            }
        }
        return recovered.sorted {
            if $0.manifest.startedAt == $1.manifest.startedAt {
                return $0.manifest.sessionID.uuidString < $1.manifest.sessionID.uuidString
            }
            return $0.manifest.startedAt < $1.manifest.startedAt
        }
    }

    static func hasRecoverableSession(
        meetingID: Int64,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) -> Bool {
        !recoverableSessions(
            meetingID: meetingID,
            supportDirectory: supportDirectory
        ).isEmpty
    }

    static func recoverableByteCount(
        meetingID: Int64,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default
    ) -> Int64 {
        recoverableSessions(meetingID: meetingID, supportDirectory: supportDirectory)
            .reduce(into: Int64(0)) { total, staged in
                total += directoryByteCount(staged.directoryURL, fileManager: fileManager)
            }
    }

    @discardableResult
    static func markProcessing(
        _ stagedAudio: MeetingStagedAudio
    ) throws -> MeetingStagedAudio {
        try updateManifest(for: stagedAudio) { manifest in
            manifest.state = .transcribing
            manifest.lastError = nil
            manifest.attemptCount = (manifest.attemptCount ?? 0) + 1
        }
    }

    @discardableResult
    static func markState(
        _ state: MeetingProcessingCaptureState,
        for stagedAudio: MeetingStagedAudio
    ) throws -> MeetingStagedAudio {
        try updateManifest(for: stagedAudio) { manifest in
            manifest.state = state
        }
    }

    @discardableResult
    static func markFailed(
        _ stagedAudio: MeetingStagedAudio,
        error: Error
    ) throws -> MeetingStagedAudio {
        try updateManifest(for: stagedAudio) { manifest in
            manifest.state = .failed
            manifest.lastError = error.localizedDescription
        }
    }

    static func discardAll(
        meetingID: Int64,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) throws {
        let root = supportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        let meetingDirectory = root
            .appendingPathComponent(String(meetingID), isDirectory: true)
            .standardizedFileURL
        guard meetingDirectory.path.hasPrefix(root.path + "/") else {
            throw MeetingProcessingCaptureError.invalidStagingDirectory
        }
        if FileManager.default.fileExists(atPath: meetingDirectory.path) {
            try FileManager.default.removeItem(at: meetingDirectory)
        }
        removeEmptyParents(startingAt: root)
    }

    private static func updateManifest(
        for stagedAudio: MeetingStagedAudio,
        mutate: (inout MeetingProcessingManifest) -> Void
    ) throws -> MeetingStagedAudio {
        var manifest = try JSONDecoder().decode(
            MeetingProcessingManifest.self,
            from: Data(contentsOf: stagedAudio.manifestURL)
        )
        mutate(&manifest)
        try writeManifest(manifest, to: stagedAudio.manifestURL)
        return MeetingStagedAudio(
            directoryURL: stagedAudio.directoryURL,
            manifestURL: stagedAudio.manifestURL,
            microphoneURL: stagedAudio.microphoneURL,
            systemURL: stagedAudio.systemURL,
            manifest: manifest
        )
    }

    private func append(_ samples: [Int16], source: String) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let manifestToCheckpoint = lock.withLock { state -> MeetingProcessingManifest? in
            guard !state.isFinalized, state.firstError == nil else { return nil }
            do {
                switch source {
                case "microphone":
                    try state.microphoneHandle?.write(contentsOf: data)
                    state.manifest.microphoneSampleCount += samples.count
                default:
                    try state.systemHandle?.write(contentsOf: data)
                    state.manifest.systemSampleCount += samples.count
                }
                let shouldCheckpoint =
                    state.manifest.microphoneSampleCount - state.lastCheckpointedMicrophoneSamples
                        >= Self.manifestCheckpointSamples
                    || state.manifest.systemSampleCount - state.lastCheckpointedSystemSamples
                        >= Self.manifestCheckpointSamples
                if shouldCheckpoint {
                    state.lastCheckpointedMicrophoneSamples = state.manifest.microphoneSampleCount
                    state.lastCheckpointedSystemSamples = state.manifest.systemSampleCount
                    return state.manifest
                }
                return nil
            } catch {
                state.firstError = (source, error)
                state.manifest.state = .failed
                state.manifest.lastError = error.localizedDescription
                return state.manifest
            }
        }
        if let manifestToCheckpoint {
            do {
                try writeManifest(manifestToCheckpoint)
            } catch {
                lock.withLock { state in
                    if state.firstError == nil {
                        state.firstError = ("manifest", error)
                        state.manifest.state = .failed
                        state.manifest.lastError = error.localizedDescription
                    }
                }
                onFailure?(MeetingProcessingCaptureError.writerFailed(
                    source: "manifest",
                    underlying: error
                ))
            }
            if manifestToCheckpoint.state == .failed {
                let failure = lock.withLock { $0.firstError }
                onFailure?(MeetingProcessingCaptureError.writerFailed(
                    source: failure?.source ?? source,
                    underlying: failure?.error ?? CocoaError(.fileWriteUnknown)
                ))
            }
        }
    }

    private func writeManifest(_ manifest: MeetingProcessingManifest) throws {
        try Self.writeManifest(manifest, to: manifestURL)
    }

    private static func writeManifest(
        _ manifest: MeetingProcessingManifest,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func createWAV(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: WavWriter.header(dataSize: 0),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
        return handle
    }

    private static func finishWAV(
        handle: FileHandle?,
        at url: URL,
        sampleCount: Int
    ) throws {
        guard let handle else { return }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WavWriter.header(dataSize: UInt32(sampleCount * MemoryLayout<Int16>.size)))
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult
    private static func repairWAVHeader(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue >= headerSize else {
            throw MeetingProcessingCaptureError.invalidAudioFile(url)
        }
        let dataSize = fileSize.intValue - headerSize
        guard dataSize.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw MeetingProcessingCaptureError.invalidAudioFile(url)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WavWriter.header(dataSize: UInt32(dataSize)))
        try handle.synchronize()
        return dataSize / MemoryLayout<Int16>.size
    }

    private static func removeEmptyParents(startingAt directory: URL) {
        let root = directory
            .deletingLastPathComponent()
            .standardizedFileURL
        var candidate = directory.standardizedFileURL
        while candidate.path.hasPrefix(root.path + "/") {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: nil
            ), contents.isEmpty else {
                return
            }
            try? FileManager.default.removeItem(at: candidate)
            candidate.deleteLastPathComponent()
        }
    }

    private static func directoryByteCount(
        _ directory: URL,
        fileManager: FileManager
    ) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
