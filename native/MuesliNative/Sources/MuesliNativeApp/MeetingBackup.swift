import Foundation
import MuesliCore

/// Encode/decode + orchestrate the `homan-meetings-backup` file: a text-only JSON backup of
/// meetings (transcript, notes, metadata) plus folders. No audio paths are ever carried.
enum MeetingBackup {
    static let formatName = "homan-meetings-backup"
    /// v2 adds an optional structured transcript-evidence payload to each
    /// meeting. v1 files remain valid and decode with `transcriptEvidence == nil`.
    static let formatVersion = 2

    enum ImportError: LocalizedError {
        case unsupportedFormat(String)
        case unsupportedVersion(Int)
        case invalidFile(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let f): return "Unsupported meetings backup format: \(f)"
            case .unsupportedVersion(let v): return "Meetings backup version \(v) is newer than this app supports."
            case .invalidFile(let reason): return "Invalid meetings backup: \(reason)"
            }
        }
    }

    struct Envelope: Codable, Equatable {
        var format: String = MeetingBackup.formatName
        var version: Int = MeetingBackup.formatVersion
        var exportedAt: Date
        var folders: [MeetingFolder]
        var meetings: [MeetingBackupEntry]
    }

    struct ImportPreview: Equatable {
        let meetingCount: Int
        let folderCount: Int
        let exportedAt: Date
    }

    struct ImportResult: Equatable {
        let imported: Int
        let skipped: Int
    }

    // MARK: - Export

    static func exportData(meetings: [MeetingBackupEntry], folders: [MeetingFolder]) throws -> Data {
        let envelope = Envelope(exportedAt: Date(), folders: folders, meetings: meetings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    // MARK: - Decode / preview

    static func decodeEnvelope(_ data: Data) throws -> Envelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw ImportError.invalidFile(error.localizedDescription)
        }
        guard envelope.format == formatName else {
            throw ImportError.unsupportedFormat(envelope.format)
        }
        guard envelope.version <= formatVersion else {
            throw ImportError.unsupportedVersion(envelope.version)
        }
        return envelope
    }

    static func previewImport(envelope: Envelope) -> ImportPreview {
        ImportPreview(
            meetingCount: envelope.meetings.count,
            folderCount: envelope.folders.count,
            exportedAt: envelope.exportedAt
        )
    }

    // MARK: - Import orchestration

    /// Restore a backup: insert folders first (parents before children, fresh ids), then meetings in
    /// predecessor-before-successor order, remapping `folderID`/`followUpToID` via source→new id maps.
    /// Always fresh local ids (owner decision) — no dedup.
    static func importBackup(_ envelope: Envelope, store: DictationStore) throws -> ImportResult {
        var folderMap: [Int64: Int64] = [:]
        for folder in foldersParentsFirst(envelope.folders) {
            let remappedParent = folder.parentID.flatMap { folderMap[$0] }
            let newID = try store.createFolder(name: folder.name, parentID: remappedParent)
            folderMap[folder.id] = newID
        }

        var meetingMap: [Int64: Int64] = [:]
        var imported = 0
        var skipped = 0
        for entry in meetingsPredecessorsFirst(envelope.meetings) {
            let remappedFolder = entry.folderID.flatMap { folderMap[$0] }
            let remappedFollowUp = entry.followUpToID.flatMap { meetingMap[$0] }
            do {
                let newID = try store.insertMeetingFromBackup(
                    entry: entry,
                    remappedFolderID: remappedFolder,
                    remappedFollowUpToID: remappedFollowUp
                )
                meetingMap[entry.sourceID] = newID
                imported += 1
            } catch {
                skipped += 1
                fputs("[meeting-backup] failed to restore meeting \(entry.sourceID): \(error)\n", stderr)
            }
        }
        return ImportResult(imported: imported, skipped: skipped)
    }

    // MARK: - Ordering helpers

    private static func foldersParentsFirst(_ folders: [MeetingFolder]) -> [MeetingFolder] {
        var remaining = folders
        var ordered: [MeetingFolder] = []
        var placed: Set<Int64> = []
        var progressed = true
        while progressed {
            progressed = false
            for (index, folder) in remaining.enumerated() {
                if folder.parentID == nil || placed.contains(folder.parentID!) {
                    ordered.append(folder)
                    placed.insert(folder.id)
                    remaining.remove(at: index)
                    progressed = true
                    break
                }
            }
            if !progressed { break } // cycle or unknown parent — emit the rest as-is
        }
        return ordered + remaining
    }

    private static func meetingsPredecessorsFirst(_ meetings: [MeetingBackupEntry]) -> [MeetingBackupEntry] {
        var remaining = meetings
        var ordered: [MeetingBackupEntry] = []
        var placed: Set<Int64> = []
        var progressed = true
        while progressed {
            progressed = false
            for (index, entry) in remaining.enumerated() {
                if entry.followUpToID == nil || placed.contains(entry.followUpToID!) {
                    ordered.append(entry)
                    placed.insert(entry.sourceID)
                    remaining.remove(at: index)
                    progressed = true
                    break
                }
            }
            if !progressed { break }
        }
        return ordered + remaining
    }
}
