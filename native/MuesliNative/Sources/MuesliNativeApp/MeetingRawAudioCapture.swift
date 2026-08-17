@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation
import MuesliCore

enum MeetingRawAudioEncoding: String, Codable, Sendable {
    case pcmJournal = "pcm_journal"
    case appleLossless = "apple_lossless"
}

enum MeetingRawAudioEpochState: String, Codable, Sendable {
    case openPCM = "open_pcm"
    case closedPCM = "closed_pcm"
    case compacting
    case verifiedALAC = "verified_alac"
}

struct MeetingRawAudioEpoch: Codable, Equatable, Sendable {
    let id: UUID
    let role: MeetingAudioSourceRole
    var relativePath: String
    let startOffsetNanoseconds: Int64
    let format: CapturedAudioFormat
    var frameCount: Int
    var encoding: MeetingRawAudioEncoding
    var state: MeetingRawAudioEpochState
    let timestampOrigin: CapturedAudioTimestampOrigin
    var contentDigest: String?

    var durationNanoseconds: Int64 {
        guard format.sampleRate > 0 else { return 0 }
        return Int64((Double(frameCount) / format.sampleRate * 1_000_000_000).rounded())
    }
}

struct MeetingRawAudioManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let meetingID: Int64
    let sessionID: UUID
    let startedAt: Date
    var endedAt: Date?
    let timelineAnchorNanoseconds: UInt64
    var timelineDurationNanoseconds: Int64
    let finalModelID: ASRModelID
    var state: MeetingProcessingCaptureState
    var lastError: String?
    var attemptCount: Int?
    var cohereLanguage: String?
    var indicASRLanguage: String?
    var nemotron35Language: String?
    /// Immutable Final speaker-analysis intent captured when recording starts.
    /// Optional for manifests written by older builds.
    var finalDiarizationEnabled: Bool?
    var finalDiarizationProfileID: String?
    var microphoneEpochs: [MeetingRawAudioEpoch]
    var systemEpochs: [MeetingRawAudioEpoch]
}

struct MeetingStagedRawAudio: Equatable, Sendable {
    let directoryURL: URL
    let manifestURL: URL
    let manifest: MeetingRawAudioManifest

    var epochs: [MeetingRawAudioEpoch] {
        manifest.microphoneEpochs + manifest.systemEpochs
    }

    func epochs(for role: MeetingAudioSourceRole) -> [MeetingRawAudioEpoch] {
        switch role {
        case .microphone: return manifest.microphoneEpochs
        case .system: return manifest.systemEpochs
        case .legacyMixed: return []
        }
    }

    func payloadURL(for epoch: MeetingRawAudioEpoch) -> URL {
        directoryURL.appendingPathComponent(epoch.relativePath)
    }
}

enum MeetingRawAudioCaptureError: Error, LocalizedError, Equatable {
    case alreadyFinalized
    case unsupportedRole
    case invalidChunk(CapturedAudioChunkError)
    case invalidManagedDirectory
    case missingManifest
    case unsupportedSchemaVersion(Int)
    case unsafeRelativePath(String)
    case missingPayload(String)
    case invalidPayloadLength(String)
    case alacEncodingFailed(String)
    case alacVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyFinalized:
            return "The raw meeting audio capture has already been finalized."
        case .unsupportedRole:
            return "Legacy mixed audio cannot be appended to a raw source capture."
        case .invalidChunk(let error):
            return "A raw audio callback was invalid: \(error)"
        case .invalidManagedDirectory:
            return "The raw meeting audio directory is outside Homan's managed storage."
        case .missingManifest:
            return "The raw meeting audio manifest is missing."
        case .unsupportedSchemaVersion(let version):
            return "Raw meeting audio schema \(version) is not supported."
        case .unsafeRelativePath(let path):
            return "The raw meeting audio manifest contains an unsafe path: \(path)"
        case .missingPayload(let path):
            return "A raw meeting audio payload is missing: \(path)"
        case .invalidPayloadLength(let path):
            return "A raw meeting audio payload has an incomplete frame: \(path)"
        case .alacEncodingFailed(let reason):
            return "Could not compact raw meeting audio losslessly: \(reason)"
        case .alacVerificationFailed(let reason):
            return "Could not verify compacted raw meeting audio: \(reason)"
        }
    }
}

/// Append-safe native meeting source capture.
///
/// Audio callbacks are first appended to short PCM segments. Closed segments
/// are compacted to ALAC on a utility queue and the PCM source is removed only
/// after the ALAC payload has been opened and its frame count verified.
final class MeetingRawAudioCapture: @unchecked Sendable {
    static let directoryName = "Meeting Raw Processing"
    static let manifestFilename = "manifest.json"

    private struct OpenEpoch {
        let role: MeetingAudioSourceRole
        let id: UUID
        let handle: FileHandle
        let format: CapturedAudioFormat
        let startedAtNanoseconds: Int64
        var lastChunkStartNanoseconds: Int64
        var frameCount: Int
        let descriptorIndex: Int
    }

    private struct WriterState {
        var manifest: MeetingRawAudioManifest
        var microphone: OpenEpoch?
        var system: OpenEpoch?
        var isFinalized = false
        var isDiscarded = false
        var firstError: Error?
        var framesSinceCheckpoint = 0
    }

    let directoryURL: URL
    let manifestURL: URL

    var onFailure: (@Sendable (Error) -> Void)?

    private let fileManager: FileManager
    private let writerQueue: DispatchQueue
    private let compactionQueue: DispatchQueue
    private let compactionGroup = DispatchGroup()
    private let segmentDurationNanoseconds: Int64
    private let discontinuityToleranceNanoseconds: Int64
    private let shouldCompactLosslessly: Bool
    private var state: WriterState

    init(
        meetingID: Int64,
        sessionID: UUID = UUID(),
        startedAt: Date,
        timelineAnchorNanoseconds: UInt64 = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()),
        finalModelID: ASRModelID,
        cohereLanguage: CohereTranscribeLanguage? = nil,
        indicASRLanguage: IndicASRLanguage? = nil,
        nemotron35Language: Nemotron35Language? = nil,
        finalDiarizationEnabled: Bool? = nil,
        finalDiarizationProfileID: MeetingDiarizationProfileID? = nil,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        segmentDuration: TimeInterval = 60,
        discontinuityTolerance: TimeInterval = 0.020,
        compactLosslessly: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.segmentDurationNanoseconds = Int64(max(segmentDuration, 0.1) * 1_000_000_000)
        self.discontinuityToleranceNanoseconds = Int64(
            max(discontinuityTolerance, 0.001) * 1_000_000_000
        )
        self.shouldCompactLosslessly = compactLosslessly
        writerQueue = DispatchQueue(
            label: "com.muesli.meeting-raw-audio-writer.\(sessionID.uuidString)"
        )
        compactionQueue = DispatchQueue(
            label: "com.muesli.meeting-raw-audio-compaction.\(sessionID.uuidString)",
            qos: .utility
        )

        let root = supportDirectory
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        let meetingDirectory = root
            .appendingPathComponent(String(meetingID), isDirectory: true)
        directoryURL = meetingDirectory
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        manifestURL = directoryURL.appendingPathComponent(Self.manifestFilename)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let manifest = MeetingRawAudioManifest(
            schemaVersion: MeetingRawAudioManifest.currentSchemaVersion,
            meetingID: meetingID,
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: nil,
            timelineAnchorNanoseconds: timelineAnchorNanoseconds,
            timelineDurationNanoseconds: 0,
            finalModelID: finalModelID,
            state: .capturing,
            lastError: nil,
            attemptCount: 0,
            cohereLanguage: cohereLanguage?.rawValue,
            indicASRLanguage: indicASRLanguage?.rawValue,
            nemotron35Language: nemotron35Language?.rawValue,
            finalDiarizationEnabled: finalDiarizationEnabled,
            finalDiarizationProfileID: finalDiarizationProfileID?.rawValue,
            microphoneEpochs: [],
            systemEpochs: []
        )
        state = WriterState(manifest: manifest)
        try writeManifest(manifest)
    }

    func append(_ chunk: CapturedAudioChunk, role: MeetingAudioSourceRole) {
        do {
            try chunk.validate()
        } catch let error as CapturedAudioChunkError {
            report(MeetingRawAudioCaptureError.invalidChunk(error))
            return
        } catch {
            report(error)
            return
        }
        guard chunk.frameCount > 0 else { return }
        guard role == .microphone || role == .system else {
            report(MeetingRawAudioCaptureError.unsupportedRole)
            return
        }
        writerQueue.async { [weak self] in
            self?.appendOnQueue(chunk, role: role)
        }
    }

    func checkpoint() throws -> MeetingStagedRawAudio {
        try writerQueue.sync {
            try checkpointOnQueue(force: true)
            return stagedAudioOnQueue()
        }
    }

    func setFinalDiarizationPolicy(
        enabled: Bool,
        profileID: MeetingDiarizationProfileID
    ) throws {
        try writerQueue.sync {
            guard !state.isFinalized, !state.isDiscarded else { return }
            state.manifest.finalDiarizationEnabled = enabled
            state.manifest.finalDiarizationProfileID = profileID.rawValue
            try writeManifest(state.manifest)
        }
    }

    func finalize(endedAt: Date) throws -> MeetingStagedRawAudio {
        try writerQueue.sync {
            guard !state.isFinalized else {
                throw MeetingRawAudioCaptureError.alreadyFinalized
            }
            closeOpenEpochOnQueue(role: .microphone)
            closeOpenEpochOnQueue(role: .system)
            state.isFinalized = true
        }

        compactionGroup.wait()

        return try writerQueue.sync {
            if let firstError = state.firstError {
                state.manifest.state = .failed
                state.manifest.lastError = firstError.localizedDescription
            } else {
                state.manifest.state = .captureComplete
            }
            state.manifest.endedAt = endedAt
            try checkpointOnQueue(force: true)
            return stagedAudioOnQueue()
        }
    }

    func discard() {
        writerQueue.sync {
            state.isDiscarded = true
            state.isFinalized = true
            try? state.microphone?.handle.close()
            try? state.system?.handle.close()
            state.microphone = nil
            state.system = nil
        }
        compactionGroup.wait()
        try? fileManager.removeItem(at: directoryURL)
    }

    /// Test-only crash boundary: close append handles without changing the
    /// manifest's capturing state or compacting open PCM segments.
    func interruptForTesting() {
        writerQueue.sync {
            try? state.microphone?.handle.synchronize()
            try? state.microphone?.handle.close()
            try? state.system?.handle.synchronize()
            try? state.system?.handle.close()
            state.microphone = nil
            state.system = nil
            try? checkpointOnQueue(force: true)
        }
    }

    static func recover(
        directoryURL: URL,
        supportDirectory: URL,
        endedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> MeetingStagedRawAudio {
        let root = supportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        let directory = directoryURL.standardizedFileURL
        guard directory.path.hasPrefix(root.path + "/") else {
            throw MeetingRawAudioCaptureError.invalidManagedDirectory
        }
        let manifestURL = directory.appendingPathComponent(manifestFilename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MeetingRawAudioCaptureError.missingManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(
            MeetingRawAudioManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == MeetingRawAudioManifest.currentSchemaVersion else {
            throw MeetingRawAudioCaptureError.unsupportedSchemaVersion(manifest.schemaVersion)
        }

        manifest.microphoneEpochs = try recoverEpochs(
            manifest.microphoneEpochs,
            directory: directory,
            fileManager: fileManager
        )
        manifest.systemEpochs = try recoverEpochs(
            manifest.systemEpochs,
            directory: directory,
            fileManager: fileManager
        )
        manifest.timelineDurationNanoseconds = (
            manifest.microphoneEpochs + manifest.systemEpochs
        ).map { $0.startOffsetNanoseconds + $0.durationNanoseconds }.max() ?? 0
        manifest.endedAt = manifest.endedAt ?? endedAt
        if manifest.state == .capturing {
            manifest.state = .captureComplete
        }
        try writeManifest(manifest, to: manifestURL, fileManager: fileManager)
        return MeetingStagedRawAudio(
            directoryURL: directory,
            manifestURL: manifestURL,
            manifest: manifest
        )
    }

    static func discard(_ stagedAudio: MeetingStagedRawAudio) {
        try? FileManager.default.removeItem(at: stagedAudio.directoryURL)
        removeEmptyParents(
            startingAt: stagedAudio.directoryURL.deletingLastPathComponent()
        )
    }

    static func recoverableSessions(
        meetingID: Int64? = nil,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default
    ) -> [MeetingStagedRawAudio] {
        let root = supportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        guard let meetingDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var recovered: [MeetingStagedRawAudio] = []
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
                    supportDirectory: supportDirectory,
                    fileManager: fileManager
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
                return $0.manifest.sessionID.uuidString
                    < $1.manifest.sessionID.uuidString
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
        recoverableSessions(
            meetingID: meetingID,
            supportDirectory: supportDirectory,
            fileManager: fileManager
        ).reduce(into: 0) { total, staged in
            total += directoryByteCount(
                staged.directoryURL,
                fileManager: fileManager
            )
        }
    }

    static func discardAll(
        meetingID: Int64,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default
    ) throws {
        let root = supportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        let meetingDirectory = root
            .appendingPathComponent(String(meetingID), isDirectory: true)
            .standardizedFileURL
        guard meetingDirectory.path.hasPrefix(root.path + "/") else {
            throw MeetingRawAudioCaptureError.invalidManagedDirectory
        }
        if fileManager.fileExists(atPath: meetingDirectory.path) {
            try fileManager.removeItem(at: meetingDirectory)
        }
        removeEmptyParents(startingAt: root)
    }

    @discardableResult
    static func markState(
        _ newState: MeetingProcessingCaptureState,
        for stagedAudio: MeetingStagedRawAudio
    ) throws -> MeetingStagedRawAudio {
        try updateManifest(for: stagedAudio) {
            $0.state = newState
        }
    }

    @discardableResult
    static func markProcessing(
        _ stagedAudio: MeetingStagedRawAudio
    ) throws -> MeetingStagedRawAudio {
        try updateManifest(for: stagedAudio) {
            $0.state = .transcribing
            $0.lastError = nil
            $0.attemptCount = ($0.attemptCount ?? 0) + 1
        }
    }

    @discardableResult
    static func markFailed(
        _ stagedAudio: MeetingStagedRawAudio,
        error: Error
    ) throws -> MeetingStagedRawAudio {
        try updateManifest(for: stagedAudio) {
            $0.state = .failed
            $0.lastError = error.localizedDescription
        }
    }

    private static func updateManifest(
        for stagedAudio: MeetingStagedRawAudio,
        mutate: (inout MeetingRawAudioManifest) -> Void
    ) throws -> MeetingStagedRawAudio {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(
            MeetingRawAudioManifest.self,
            from: Data(contentsOf: stagedAudio.manifestURL)
        )
        mutate(&manifest)
        try writeManifest(
            manifest,
            to: stagedAudio.manifestURL,
            fileManager: .default
        )
        return MeetingStagedRawAudio(
            directoryURL: stagedAudio.directoryURL,
            manifestURL: stagedAudio.manifestURL,
            manifest: manifest
        )
    }

    private func appendOnQueue(
        _ chunk: CapturedAudioChunk,
        role: MeetingAudioSourceRole
    ) {
        guard !state.isFinalized, !state.isDiscarded, state.firstError == nil else { return }
        do {
            let interleavedData = try chunk.interleavedPCMData()
            let offset = max(
                0,
                chunk.timestamp.offsetNanoseconds(
                    since: state.manifest.timelineAnchorNanoseconds
                )
            )
            if shouldRotateOnQueue(chunk: chunk, role: role, offset: offset) {
                closeOpenEpochOnQueue(role: role)
            }
            if openEpochOnQueue(for: role) == nil {
                try openEpochOnQueue(
                    role: role,
                    format: chunk.format.persistedInterleaved(),
                    timestampOrigin: chunk.timestamp.origin,
                    startOffsetNanoseconds: offset
                )
            }
            guard var open = openEpochOnQueue(for: role) else { return }
            try open.handle.write(contentsOf: interleavedData)
            open.lastChunkStartNanoseconds = offset
            open.frameCount += chunk.frameCount
            setOpenEpochOnQueue(open, role: role)
            updateDescriptorOnQueue(open)
            state.framesSinceCheckpoint += chunk.frameCount
            state.manifest.timelineDurationNanoseconds = max(
                state.manifest.timelineDurationNanoseconds,
                open.startedAtNanoseconds + durationNanoseconds(
                    frames: open.frameCount,
                    sampleRate: open.format.sampleRate
                )
            )
            try checkpointOnQueue(force: state.framesSinceCheckpoint >= 240_000)
        } catch {
            state.firstError = error
            state.manifest.state = .failed
            state.manifest.lastError = error.localizedDescription
            report(error)
        }
    }

    private func shouldRotateOnQueue(
        chunk: CapturedAudioChunk,
        role: MeetingAudioSourceRole,
        offset: Int64
    ) -> Bool {
        guard let open = openEpochOnQueue(for: role) else { return false }
        let persistedFormat = chunk.format.persistedInterleaved()
        guard persistedFormat == open.format else { return true }
        let expectedStart = open.startedAtNanoseconds + durationNanoseconds(
            frames: open.frameCount,
            sampleRate: open.format.sampleRate
        )
        let discontinuity = abs(offset - expectedStart) > discontinuityToleranceNanoseconds
        let durationReached = expectedStart - open.startedAtNanoseconds
            >= segmentDurationNanoseconds
        return discontinuity || durationReached
    }

    private func openEpochOnQueue(
        role: MeetingAudioSourceRole,
        format: CapturedAudioFormat,
        timestampOrigin: CapturedAudioTimestampOrigin,
        startOffsetNanoseconds: Int64
    ) throws {
        let id = UUID()
        let roleDirectory = directoryURL
            .appendingPathComponent(role.rawValue, isDirectory: true)
        try fileManager.createDirectory(
            at: roleDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let relativePath = "\(role.rawValue)/\(id.uuidString.lowercased()).pcm"
        let url = directoryURL.appendingPathComponent(relativePath)
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        let descriptor = MeetingRawAudioEpoch(
            id: id,
            role: role,
            relativePath: relativePath,
            startOffsetNanoseconds: startOffsetNanoseconds,
            format: format,
            frameCount: 0,
            encoding: .pcmJournal,
            state: .openPCM,
            timestampOrigin: timestampOrigin,
            contentDigest: nil
        )
        let descriptorIndex: Int
        switch role {
        case .microphone:
            descriptorIndex = state.manifest.microphoneEpochs.count
            state.manifest.microphoneEpochs.append(descriptor)
        case .system:
            descriptorIndex = state.manifest.systemEpochs.count
            state.manifest.systemEpochs.append(descriptor)
        case .legacyMixed:
            throw MeetingRawAudioCaptureError.unsupportedRole
        }
        setOpenEpochOnQueue(
            OpenEpoch(
                role: role,
                id: id,
                handle: handle,
                format: format,
                startedAtNanoseconds: startOffsetNanoseconds,
                lastChunkStartNanoseconds: startOffsetNanoseconds,
                frameCount: 0,
                descriptorIndex: descriptorIndex
            ),
            role: role
        )
        try checkpointOnQueue(force: true)
    }

    private func closeOpenEpochOnQueue(role: MeetingAudioSourceRole) {
        guard let open = openEpochOnQueue(for: role) else { return }
        do {
            try open.handle.synchronize()
            try open.handle.close()
            setOpenEpochOnQueue(nil, role: role)
            updateDescriptorOnQueue(open, state: .closedPCM)
            try checkpointOnQueue(force: true)
            if shouldCompactLosslessly, open.frameCount > 0 {
                scheduleCompaction(open)
            }
        } catch {
            state.firstError = error
            state.manifest.state = .failed
            state.manifest.lastError = error.localizedDescription
            report(error)
        }
    }

    private func scheduleCompaction(_ open: OpenEpoch) {
        let sourceRelativePath = descriptorOnQueue(for: open).relativePath
        let sourceURL = directoryURL.appendingPathComponent(sourceRelativePath)
        let destinationRelativePath =
            "\(open.role.rawValue)/\(open.id.uuidString.lowercased()).caf"
        let destinationURL = directoryURL.appendingPathComponent(destinationRelativePath)
        updateDescriptorOnQueue(open, state: .compacting)
        try? checkpointOnQueue(force: true)

        compactionGroup.enter()
        compactionQueue.async { [self] in
            let result = Result {
                try Self.encodeALAC(
                    pcmURL: sourceURL,
                    destinationURL: destinationURL,
                    format: open.format,
                    expectedFrames: open.frameCount
                )
                return try Self.digest(at: destinationURL)
            }
            self.writerQueue.async {
                defer { self.compactionGroup.leave() }
                guard !self.state.isDiscarded else {
                    try? self.fileManager.removeItem(at: destinationURL)
                    return
                }
                switch result {
                case .success(let digest):
                    do {
                        var descriptor = self.descriptorOnQueue(for: open)
                        descriptor.relativePath = destinationRelativePath
                        descriptor.encoding = .appleLossless
                        descriptor.state = .verifiedALAC
                        descriptor.contentDigest = digest
                        self.setDescriptorOnQueue(descriptor, for: open)
                        try self.checkpointOnQueue(force: true)
                        try self.fileManager.removeItem(at: sourceURL)
                    } catch {
                        try? self.fileManager.removeItem(at: destinationURL)
                        self.updateDescriptorOnQueue(open, state: .closedPCM)
                        self.recordCompactionFailureOnQueue(error)
                    }
                case .failure(let error):
                    try? self.fileManager.removeItem(at: destinationURL)
                    self.updateDescriptorOnQueue(open, state: .closedPCM)
                    self.recordCompactionFailureOnQueue(error)
                }
            }
        }
    }

    private func recordCompactionFailureOnQueue(_ error: Error) {
        // The verified source is still the PCM journal, so compaction failure is
        // recoverable and must not fail the meeting capture.
        state.manifest.lastError = error.localizedDescription
        try? checkpointOnQueue(force: true)
        fputs("[meeting-raw] lossless compaction deferred: \(error)\n", stderr)
    }

    private func openEpochOnQueue(for role: MeetingAudioSourceRole) -> OpenEpoch? {
        role == .microphone ? state.microphone : state.system
    }

    private func setOpenEpochOnQueue(
        _ open: OpenEpoch?,
        role: MeetingAudioSourceRole
    ) {
        if role == .microphone {
            state.microphone = open
        } else {
            state.system = open
        }
    }

    private func descriptorOnQueue(for open: OpenEpoch) -> MeetingRawAudioEpoch {
        switch open.role {
        case .microphone:
            return state.manifest.microphoneEpochs[open.descriptorIndex]
        case .system:
            return state.manifest.systemEpochs[open.descriptorIndex]
        case .legacyMixed:
            preconditionFailure("Legacy mixed audio cannot have a raw epoch")
        }
    }

    private func setDescriptorOnQueue(
        _ descriptor: MeetingRawAudioEpoch,
        for open: OpenEpoch
    ) {
        switch open.role {
        case .microphone:
            state.manifest.microphoneEpochs[open.descriptorIndex] = descriptor
        case .system:
            state.manifest.systemEpochs[open.descriptorIndex] = descriptor
        case .legacyMixed:
            break
        }
    }

    private func updateDescriptorOnQueue(
        _ open: OpenEpoch,
        state epochState: MeetingRawAudioEpochState? = nil
    ) {
        var descriptor = descriptorOnQueue(for: open)
        descriptor.frameCount = open.frameCount
        if let epochState {
            descriptor.state = epochState
        }
        setDescriptorOnQueue(descriptor, for: open)
    }

    private func checkpointOnQueue(force: Bool) throws {
        guard force else { return }
        state.framesSinceCheckpoint = 0
        try writeManifest(state.manifest)
    }

    private func stagedAudioOnQueue() -> MeetingStagedRawAudio {
        MeetingStagedRawAudio(
            directoryURL: directoryURL,
            manifestURL: manifestURL,
            manifest: state.manifest
        )
    }

    private func writeManifest(_ manifest: MeetingRawAudioManifest) throws {
        try Self.writeManifest(
            manifest,
            to: manifestURL,
            fileManager: fileManager
        )
    }

    private static func writeManifest(
        _ manifest: MeetingRawAudioManifest,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func report(_ error: Error) {
        onFailure?(error)
    }

    private static func recoverEpochs(
        _ epochs: [MeetingRawAudioEpoch],
        directory: URL,
        fileManager: FileManager
    ) throws -> [MeetingRawAudioEpoch] {
        try epochs.map { epoch in
            guard isSafeRelativePath(epoch.relativePath) else {
                throw MeetingRawAudioCaptureError.unsafeRelativePath(epoch.relativePath)
            }
            let url = directory.appendingPathComponent(epoch.relativePath).standardizedFileURL
            guard url.path.hasPrefix(directory.path + "/") else {
                throw MeetingRawAudioCaptureError.unsafeRelativePath(epoch.relativePath)
            }
            guard fileManager.fileExists(atPath: url.path) else {
                throw MeetingRawAudioCaptureError.missingPayload(epoch.relativePath)
            }
            var recovered = epoch
            switch epoch.encoding {
            case .pcmJournal:
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
                let bytesPerFrame = epoch.format.bytesPerFrame
                guard bytesPerFrame > 0, bytes.isMultiple(of: bytesPerFrame) else {
                    throw MeetingRawAudioCaptureError.invalidPayloadLength(epoch.relativePath)
                }
                recovered.frameCount = bytes / bytesPerFrame
                recovered.state = .closedPCM
            case .appleLossless:
                let file = try AVAudioFile(forReading: url)
                recovered.frameCount = Int(file.length)
                recovered.state = .verifiedALAC
            }
            return recovered
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && URL(fileURLWithPath: path).pathComponents.allSatisfy { $0 != ".." }
    }

    private static func encodeALAC(
        pcmURL: URL,
        destinationURL: URL,
        format: CapturedAudioFormat,
        expectedFrames: Int
    ) throws {
        guard expectedFrames >= 0 else {
            throw MeetingRawAudioCaptureError.alacEncodingFailed("negative frame count")
        }
        try? FileManager.default.removeItem(at: destinationURL)
        try writeALAC(
            pcmURL: pcmURL,
            destinationURL: destinationURL,
            format: format,
            expectedFrames: expectedFrames
        )

        let commonFormat: AVAudioCommonFormat =
            format.sampleRepresentation == .signedInt16 ? .pcmFormatInt16 : .pcmFormatFloat32
        let verified = try AVAudioFile(
            forReading: destinationURL,
            commonFormat: commonFormat,
            interleaved: true
        )
        guard verified.fileFormat.streamDescription.pointee.mFormatID
                == kAudioFormatAppleLossless,
              Int(verified.length) == expectedFrames,
              Int(verified.fileFormat.channelCount) == format.channelCount,
              abs(verified.fileFormat.sampleRate - format.sampleRate) < 1 else {
            throw MeetingRawAudioCaptureError.alacVerificationFailed(
                destinationURL.lastPathComponent
            )
        }
    }

    private static func writeALAC(
        pcmURL: URL,
        destinationURL: URL,
        format: CapturedAudioFormat,
        expectedFrames: Int
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitDepthHintKey:
                format.sampleRepresentation == .signedInt16 ? 16 : 32,
        ]
        let commonFormat: AVAudioCommonFormat =
            format.sampleRepresentation == .signedInt16 ? .pcmFormatInt16 : .pcmFormatFloat32
        let processingFormat = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: true
        )
        guard let processingFormat else {
            throw MeetingRawAudioCaptureError.alacEncodingFailed(
                "could not create the source processing format"
            )
        }
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: settings,
            commonFormat: commonFormat,
            interleaved: true
        )
        let input = try FileHandle(forReadingFrom: pcmURL)
        defer { try? input.close() }
        let framesPerBuffer = 16_384
        let bytesPerFrame = format.bytesPerFrame
        var framesWritten = 0
        while framesWritten < expectedFrames {
            let requestedFrames = min(framesPerBuffer, expectedFrames - framesWritten)
            let data = try input.read(upToCount: requestedFrames * bytesPerFrame) ?? Data()
            guard data.count == requestedFrames * bytesPerFrame else {
                throw MeetingRawAudioCaptureError.alacEncodingFailed(
                    "PCM journal ended before frame \(framesWritten + requestedFrames)"
                )
            }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: AVAudioFrameCount(requestedFrames)
            ) else {
                throw MeetingRawAudioCaptureError.alacEncodingFailed(
                    "could not allocate an encoder buffer"
                )
            }
            buffer.frameLength = AVAudioFrameCount(requestedFrames)
            let audioBuffers = UnsafeMutableAudioBufferListPointer(
                buffer.mutableAudioBufferList
            )
            guard audioBuffers.count == 1,
                  let destination = audioBuffers[0].mData else {
                throw MeetingRawAudioCaptureError.alacEncodingFailed(
                    "encoder buffer was not interleaved"
                )
            }
            data.copyBytes(
                to: destination.assumingMemoryBound(to: UInt8.self),
                count: data.count
            )
            audioBuffers[0].mDataByteSize = UInt32(data.count)
            try output.write(from: buffer)
            framesWritten += requestedFrames
        }
    }

    private static func digest(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func durationNanoseconds(frames: Int, sampleRate: Double) -> Int64 {
        Self.durationNanoseconds(frames: frames, sampleRate: sampleRate)
    }

    private static func durationNanoseconds(frames: Int, sampleRate: Double) -> Int64 {
        guard sampleRate > 0 else { return 0 }
        return Int64((Double(frames) / sampleRate * 1_000_000_000).rounded())
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
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
