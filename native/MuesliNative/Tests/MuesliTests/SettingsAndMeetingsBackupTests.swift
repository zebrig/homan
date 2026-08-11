import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Settings import/export")
struct SettingsImportExportTests {
    private func makeConfig() -> AppConfig {
        var config = AppConfig()
        config.userName = "Test User"
        config.homanWhisperEndpoint = "https://whisper.example.com"
        config.homanWhisperAPIKey = "sk-123"
        config.ollamaURL = "http://ollama.local:11434"
        config.gemmaSummaryModel = "gemma-4-e4b-qat-ud-q4_k_xl"
        return config
    }

    @Test("settings round-trip preserves provider fields and the summary model")
    func settingsRoundTrip() throws {
        let config = makeConfig()
        let data = try SettingsFileIO.exportData(config: config, includeSecrets: true)
        let envelope = try SettingsFileIO.decodeEnvelope(data)

        #expect(envelope.format == "homan-settings")
        #expect(envelope.settings["user_name"] == .string("Test User"))
        #expect(envelope.settings["homan_whisper_endpoint"] == .string("https://whisper.example.com"))
        #expect(envelope.settings["homan_whisper_api_key"] == .string("sk-123"))
        #expect(envelope.settings["gemma_summary_model"] == .string("gemma-4-e4b-qat-ud-q4_k_xl"))

        let merged = SettingsFileIO.mergedConfig(config, envelope: envelope)
        #expect(merged.userName == "Test User")
        #expect(merged.homanWhisperEndpoint == "https://whisper.example.com")
        #expect(merged.homanWhisperAPIKey == "sk-123")
        #expect(merged.ollamaURL == "http://ollama.local:11434")
        #expect(merged.gemmaSummaryModel == "gemma-4-e4b-qat-ud-q4_k_xl")
    }

    @Test("redacted export drops API keys but keeps safe settings")
    func settingsRedaction() throws {
        var config = AppConfig()
        config.homanWhisperAPIKey = "sk-123"
        config.openRouterAPIKey = "or-456"
        config.userName = "Safe Name"

        let redacted = try SettingsFileIO.exportData(config: config, includeSecrets: false)
        let envelope = try SettingsFileIO.decodeEnvelope(redacted)
        #expect(envelope.settings["homan_whisper_api_key"] == nil)
        #expect(envelope.settings["openrouter_api_key"] == nil)
        #expect(envelope.settings["user_name"] == .string("Safe Name"))

        let full = try SettingsFileIO.exportData(config: config, includeSecrets: true)
        let fullEnvelope = try SettingsFileIO.decodeEnvelope(full)
        #expect(fullEnvelope.settings["homan_whisper_api_key"] == .string("sk-123"))
        #expect(fullEnvelope.settings["openrouter_api_key"] == .string("or-456"))
    }

    @Test("merge keeps existing API key when the imported value is empty")
    func settingsMergeKeepsExistingForEmptyKey() {
        var current = AppConfig()
        current.homanWhisperAPIKey = "current-key"
        let envelope = SettingsFileIO.Envelope(
            appVersion: "0.8.1",
            exportedAt: Date(),
            settings: [
                "homan_whisper_api_key": .string(""),
                "user_name": .string("New"),
            ]
        )
        let merged = SettingsFileIO.mergedConfig(current, envelope: envelope)
        #expect(merged.homanWhisperAPIKey == "current-key")
        #expect(merged.userName == "New")
    }

    @Test("import rejects a newer format version")
    func settingsRejectsNewerVersion() throws {
        var envelope = SettingsFileIO.Envelope(appVersion: "0.8.1", exportedAt: Date(), settings: [:])
        envelope.version = SettingsFileIO.formatVersion + 1
        let data = try JSONEncoder().encode(envelope)
        #expect(throws: SettingsFileIO.ImportError.self) {
            try SettingsFileIO.decodeEnvelope(data)
        }
    }
}

@Suite("Meetings backup")
struct MeetingsBackupTests {
    /// Creates a DictationStore backed by a temporary database file.
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-backup-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeEntry() -> MeetingBackupEntry {
        MeetingBackupEntry(
            sourceID: 5,
            title: "Backup Test",
            startTime: "2026-08-06T10:00:00Z",
            durationSeconds: 600,
            rawTranscript: "Hello world",
            formattedNotes: "Meeting notes",
            wordCount: 2,
            folderID: 1,
            calendarEventID: nil,
            calendarOccurrence: nil,
            recordingRetentionProtected: false,
            status: .completed,
            manualNotes: "Manual note",
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: nil,
            source: .meeting,
            followUpToID: nil,
            followUpToRecordName: nil,
            processingMetadata: .empty
        )
    }

    @Test("backup round-trips meeting fields and carries no audio paths")
    func backupRoundTrip() throws {
        let store = try makeStore()
        let folder = MeetingFolder(id: 1, name: "Work", parentID: nil, createdAt: "2026-08-06T10:00:00Z")
        let envelope = MeetingBackup.Envelope(
            exportedAt: Date(),
            folders: [folder],
            meetings: [makeEntry()]
        )

        let data = try MeetingBackup.exportData(meetings: envelope.meetings, folders: envelope.folders)
        let decoded = try MeetingBackup.decodeEnvelope(data)
        #expect(decoded.meetings.count == 1)
        #expect(decoded.meetings[0].title == "Backup Test")
        #expect(decoded.meetings[0].rawTranscript == "Hello world")
        #expect(decoded.meetings[0].formattedNotes == "Meeting notes")
        #expect(decoded.meetings[0].manualNotes == "Manual note")
        #expect(decoded.meetings[0].status == .completed)
        // MeetingBackupEntry has no audio fields by construction (text-only).
        #expect(decoded.folders.count == 1)

        let result = try MeetingBackup.importBackup(decoded, store: store)
        #expect(result.imported == 1)
        #expect(result.skipped == 0)

        let meetings = try store.recentMeetings(limit: nil)
        #expect(meetings.count == 1)
        let restored = meetings[0]
        #expect(restored.title == "Backup Test")
        #expect(restored.rawTranscript == "Hello world")
        #expect(restored.formattedNotes == "Meeting notes")
        #expect(restored.manualNotes == "Manual note")
        #expect(restored.status == .completed)
        #expect(restored.folderID != nil)

        let folders = try store.listFolders()
        #expect(folders.count == 1)
        #expect(folders[0].name == "Work")
        #expect(restored.folderID == folders[0].id)
    }

    @Test("re-import onto the same store yields fresh rows (duplicates, accepted)")
    func reimportYieldsNewRows() throws {
        let store = try makeStore()
        let envelope = MeetingBackup.Envelope(
            exportedAt: Date(),
            folders: [],
            meetings: [makeEntry()]
        )
        _ = try MeetingBackup.importBackup(envelope, store: store)
        _ = try MeetingBackup.importBackup(envelope, store: store)

        let meetings = try store.recentMeetings(limit: nil)
        #expect(meetings.count == 2)
    }

    @Test("follow-up links are remapped to freshly created ids")
    func followUpRemap() throws {
        let store = try makeStore()
        var first = makeEntry()
        first.sourceID = 100
        first.followUpToID = nil
        var second = makeEntry()
        second.sourceID = 101
        second.followUpToID = 100
        let envelope = MeetingBackup.Envelope(
            exportedAt: Date(),
            folders: [],
            meetings: [second, first] // out of order on purpose
        )

        _ = try MeetingBackup.importBackup(envelope, store: store)
        let meetings = try store.recentMeetings(limit: nil)
        #expect(meetings.count == 2)

        let restoredFirst = meetings.first { $0.title == first.title && $0.followUpToID == nil }
        let restoredSecond = meetings.first { $0.title == second.title }
        #expect(restoredFirst != nil)
        #expect(restoredSecond != nil)
        #expect(restoredSecond?.followUpToID == restoredFirst?.id)
    }

    @Test("meetings import rejects a newer format version")
    func meetingsRejectsNewerVersion() throws {
        var envelope = MeetingBackup.Envelope(exportedAt: Date(), folders: [], meetings: [makeEntry()])
        envelope.version = MeetingBackup.formatVersion + 1
        let data = try JSONEncoder().encode(envelope)
        #expect(throws: MeetingBackup.ImportError.self) {
            try MeetingBackup.decodeEnvelope(data)
        }
    }
}
