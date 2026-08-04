import Foundation
import MuesliCore

struct MeetingRecordingRecoveryReport: Equatable, Sendable {
    var removedPendingDirectories = 0
    var registeredPublishedBundles = 0
    var markedDanglingLinks = 0
    var removedUnreferencedBundles = 0
    var removedRedundantStagingSessions = 0

    var didChange: Bool {
        removedPendingDirectories > 0
            || registeredPublishedBundles > 0
            || markedDanglingLinks > 0
            || removedUnreferencedBundles > 0
            || removedRedundantStagingSessions > 0
    }
}

enum MeetingRecordingRecoveryService {
    static func reconcile(
        store: DictationStore,
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> MeetingRecordingRecoveryReport {
        var report = MeetingRecordingRecoveryReport()
        var units = try store.allMeetingRecordingUnits()
        var referencedBundlePaths = Set(
            units.compactMap { $0.sourceBundle?.bundlePath }
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        )

        for unit in units {
            guard let sourceBundle = unit.sourceBundle else { continue }
            let bundleURL = URL(fileURLWithPath: sourceBundle.bundlePath).standardizedFileURL
            guard fileManager.fileExists(atPath: bundleURL.path) else {
                try store.updateMeetingRecordingSourceBundleState(
                    recordingID: unit.recording.id,
                    sourceState: .invalid,
                    verifiedAt: Date(),
                    errorMessage: "Source bundle directory is missing."
                )
                report.markedDanglingLinks += 1
                continue
            }
            do {
                let bundle = try MeetingRecordingBundle.load(
                    directoryURL: bundleURL,
                    supportDirectory: supportDirectory,
                    fileManager: fileManager
                )
                try store.updateMeetingRecordingSourceBundleState(
                    recordingID: unit.recording.id,
                    sourceState: bundle.sourceState,
                    verifiedAt: Date(),
                    errorMessage: bundle.degradations.isEmpty
                        ? nil
                        : String(describing: bundle.degradations)
                )
            } catch {
                try store.updateMeetingRecordingSourceBundleState(
                    recordingID: unit.recording.id,
                    sourceState: .invalid,
                    verifiedAt: Date(),
                    errorMessage: error.localizedDescription
                )
            }
        }

        let sourceRoot = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
            .appendingPathComponent(MeetingRecordingBundle.sourceDirectoryName, isDirectory: true)
        let entries = (try? fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        for entry in entries {
            if entry.lastPathComponent.hasPrefix(".pending-") {
                try? fileManager.removeItem(at: entry)
                report.removedPendingDirectories += 1
                continue
            }
            let path = entry.standardizedFileURL.path
            guard !referencedBundlePaths.contains(path) else { continue }
            do {
                let bundle = try MeetingRecordingBundle.load(
                    directoryURL: entry,
                    supportDirectory: supportDirectory,
                    fileManager: fileManager
                )
                let playbackPath = bundle.manifest.playback?.relativeOrAbsolutePath
                let playbackExists = playbackPath.map {
                    fileManager.fileExists(atPath: URL(fileURLWithPath: $0).path)
                } ?? false
                let meetingExists = try store.meeting(id: bundle.manifest.meetingID) != nil
                if let playbackPath, playbackExists, meetingExists {
                    _ = try store.registerMeetingRecordingWithSourceBundle(
                        meetingID: bundle.manifest.meetingID,
                        playbackPath: playbackPath,
                        createdAt: bundle.manifest.startedAt,
                        deleteAfter: nil,
                        bundlePath: entry.path,
                        schemaVersion: bundle.manifest.schemaVersion,
                        sourceState: bundle.sourceState,
                        lastVerifiedAt: Date(),
                        lastErrorMessage: bundle.degradations.isEmpty
                            ? nil
                            : String(describing: bundle.degradations)
                    )
                    referencedBundlePaths.insert(path)
                    report.registeredPublishedBundles += 1
                } else {
                    try fileManager.removeItem(at: entry)
                    report.removedUnreferencedBundles += 1
                }
            } catch {
                // A directory without a valid manifest cannot be proven to own
                // user media, so leave it for manual inspection.
                continue
            }
        }

        units = try store.allMeetingRecordingUnits()
        let registeredSessionIDs = Set(units.compactMap { unit -> UUID? in
            guard let path = unit.sourceBundle?.bundlePath else { return nil }
            return UUID(
                uuidString: URL(fileURLWithPath: path).lastPathComponent
            )
        })
        for staged in MeetingProcessingCapture.recoverableSessions(
            supportDirectory: supportDirectory
        ) where registeredSessionIDs.contains(staged.manifest.sessionID) {
            MeetingProcessingCapture.discard(staged)
            report.removedRedundantStagingSessions += 1
        }
        for staged in MeetingRawAudioCapture.recoverableSessions(
            supportDirectory: supportDirectory
        ) where registeredSessionIDs.contains(staged.manifest.sessionID) {
            MeetingRawAudioCapture.discard(staged)
            report.removedRedundantStagingSessions += 1
        }
        return report
    }
}
