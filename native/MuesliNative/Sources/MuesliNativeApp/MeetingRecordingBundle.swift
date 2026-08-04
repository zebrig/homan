@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import MuesliCore

enum MeetingRecordingTimelinePolicy: String, Codable, Sendable {
    case activeCaptureCompacted = "active_capture_compacted"
}

enum MeetingRecordingSourceEncoding: String, Codable, Sendable {
    case pcmS16LEWAV = "pcm_s16le_wav"
    case nativeLosslessEpochs = "native_lossless_epochs"
}

enum MeetingRecordingSourceAvailability: String, Codable, Sendable {
    case available
    case empty
    case missing
    case corrupt
}

struct MeetingRecordingSourceDescriptor: Codable, Equatable, Sendable {
    var role: MeetingAudioSourceRole
    var relativePath: String
    var sampleCount: Int
    var encoding: MeetingRecordingSourceEncoding
    var availability: MeetingRecordingSourceAvailability
    var contentDigest: String?
}

struct MeetingRecordingPreprocessingDescriptor: Codable, Equatable, Sendable {
    static let current = MeetingRecordingPreprocessingDescriptor(
        schemaVersion: 1,
        microphoneSignal: "dtln_aec_cleaned",
        systemSignal: "captured_system_pcm",
        pausePolicy: "stop_both_and_compact",
        sampleFormat: "signed_int16"
    )
    static let rawSources = MeetingRecordingPreprocessingDescriptor(
        schemaVersion: 2,
        microphoneSignal: "captured_microphone_before_muesli_dsp",
        systemSignal: "captured_system_before_muesli_dsp",
        pausePolicy: "timestamped_source_epochs",
        sampleFormat: "native_lossless"
    )

    let schemaVersion: Int
    let microphoneSignal: String
    let systemSignal: String
    let pausePolicy: String
    let sampleFormat: String
}

struct MeetingRecordingModelSnapshot: Codable, Equatable, Sendable {
    let modelID: ASRModelID
    let languages: MeetingLanguageSnapshot
}

struct MeetingRecordingPlaybackDescriptor: Codable, Equatable, Sendable {
    let relativeOrAbsolutePath: String
    let format: String
}

struct MeetingRecordingBundleManifest: Codable, Equatable, Sendable {
    static let legacySchemaVersion = 1
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let meetingID: Int64
    var recordingID: Int64?
    let sessionID: UUID
    let startedAt: Date
    let endedAt: Date
    let timelinePolicy: MeetingRecordingTimelinePolicy
    let sampleRate: Int
    let channelsPerSource: Int
    var microphone: MeetingRecordingSourceDescriptor
    var system: MeetingRecordingSourceDescriptor
    let preprocessing: MeetingRecordingPreprocessingDescriptor
    let captureModelSnapshot: MeetingRecordingModelSnapshot?
    var playback: MeetingRecordingPlaybackDescriptor?
    var rawAudio: MeetingRawAudioManifest?
}

enum MeetingRecordingBundleError: Error, LocalizedError {
    case directoryOutsideManagedRoot
    case missingManifest
    case unsupportedSchemaVersion(Int)
    case invalidRelativePath(String)
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .directoryOutsideManagedRoot:
            return "The meeting source bundle is outside Homan's managed recording directory."
        case .missingManifest:
            return "The meeting source bundle manifest is missing."
        case .unsupportedSchemaVersion(let version):
            return "The meeting source bundle version \(version) is not supported."
        case .invalidRelativePath(let path):
            return "The meeting source bundle contains an unsafe source path: \(path)"
        case .invalidManifest(let reason):
            return "The meeting source bundle is invalid: \(reason)"
        }
    }
}

struct MeetingRecordingBundle: Sendable {
    static let manifestFilename = "manifest.json"
    static let sourceDirectoryName = "sources"

    let directoryURL: URL
    let manifestURL: URL
    let manifest: MeetingRecordingBundleManifest
    let microphoneURL: URL?
    let systemURL: URL?
    let rawAudio: MeetingStagedRawAudio?
    let degradations: [MeetingProcessingDegradation]
    let sourceState: MeetingRecordingSourceState

    static func load(
        directoryURL: URL,
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> MeetingRecordingBundle {
        let managedRoot = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
            .appendingPathComponent(sourceDirectoryName, isDirectory: true)
            .standardizedFileURL
        let directory = directoryURL.standardizedFileURL
        guard directory.path.hasPrefix(managedRoot.path + "/") else {
            throw MeetingRecordingBundleError.directoryOutsideManagedRoot
        }

        let manifestURL = directory.appendingPathComponent(manifestFilename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MeetingRecordingBundleError.missingManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: MeetingRecordingBundleManifest
        do {
            manifest = try decoder.decode(
                MeetingRecordingBundleManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw MeetingRecordingBundleError.invalidManifest(error.localizedDescription)
        }
        guard manifest.schemaVersion == MeetingRecordingBundleManifest.legacySchemaVersion
                || manifest.schemaVersion == MeetingRecordingBundleManifest.currentSchemaVersion else {
            throw MeetingRecordingBundleError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        if manifest.schemaVersion == MeetingRecordingBundleManifest.currentSchemaVersion {
            return try loadRawBundle(
                directory: directory,
                manifestURL: manifestURL,
                manifest: manifest,
                fileManager: fileManager
            )
        }
        guard manifest.sampleRate == MeetingProcessingCapture.sampleRate,
              manifest.channelsPerSource == MeetingProcessingCapture.channels else {
            throw MeetingRecordingBundleError.invalidManifest("unsupported audio format")
        }
        guard manifest.microphone.role == .microphone,
              manifest.system.role == .system else {
            throw MeetingRecordingBundleError.invalidManifest("source roles do not match their descriptors")
        }

        var degradations: [MeetingProcessingDegradation] = []
        let microphoneURL = try resolve(
            descriptor: manifest.microphone,
            in: directory,
            expectedRole: .microphone,
            degradations: &degradations,
            fileManager: fileManager
        )
        let systemURL = try resolve(
            descriptor: manifest.system,
            in: directory,
            expectedRole: .system,
            degradations: &degradations,
            fileManager: fileManager
        )
        let sourceState: MeetingRecordingSourceState
        if microphoneURL == nil, systemURL == nil {
            sourceState = .invalid
        } else if degradations.isEmpty {
            sourceState = .complete
        } else {
            sourceState = .degraded
        }
        return MeetingRecordingBundle(
            directoryURL: directory,
            manifestURL: manifestURL,
            manifest: manifest,
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            rawAudio: nil,
            degradations: degradations,
            sourceState: sourceState
        )
    }

    private static func loadRawBundle(
        directory: URL,
        manifestURL: URL,
        manifest: MeetingRecordingBundleManifest,
        fileManager: FileManager
    ) throws -> MeetingRecordingBundle {
        guard var rawManifest = manifest.rawAudio else {
            throw MeetingRecordingBundleError.invalidManifest(
                "schema version 2 is missing raw audio metadata"
            )
        }
        guard rawManifest.schemaVersion == MeetingRawAudioManifest.currentSchemaVersion,
              rawManifest.meetingID == manifest.meetingID,
              rawManifest.sessionID == manifest.sessionID else {
            throw MeetingRecordingBundleError.invalidManifest(
                "raw audio identity does not match the bundle"
            )
        }

        var degradations: [MeetingProcessingDegradation] = []
        rawManifest.microphoneEpochs = validatedRawEpochs(
            rawManifest.microphoneEpochs,
            role: .microphone,
            directory: directory,
            degradations: &degradations,
            fileManager: fileManager
        )
        rawManifest.systemEpochs = validatedRawEpochs(
            rawManifest.systemEpochs,
            role: .system,
            directory: directory,
            degradations: &degradations,
            fileManager: fileManager
        )
        let hasMicrophone = !rawManifest.microphoneEpochs.isEmpty
        let hasSystem = !rawManifest.systemEpochs.isEmpty
        if !hasMicrophone, !degradations.contains(.sourceMissing(.microphone)),
           !degradations.contains(.sourceCorrupt(.microphone)) {
            degradations.append(.sourceEmpty(.microphone))
        }
        if !hasSystem, !degradations.contains(.sourceMissing(.system)),
           !degradations.contains(.sourceCorrupt(.system)) {
            degradations.append(.sourceEmpty(.system))
        }
        let sourceState: MeetingRecordingSourceState
        if !hasMicrophone, !hasSystem {
            sourceState = .invalid
        } else if degradations.isEmpty {
            sourceState = .complete
        } else {
            sourceState = .degraded
        }
        return MeetingRecordingBundle(
            directoryURL: directory,
            manifestURL: manifestURL,
            manifest: manifest,
            microphoneURL: nil,
            systemURL: nil,
            rawAudio: MeetingStagedRawAudio(
                directoryURL: directory,
                manifestURL: manifestURL,
                manifest: rawManifest
            ),
            degradations: degradations,
            sourceState: sourceState
        )
    }

    private static func validatedRawEpochs(
        _ epochs: [MeetingRawAudioEpoch],
        role: MeetingAudioSourceRole,
        directory: URL,
        degradations: inout [MeetingProcessingDegradation],
        fileManager: FileManager
    ) -> [MeetingRawAudioEpoch] {
        var valid: [MeetingRawAudioEpoch] = []
        for epoch in epochs where epoch.role == role && epoch.frameCount > 0 {
            guard isSafeRawRelativePath(epoch.relativePath) else {
                degradations.append(.sourceCorrupt(role))
                continue
            }
            let url = directory.appendingPathComponent(epoch.relativePath)
                .standardizedFileURL
            guard url.path.hasPrefix(directory.path + "/"),
                  fileManager.fileExists(atPath: url.path) else {
                degradations.append(.sourceMissing(role))
                continue
            }
            let resolvedURL = url.resolvingSymlinksInPath()
            let resolvedDirectory = directory.resolvingSymlinksInPath()
            guard resolvedURL.path.hasPrefix(resolvedDirectory.path + "/"),
                  isValidRawEpoch(epoch, at: resolvedURL, fileManager: fileManager),
                  epoch.contentDigest.map({ fileDigest(at: resolvedURL) == $0.lowercased() })
                    ?? true else {
                degradations.append(.sourceCorrupt(role))
                continue
            }
            valid.append(epoch)
        }
        return valid
    }

    private static func isSafeRawRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && URL(fileURLWithPath: path).pathComponents.allSatisfy { $0 != ".." }
    }

    private static func isValidRawEpoch(
        _ epoch: MeetingRawAudioEpoch,
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        switch epoch.encoding {
        case .pcmJournal:
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let bytes = (attributes[.size] as? NSNumber)?.intValue else {
                return false
            }
            return epoch.format.bytesPerFrame > 0
                && bytes == epoch.frameCount * epoch.format.bytesPerFrame
        case .appleLossless:
            guard let file = try? AVAudioFile(forReading: url) else { return false }
            return Int(file.length) == epoch.frameCount
                && Int(file.fileFormat.channelCount) == epoch.format.channelCount
                && abs(file.fileFormat.sampleRate - epoch.format.sampleRate) < 0.5
        }
    }

    private static func resolve(
        descriptor: MeetingRecordingSourceDescriptor,
        in directory: URL,
        expectedRole: MeetingAudioSourceRole,
        degradations: inout [MeetingProcessingDegradation],
        fileManager: FileManager
    ) throws -> URL? {
        let relativePath = descriptor.relativePath
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              URL(fileURLWithPath: relativePath).pathComponents.allSatisfy({ $0 != ".." }) else {
            throw MeetingRecordingBundleError.invalidRelativePath(relativePath)
        }
        let url = directory.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/") else {
            throw MeetingRecordingBundleError.invalidRelativePath(relativePath)
        }
        if descriptor.sampleCount == 0 || descriptor.availability == .empty {
            degradations.append(.sourceEmpty(expectedRole))
            return nil
        }
        guard fileManager.fileExists(atPath: url.path) else {
            degradations.append(.sourceMissing(expectedRole))
            return nil
        }
        let resolvedURL = url.resolvingSymlinksInPath()
        let resolvedDirectory = directory.resolvingSymlinksInPath()
        guard resolvedURL.path.hasPrefix(resolvedDirectory.path + "/") else {
            throw MeetingRecordingBundleError.invalidRelativePath(relativePath)
        }
        guard isValidPCM16MonoWAV(
            at: resolvedURL,
            expectedSampleRate: 16_000,
            expectedSampleCount: descriptor.sampleCount
        ) else {
            degradations.append(.sourceCorrupt(expectedRole))
            return nil
        }
        if let expectedDigest = descriptor.contentDigest,
           fileDigest(at: resolvedURL) != expectedDigest.lowercased() {
            degradations.append(.sourceCorrupt(expectedRole))
            return nil
        }
        return resolvedURL
    }

    private static func isValidPCM16MonoWAV(
        at url: URL,
        expectedSampleRate: Int,
        expectedSampleCount: Int
    ) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE",
              String(data: data[12..<16], encoding: .ascii) == "fmt ",
              String(data: data[36..<40], encoding: .ascii) == "data",
              readUInt16LE(data, at: 20) == 1,
              readUInt16LE(data, at: 22) == 1,
              readUInt32LE(data, at: 24) == UInt32(expectedSampleRate),
              readUInt16LE(data, at: 34) == 16 else {
            return false
        }
        let declaredDataBytes = Int(readUInt32LE(data, at: 40))
        guard declaredDataBytes >= 0,
              declaredDataBytes <= data.count - 44,
              declaredDataBytes.isMultiple(of: MemoryLayout<Int16>.size) else {
            return false
        }
        return declaredDataBytes / MemoryLayout<Int16>.size == expectedSampleCount
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func fileDigest(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
