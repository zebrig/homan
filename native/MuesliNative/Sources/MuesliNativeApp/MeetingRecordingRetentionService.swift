import Foundation
import MuesliCore

enum MeetingRecordingDeletionOutcome: Equatable {
    case deleted
    case deferred
    case notFound
}

enum MeetingRecordingRetentionError: Error, LocalizedError {
    case unsafeManagedPath(String)

    var errorDescription: String? {
        switch self {
        case .unsafeManagedPath(let path):
            return "Refusing to delete meeting audio outside Homan's managed storage: \(path)"
        }
    }
}

enum MeetingRecordingRetentionService {
    static func deleteStaging(
        meetingID: Int64,
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try MeetingRawAudioCapture.discardAll(
            meetingID: meetingID,
            supportDirectory: supportDirectory,
            fileManager: fileManager
        )
        try MeetingProcessingCapture.discardAll(
            meetingID: meetingID,
            supportDirectory: supportDirectory
        )
    }

    static func deleteAllStaging(
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let roots = [
            rawProcessingRoot(supportDirectory),
            processingRoot(supportDirectory)
        ]
        for root in roots {
            try requireManaged(
                root,
                under: supportDirectory,
                allowRoot: false
            )
        }
        for root in roots where fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }

    static func delete(
        recording: MeetingRecordingRecord,
        store: DictationStore,
        supportDirectory: URL,
        leaseRegistry: MeetingRecordingLeaseRegistry = .shared,
        fileManager: FileManager = .default
    ) throws -> MeetingRecordingDeletionOutcome {
        guard let lease = leaseRegistry.acquireDeletion(
            for: .recordingID(recording.id)
        ) else {
            return .deferred
        }
        defer { lease.release() }

        let unit = try store.meetingRecordingUnits(meetingID: recording.meetingID)
            .first { $0.recording.id == recording.id }
        guard let unit else { return .notFound }

        let playbackURL = URL(fileURLWithPath: unit.recording.path).standardizedFileURL
        let playbackIsShared = try store.hasMeetingRecordingReference(
            toPath: unit.recording.path,
            excludingRecordingID: unit.recording.id
        )
        let waveformURL = try? RecordingWaveformCacheFiles.cacheURL(
            for: playbackURL,
            supportDirectory: supportDirectory,
            fileManager: fileManager,
            createDirectory: false
        )

        var bundleSessionID: UUID?
        var bundleURLToDelete: URL?
        if let sourceBundle = unit.sourceBundle {
            let bundleURL = URL(fileURLWithPath: sourceBundle.bundlePath).standardizedFileURL
            let bundleIsShared = try store.hasMeetingRecordingSourceBundleReference(
                toPath: sourceBundle.bundlePath,
                excludingRecordingID: unit.recording.id
            )
            if fileManager.fileExists(atPath: bundleURL.path) {
                if let bundle = try? MeetingRecordingBundle.load(
                    directoryURL: bundleURL,
                    supportDirectory: supportDirectory,
                    fileManager: fileManager
                ) {
                    bundleSessionID = bundle.manifest.sessionID
                } else {
                    bundleSessionID = UUID(uuidString: bundleURL.lastPathComponent)
                }
                if !bundleIsShared {
                    try requireManaged(
                        bundleURL,
                        under: sourceBundlesRoot(supportDirectory),
                        allowRoot: false
                    )
                    bundleURLToDelete = bundleURL
                }
            }
        }

        var stagingURLsToDelete: [URL] = []
        if let bundleSessionID {
            let derivedStagingURL = supportDirectory
                .appendingPathComponent(MeetingProcessingCapture.directoryName, isDirectory: true)
                .appendingPathComponent(String(recording.meetingID), isDirectory: true)
                .appendingPathComponent(
                    bundleSessionID.uuidString.lowercased(),
                    isDirectory: true
                )
                .standardizedFileURL
            if fileManager.fileExists(atPath: derivedStagingURL.path) {
                try requireManaged(
                    derivedStagingURL,
                    under: processingRoot(supportDirectory),
                    allowRoot: false
                )
                stagingURLsToDelete.append(derivedStagingURL)
            }
            let rawStagingURL = supportDirectory
                .appendingPathComponent(
                    MeetingRawAudioCapture.directoryName,
                    isDirectory: true
                )
                .appendingPathComponent(String(recording.meetingID), isDirectory: true)
                .appendingPathComponent(
                    bundleSessionID.uuidString.lowercased(),
                    isDirectory: true
                )
                .standardizedFileURL
            if fileManager.fileExists(atPath: rawStagingURL.path) {
                try requireManaged(
                    rawStagingURL,
                    under: rawProcessingRoot(supportDirectory),
                    allowRoot: false
                )
                stagingURLsToDelete.append(rawStagingURL)
            }
        }

        if !playbackIsShared, fileManager.fileExists(atPath: playbackURL.path) {
            try requireManaged(
                playbackURL,
                under: recordingsRoot(supportDirectory),
                allowRoot: false
            )
            if let waveformURL,
               fileManager.fileExists(atPath: waveformURL.path) {
                try requireManaged(
                    waveformURL,
                    under: RecordingWaveformCacheFiles.cacheDirectory(
                        supportDirectory: supportDirectory
                    ),
                    allowRoot: false
                )
            }
        }

        // Validate every owned path before removing the first member so an
        // unsafe legacy path cannot leave a half-deleted recording unit.
        if let bundleURLToDelete {
            try fileManager.removeItem(at: bundleURLToDelete)
        }
        for stagingURL in stagingURLsToDelete {
            try fileManager.removeItem(at: stagingURL)
        }
        if !playbackIsShared, fileManager.fileExists(atPath: playbackURL.path) {
            if let waveformURL,
               fileManager.fileExists(atPath: waveformURL.path) {
                try? fileManager.removeItem(at: waveformURL)
            }
            try fileManager.removeItem(at: playbackURL)
        }

        return try store.deleteMeetingRecording(
            id: recording.id,
            meetingID: recording.meetingID
        ) ? .deleted : .notFound
    }

    private static func requireManaged(
        _ url: URL,
        under root: URL,
        allowRoot: Bool
    ) throws {
        let candidate = url.standardizedFileURL
        let managedRoot = root.standardizedFileURL
        let isManaged = candidate.path == managedRoot.path
            ? allowRoot
            : candidate.path.hasPrefix(managedRoot.path + "/")
        guard isManaged else {
            throw MeetingRecordingRetentionError.unsafeManagedPath(candidate.path)
        }
    }

    private static func recordingsRoot(_ supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
    }

    private static func sourceBundlesRoot(_ supportDirectory: URL) -> URL {
        recordingsRoot(supportDirectory)
            .appendingPathComponent(MeetingRecordingBundle.sourceDirectoryName, isDirectory: true)
    }

    private static func processingRoot(_ supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(
            MeetingProcessingCapture.directoryName,
            isDirectory: true
        )
    }

    private static func rawProcessingRoot(_ supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(
            MeetingRawAudioCapture.directoryName,
            isDirectory: true
        )
    }
}
