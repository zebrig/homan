import CryptoKit
import Foundation

enum HomanWhisperBatchCheckpointError: Error, LocalizedError, Equatable {
    case incompatibleManifest
    case unsafePath(String)
    case missingItem(String)
    case changedItem(String)

    var errorDescription: String? {
        switch self {
        case .incompatibleManifest:
            return "The saved Homan Whisper preparation does not match this recording."
        case .unsafePath(let path):
            return "The saved Homan Whisper preparation contains an unsafe path: \(path)."
        case .missingItem(let id):
            return "The saved Homan Whisper audio item is missing: \(id)."
        case .changedItem(let id):
            return "The saved Homan Whisper audio item changed after preparation: \(id)."
        }
    }
}

/// Durable, recording-scoped preparation for a Homan Whisper request.
///
/// The checkpoint lives inside `Meeting Processing/<meeting>/<session>`, so the
/// existing recovery retention and deletion rules own its complete lifecycle.
/// A network failure or response-decoding failure can therefore retry the exact
/// prepared AAC items without running AEC, VAD, or AAC encoding again.
struct HomanWhisperBatchCheckpoint: Sendable {
    static let currentSchemaVersion = 1
    static let directoryName = "homan-whisper-batch-v1"
    static let responseFilename = "response.json"

    struct StoredItem: Codable, Equatable, Sendable {
        let id: String
        let source: MeetingAudioSourceRole
        let start: TimeInterval
        let end: TimeInterval
        let relativePath: String
        let byteCount: Int64
        let sha256: String
    }

    struct Manifest: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let meetingID: Int64
        let sessionID: UUID
        let sourceManifestSchemaVersion: Int
        let finalModelID: ASRModelID
        let sampleRate: Int
        let microphoneSampleCount: Int
        let systemSampleCount: Int
        let preprocessing: MeetingRecordingPreprocessingDescriptor?
        let requestID: UUID
        let createdAt: Date
        let items: [StoredItem]
    }

    final class Builder: @unchecked Sendable {
        let requestID: UUID
        let stagingDirectoryURL: URL
        let itemsDirectoryURL: URL

        private let stagedAudio: MeetingStagedAudio
        private let fileManager: FileManager
        private var committed = false

        fileprivate init(
            stagedAudio: MeetingStagedAudio,
            fileManager: FileManager
        ) throws {
            self.stagedAudio = stagedAudio
            self.fileManager = fileManager
            requestID = UUID()
            stagingDirectoryURL = stagedAudio.directoryURL.appendingPathComponent(
                ".\(Self.buildingPrefix)\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            itemsDirectoryURL = stagingDirectoryURL.appendingPathComponent(
                "items",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: itemsDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        deinit {
            guard !committed else { return }
            try? fileManager.removeItem(at: stagingDirectoryURL)
        }

        func itemURL(at index: Int) -> URL {
            itemsDirectoryURL.appendingPathComponent(
                String(format: "%04d.m4a", index)
            )
        }

        func commit(items: [RemoteMeetingSpeechItem]) throws -> HomanWhisperBatchCheckpoint {
            var seen = Set<String>()
            let storedItems = try items.map { item -> StoredItem in
                guard seen.insert(item.id).inserted else {
                    throw HomanWhisperBatchCheckpointError.changedItem(item.id)
                }
                let standardizedItem = item.audioURL.standardizedFileURL
                let standardizedItemsDirectory = itemsDirectoryURL.standardizedFileURL
                guard standardizedItem.path.hasPrefix(standardizedItemsDirectory.path + "/"),
                      standardizedItem.pathExtension.lowercased() == "m4a" else {
                    throw HomanWhisperBatchCheckpointError.unsafePath(item.audioURL.path)
                }
                let values = try standardizedItem.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                )
                guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                    throw HomanWhisperBatchCheckpointError.missingItem(item.id)
                }
                return StoredItem(
                    id: item.id,
                    source: item.source,
                    start: item.start,
                    end: item.end,
                    relativePath: "items/\(standardizedItem.lastPathComponent)",
                    byteCount: Int64(size),
                    sha256: try Self.digest(of: standardizedItem)
                )
            }
            let manifest = Manifest(
                schemaVersion: HomanWhisperBatchCheckpoint.currentSchemaVersion,
                meetingID: stagedAudio.manifest.meetingID,
                sessionID: stagedAudio.manifest.sessionID,
                sourceManifestSchemaVersion: stagedAudio.manifest.schemaVersion,
                finalModelID: stagedAudio.manifest.finalModelID,
                sampleRate: stagedAudio.manifest.sampleRate,
                microphoneSampleCount: stagedAudio.manifest.microphoneSampleCount,
                systemSampleCount: stagedAudio.manifest.systemSampleCount,
                preprocessing: stagedAudio.manifest.preprocessing,
                requestID: requestID,
                createdAt: Date(),
                items: storedItems
            )
            let manifestURL = stagingDirectoryURL.appendingPathComponent("manifest.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: manifestURL.path
            )

            let finalDirectory = HomanWhisperBatchCheckpoint.directoryURL(for: stagedAudio)
            if fileManager.fileExists(atPath: finalDirectory.path) {
                try fileManager.removeItem(at: finalDirectory)
            }
            try fileManager.moveItem(at: stagingDirectoryURL, to: finalDirectory)
            do {
                let checkpoint = try HomanWhisperBatchCheckpoint.load(
                    for: stagedAudio,
                    fileManager: fileManager
                )
                committed = true
                return checkpoint
            } catch {
                try? fileManager.removeItem(at: finalDirectory)
                throw error
            }
        }

        private static let buildingPrefix = "homan-whisper-batch-building-"

        fileprivate static func removeAbandonedBuilds(
            for stagedAudio: MeetingStagedAudio,
            fileManager: FileManager
        ) {
            guard let children = try? fileManager.contentsOfDirectory(
                at: stagedAudio.directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants]
            ) else { return }
            for child in children where child.lastPathComponent.hasPrefix(".\(buildingPrefix)") {
                try? fileManager.removeItem(at: child)
            }
        }

        fileprivate static func digest(of url: URL) throws -> String {
            let digest = SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    let directoryURL: URL
    let manifestURL: URL
    let responseURL: URL
    let manifest: Manifest
    let items: [RemoteMeetingSpeechItem]

    var requestID: UUID { manifest.requestID }

    static func begin(
        for stagedAudio: MeetingStagedAudio,
        fileManager: FileManager = .default
    ) throws -> Builder {
        Builder.removeAbandonedBuilds(for: stagedAudio, fileManager: fileManager)
        return try Builder(stagedAudio: stagedAudio, fileManager: fileManager)
    }

    static func load(
        for stagedAudio: MeetingStagedAudio,
        fileManager: FileManager = .default
    ) throws -> HomanWhisperBatchCheckpoint {
        let directoryURL = directoryURL(for: stagedAudio)
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == currentSchemaVersion,
              manifest.meetingID == stagedAudio.manifest.meetingID,
              manifest.sessionID == stagedAudio.manifest.sessionID,
              manifest.sourceManifestSchemaVersion == stagedAudio.manifest.schemaVersion,
              manifest.finalModelID == stagedAudio.manifest.finalModelID,
              manifest.sampleRate == stagedAudio.manifest.sampleRate,
              manifest.microphoneSampleCount == stagedAudio.manifest.microphoneSampleCount,
              manifest.systemSampleCount == stagedAudio.manifest.systemSampleCount,
              manifest.preprocessing == stagedAudio.manifest.preprocessing,
              !manifest.items.isEmpty,
              manifest.items.count <= 2_048 else {
            throw HomanWhisperBatchCheckpointError.incompatibleManifest
        }

        var seen = Set<String>()
        let items = try manifest.items.map { stored -> RemoteMeetingSpeechItem in
            guard !stored.id.isEmpty,
                  seen.insert(stored.id).inserted,
                  stored.start.isFinite,
                  stored.end.isFinite,
                  stored.start >= 0,
                  stored.end > stored.start,
                  stored.end - stored.start <= 35.001,
                  stored.byteCount > 0,
                  stored.sha256.count == 64 else {
                throw HomanWhisperBatchCheckpointError.changedItem(stored.id)
            }
            let itemURL = directoryURL.appendingPathComponent(stored.relativePath)
                .standardizedFileURL
            guard Self.isSafeItemURL(itemURL, in: directoryURL),
                  itemURL.pathExtension.lowercased() == "m4a" else {
                throw HomanWhisperBatchCheckpointError.unsafePath(stored.relativePath)
            }
            let values = try itemURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                  Int64(values.fileSize ?? -1) == stored.byteCount else {
                throw HomanWhisperBatchCheckpointError.missingItem(stored.id)
            }
            guard try Builder.digest(of: itemURL) == stored.sha256 else {
                throw HomanWhisperBatchCheckpointError.changedItem(stored.id)
            }
            return RemoteMeetingSpeechItem(
                id: stored.id,
                source: stored.source,
                start: stored.start,
                end: stored.end,
                audioURL: itemURL
            )
        }
        return HomanWhisperBatchCheckpoint(
            directoryURL: directoryURL,
            manifestURL: manifestURL,
            responseURL: directoryURL.appendingPathComponent(responseFilename),
            manifest: manifest,
            items: items
        )
    }

    static func discard(
        for stagedAudio: MeetingStagedAudio,
        fileManager: FileManager = .default
    ) {
        let url = directoryURL(for: stagedAudio)
        guard url.standardizedFileURL.path.hasPrefix(
            stagedAudio.directoryURL.standardizedFileURL.path + "/"
        ) else { return }
        try? fileManager.removeItem(at: url)
        Builder.removeAbandonedBuilds(for: stagedAudio, fileManager: fileManager)
    }

    private static func directoryURL(for stagedAudio: MeetingStagedAudio) -> URL {
        stagedAudio.directoryURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func isSafeItemURL(_ itemURL: URL, in directoryURL: URL) -> Bool {
        let itemRoot = directoryURL.appendingPathComponent("items", isDirectory: true)
            .standardizedFileURL
        return itemURL.standardizedFileURL.path.hasPrefix(itemRoot.path + "/")
    }
}
