import Foundation

public enum MeetingNotesState: String, Codable, Sendable {
    case missing
    case rawTranscriptFallback = "raw_transcript_fallback"
    case structuredNotes = "structured_notes"
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording
    case processing
    case completed
    case noteOnly = "note_only"
    case failed
}

public enum MeetingTemplateKind: String, Codable, Sendable {
    case auto
    case builtin
    case custom
}

public enum MeetingRecordingSavePolicy: String, Codable, CaseIterable, Sendable {
    case never
    case prompt
    case always
}

public enum MeetingSource: String, Codable, Sendable {
    case meeting
    case iOS = "ios"
    case audioImport = "audio_import"
}

/// Describes how source roles are stored inside one retained meeting file.
///
/// A nil value on older rows means that the file predates channel-aware
/// storage and must continue through the legacy mixed-audio path. Historical
/// source-bundle rows remain separately identifiable through their joined
/// bundle metadata.
public enum MeetingRecordingSourceLayout: String, Codable, Sendable {
    /// Channel 1 (left) is the cleaned microphone source and channel 2 (right)
    /// is the system-audio source.
    case separateStereoMicrophoneAndSystem = "stereo_mic_left_system_right"
    /// Channel 1 (left) contains the cleaned microphone source. Channel 2 is
    /// intentionally silent because no system samples were captured.
    case separateStereoMicrophoneOnly = "stereo_mic_left_system_silent"
    /// Channel 1 is intentionally silent and channel 2 (right) contains the
    /// system-audio source.
    case separateStereoSystemOnly = "stereo_mic_silent_system_right"

    public var hasMicrophone: Bool {
        switch self {
        case .separateStereoMicrophoneAndSystem, .separateStereoMicrophoneOnly:
            return true
        case .separateStereoSystemOnly:
            return false
        }
    }

    public var hasSystem: Bool {
        switch self {
        case .separateStereoMicrophoneAndSystem, .separateStereoSystemOnly:
            return true
        case .separateStereoMicrophoneOnly:
            return false
        }
    }
}

public struct MeetingRecordingRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: Int64
    public let meetingID: Int64
    public let path: String
    public let createdAt: Date
    public let deleteAfter: Date?
    public let sourceLayout: MeetingRecordingSourceLayout?

    public init(
        id: Int64,
        meetingID: Int64,
        path: String,
        createdAt: Date,
        deleteAfter: Date?,
        sourceLayout: MeetingRecordingSourceLayout? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.path = path
        self.createdAt = createdAt
        self.deleteAfter = deleteAfter
        self.sourceLayout = sourceLayout
    }
}

public enum MeetingRecordingSourceState: String, Codable, Sendable {
    case complete
    case degraded
    case recoveryPending = "recovery_pending"
    case invalid
}

public struct MeetingRecordingSourceBundleRecord: Codable, Sendable, Equatable {
    public let recordingID: Int64
    public let bundlePath: String
    public let schemaVersion: Int
    public let sourceState: MeetingRecordingSourceState
    public let createdAt: Date
    public let lastVerifiedAt: Date?
    public let lastError: String?

    public init(
        recordingID: Int64,
        bundlePath: String,
        schemaVersion: Int,
        sourceState: MeetingRecordingSourceState,
        createdAt: Date,
        lastVerifiedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.recordingID = recordingID
        self.bundlePath = bundlePath
        self.schemaVersion = schemaVersion
        self.sourceState = sourceState
        self.createdAt = createdAt
        self.lastVerifiedAt = lastVerifiedAt
        self.lastError = lastError
    }
}

public struct MeetingRecordingUnitRecord: Codable, Sendable, Equatable {
    public let recording: MeetingRecordingRecord
    public let sourceBundle: MeetingRecordingSourceBundleRecord?

    public init(
        recording: MeetingRecordingRecord,
        sourceBundle: MeetingRecordingSourceBundleRecord?
    ) {
        self.recording = recording
        self.sourceBundle = sourceBundle
    }
}

public enum RecordOriginFilter: String, Codable, CaseIterable, Hashable, Sendable {
    case all
    case thisMac
    case fromIPhone
}

public enum SyncTextRecordKind: String, Codable, Sendable {
    case dictation
    case meeting
}

public enum MeetingProcessingThinkingStatus: String, Codable, Sendable, Equatable {
    case used
    case notUsed = "not_used"
    case notReported = "not_reported"
}

public struct MeetingAecRunDiagnostics: Codable, Sendable, Equatable {
    public let processor: String
    public let ready: Bool
    public let processedFrames: Int
    public let fullReferenceFrames: Int
    public let partialReferenceFrames: Int
    public let missingReferenceFrames: Int
    public let sourceUnitCount: Int
    public let appliedSourceUnitCount: Int
    public let processingError: String?

    private enum CodingKeys: String, CodingKey {
        case processor
        case ready
        case processedFrames
        case fullReferenceFrames
        case partialReferenceFrames
        case missingReferenceFrames
        case sourceUnitCount
        case appliedSourceUnitCount
        case processingError
    }

    public init(
        processor: String,
        ready: Bool,
        processedFrames: Int,
        fullReferenceFrames: Int,
        partialReferenceFrames: Int,
        missingReferenceFrames: Int,
        sourceUnitCount: Int = 1,
        appliedSourceUnitCount: Int? = nil,
        processingError: String? = nil
    ) {
        self.processor = processor
        self.ready = ready
        self.processedFrames = max(processedFrames, 0)
        self.fullReferenceFrames = max(fullReferenceFrames, 0)
        self.partialReferenceFrames = max(partialReferenceFrames, 0)
        self.missingReferenceFrames = max(missingReferenceFrames, 0)
        let resolvedSourceUnitCount = max(sourceUnitCount, 0)
        self.sourceUnitCount = resolvedSourceUnitCount
        let inferredAppliedUnitCount = ready
            && processedFrames > 0
            && fullReferenceFrames + partialReferenceFrames > 0
            && processingError == nil
            ? resolvedSourceUnitCount
            : 0
        self.appliedSourceUnitCount = min(
            max(appliedSourceUnitCount ?? inferredAppliedUnitCount, 0),
            resolvedSourceUnitCount
        )
        self.processingError = processingError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            processor: container.decode(String.self, forKey: .processor),
            ready: container.decode(Bool.self, forKey: .ready),
            processedFrames: container.decode(Int.self, forKey: .processedFrames),
            fullReferenceFrames: container.decode(Int.self, forKey: .fullReferenceFrames),
            partialReferenceFrames: container.decode(Int.self, forKey: .partialReferenceFrames),
            missingReferenceFrames: container.decode(Int.self, forKey: .missingReferenceFrames),
            sourceUnitCount: container.decodeIfPresent(Int.self, forKey: .sourceUnitCount) ?? 1,
            appliedSourceUnitCount: container.decodeIfPresent(
                Int.self,
                forKey: .appliedSourceUnitCount
            ),
            processingError: container.decodeIfPresent(String.self, forKey: .processingError)
        )
    }
}

public struct MeetingProcessingRunMetadata: Codable, Sendable, Equatable {
    public let completedAt: Date
    public let durationSeconds: Double
    public let backend: String
    public let model: String
    public let displayName: String
    public let thinkingStatus: MeetingProcessingThinkingStatus?
    /// Canonical source selected for this run. Optional for 0.8.3 and older data.
    public let audioSource: String?
    /// Requested AEC model when this run actually reprocessed raw sources.
    public let aecModel: String?
    /// Actual processor outcome, including fallback or pass-through evidence.
    public let aecDiagnostics: MeetingAecRunDiagnostics?

    public init(
        completedAt: Date,
        durationSeconds: Double,
        backend: String,
        model: String,
        displayName: String,
        thinkingStatus: MeetingProcessingThinkingStatus? = nil,
        audioSource: String? = nil,
        aecModel: String? = nil,
        aecDiagnostics: MeetingAecRunDiagnostics? = nil
    ) {
        self.completedAt = completedAt
        self.durationSeconds = max(durationSeconds, 0)
        self.backend = backend
        self.model = model
        self.displayName = displayName
        self.thinkingStatus = thinkingStatus
        self.audioSource = audioSource
        self.aecModel = aecModel
        self.aecDiagnostics = aecDiagnostics
    }
}

public struct MeetingProcessingMetadata: Codable, Sendable, Equatable {
    public var transcription: MeetingProcessingRunMetadata?
    public var summary: MeetingProcessingRunMetadata?
    public var manualNotesUpdatedAt: Date?
    /// Exact transcript presentation used by the latest generated summary.
    /// Optional so metadata written by Homan 0.8.2 and older remains valid.
    public var summaryInput: MeetingSummaryInputDescriptor?

    public init(
        transcription: MeetingProcessingRunMetadata? = nil,
        summary: MeetingProcessingRunMetadata? = nil,
        manualNotesUpdatedAt: Date? = nil,
        summaryInput: MeetingSummaryInputDescriptor? = nil
    ) {
        self.transcription = transcription
        self.summary = summary
        self.manualNotesUpdatedAt = manualNotesUpdatedAt
        self.summaryInput = summaryInput
    }

    public static let empty = MeetingProcessingMetadata()

    public var isEmpty: Bool {
        transcription == nil
            && summary == nil
            && manualNotesUpdatedAt == nil
            && summaryInput == nil
    }
}

public struct SyncTextRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let kind: SyncTextRecordKind
    public var title: String?
    public var text: String
    public var speakerTranscript: String?
    public var summaryText: String?
    public var manualNotes: String?
    public var source: String?
    /// Platform origin for UI badges lives in `source`; this preserves the
    /// local capture subtype such as dictation, cua, meeting, or audio_import.
    public var localSource: String?
    public var meetingStatus: MeetingStatus?
    public var engineIdentifier: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var durationSeconds: Double
    public var wordCount: Int
    public var isDeleted: Bool
    public var cloudChangeTag: String?
    public var followUpToRecordName: String?
    public var processingMetadataJSON: String?
    /// Optional additive meeting evidence used by newer Homan clients. Older
    /// clients continue to exchange the materialized `text` field only.
    public var transcriptEvidence: MeetingTranscriptEvidenceBundle?

    public init(
        id: String,
        kind: SyncTextRecordKind,
        title: String? = nil,
        text: String,
        speakerTranscript: String? = nil,
        summaryText: String? = nil,
        manualNotes: String? = nil,
        source: String? = nil,
        localSource: String? = nil,
        meetingStatus: MeetingStatus? = nil,
        engineIdentifier: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationSeconds: Double,
        wordCount: Int,
        isDeleted: Bool = false,
        cloudChangeTag: String? = nil,
        followUpToRecordName: String? = nil,
        processingMetadataJSON: String? = nil,
        transcriptEvidence: MeetingTranscriptEvidenceBundle? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.speakerTranscript = speakerTranscript
        self.summaryText = summaryText
        self.manualNotes = manualNotes
        self.source = source
        self.localSource = localSource
        self.meetingStatus = meetingStatus
        self.engineIdentifier = engineIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.isDeleted = isDeleted
        self.cloudChangeTag = cloudChangeTag
        self.followUpToRecordName = followUpToRecordName
        self.processingMetadataJSON = processingMetadataJSON
        self.transcriptEvidence = transcriptEvidence
    }
}

public struct LiveTranscriptCheckpointEntry: Sendable, Equatable {
    public let timestampLabel: String
    public let speaker: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(
        timestampLabel: String,
        speaker: String,
        startSeconds: Double,
        endSeconds: Double,
        text: String
    ) {
        self.timestampLabel = timestampLabel
        self.speaker = speaker
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

public struct DictationRecord: Identifiable, Codable, Sendable {
    public let id: Int64
    public let timestamp: String
    public let durationSeconds: Double
    public let rawText: String
    public let appContext: String
    public let wordCount: Int
    public let source: String
    public let computerUseTrace: ComputerUseTraceRecord?

    public init(
        id: Int64,
        timestamp: String,
        durationSeconds: Double,
        rawText: String,
        appContext: String,
        wordCount: Int,
        source: String = "dictation",
        computerUseTrace: ComputerUseTraceRecord? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.rawText = rawText
        self.appContext = appContext
        self.wordCount = wordCount
        self.source = source
        self.computerUseTrace = computerUseTrace
    }
}

public struct ComputerUseTraceRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let dictationID: Int64
    public let finalStatus: String
    public let finalMessage: String
    public let events: [ComputerUseTraceEvent]
    public let createdAt: String

    public init(
        id: Int64,
        dictationID: Int64,
        finalStatus: String,
        finalMessage: String,
        events: [ComputerUseTraceEvent],
        createdAt: String
    ) {
        self.id = id
        self.dictationID = dictationID
        self.finalStatus = finalStatus
        self.finalMessage = finalMessage
        self.events = events
        self.createdAt = createdAt
    }
}

public struct ComputerUseTraceEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: String
    public let title: String
    public let body: String
    public let status: String?
    public let step: Int?
    public let timestamp: String

    public init(
        id: UUID = UUID(),
        kind: String,
        title: String,
        body: String,
        status: String? = nil,
        step: Int? = nil,
        timestamp: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.status = status
        self.step = step
        self.timestamp = timestamp
    }
}

public struct CalendarOccurrenceReference: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable {
        case eventKit
        case googleCalendar
    }

    public let provider: Provider
    public let calendarID: String?
    public let eventID: String
    public let seriesID: String?
    public let originalStartTime: Date

    public init(
        provider: Provider,
        calendarID: String?,
        eventID: String,
        seriesID: String? = nil,
        originalStartTime: Date
    ) {
        self.provider = provider
        self.calendarID = calendarID
        self.eventID = eventID
        self.seriesID = seriesID
        self.originalStartTime = originalStartTime
    }

    /// Stable identity for one provider occurrence. Recurring instances use
    /// the series plus their immutable original start; one-off events use the
    /// provider event id so rescheduling does not create a new occurrence.
    public var identityKey: String {
        let calendarComponent = Self.component(calendarID ?? "")
        if let seriesID {
            let originalStartMilliseconds = Int64((originalStartTime.timeIntervalSince1970 * 1_000).rounded())
            return "v1|recurring|\(provider.rawValue)|\(calendarComponent)|\(Self.component(seriesID))|\(originalStartMilliseconds)"
        }
        return "v1|single|\(provider.rawValue)|\(calendarComponent)|\(Self.component(eventID))"
    }

    private static func component(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}

public struct MeetingRecord: Identifiable, Codable, Sendable {
    public let id: Int64
    public let title: String
    public let startTime: String
    public let durationSeconds: Double
    public let rawTranscript: String
    public let formattedNotes: String
    public let wordCount: Int
    public let folderID: Int64?
    public let calendarEventID: String?
    public let calendarOccurrence: CalendarOccurrenceReference?
    public let micAudioPath: String?
    public let systemAudioPath: String?
    public let savedRecordingPath: String?
    public let recordingRetentionProtected: Bool
    public let status: MeetingStatus
    public let manualNotes: String
    public let selectedTemplateID: String?
    public let selectedTemplateName: String?
    public let selectedTemplateKind: MeetingTemplateKind?
    public let selectedTemplatePrompt: String?
    public let source: MeetingSource
    /// Self-referencing link: the meeting this one is a follow-up to. A meeting
    /// can have multiple follow-ups; root meetings have nil.
    public let followUpToID: Int64?
    /// Stable sync identity for the predecessor. Local row ids differ across
    /// devices, so sync uses the predecessor's cloud record name.
    public let followUpToRecordName: String?
    public let processingMetadata: MeetingProcessingMetadata

    public init(
        id: Int64,
        title: String,
        startTime: String,
        durationSeconds: Double,
        rawTranscript: String,
        formattedNotes: String,
        wordCount: Int,
        folderID: Int64?,
        calendarEventID: String? = nil,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        micAudioPath: String? = nil,
        systemAudioPath: String? = nil,
        savedRecordingPath: String? = nil,
        recordingRetentionProtected: Bool = false,
        status: MeetingStatus = .completed,
        manualNotes: String = "",
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil,
        source: MeetingSource = .meeting,
        followUpToID: Int64? = nil,
        followUpToRecordName: String? = nil,
        processingMetadata: MeetingProcessingMetadata = .empty
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.rawTranscript = rawTranscript
        self.formattedNotes = formattedNotes
        self.wordCount = wordCount
        self.folderID = folderID
        self.calendarEventID = calendarEventID
        self.calendarOccurrence = calendarOccurrence
        self.micAudioPath = micAudioPath
        self.systemAudioPath = systemAudioPath
        self.savedRecordingPath = savedRecordingPath
        self.recordingRetentionProtected = recordingRetentionProtected
        self.status = status
        self.manualNotes = manualNotes
        self.selectedTemplateID = selectedTemplateID
        self.selectedTemplateName = selectedTemplateName
        self.selectedTemplateKind = selectedTemplateKind
        self.selectedTemplatePrompt = selectedTemplatePrompt
        self.source = source
        self.followUpToID = followUpToID
        self.followUpToRecordName = followUpToRecordName
        self.processingMetadata = processingMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case startTime
        case durationSeconds
        case rawTranscript
        case formattedNotes
        case wordCount
        case folderID
        case calendarEventID
        case calendarOccurrence
        case micAudioPath
        case systemAudioPath
        case savedRecordingPath
        case recordingRetentionProtected
        case status
        case manualNotes
        case selectedTemplateID
        case selectedTemplateName
        case selectedTemplateKind
        case selectedTemplatePrompt
        case source
        case followUpToID
        case followUpToRecordName
        case processingMetadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(Int64.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            startTime: try c.decode(String.self, forKey: .startTime),
            durationSeconds: try c.decode(Double.self, forKey: .durationSeconds),
            rawTranscript: try c.decode(String.self, forKey: .rawTranscript),
            formattedNotes: try c.decode(String.self, forKey: .formattedNotes),
            wordCount: try c.decode(Int.self, forKey: .wordCount),
            folderID: try c.decodeIfPresent(Int64.self, forKey: .folderID),
            calendarEventID: try c.decodeIfPresent(String.self, forKey: .calendarEventID),
            calendarOccurrence: try c.decodeIfPresent(CalendarOccurrenceReference.self, forKey: .calendarOccurrence),
            micAudioPath: try c.decodeIfPresent(String.self, forKey: .micAudioPath),
            systemAudioPath: try c.decodeIfPresent(String.self, forKey: .systemAudioPath),
            savedRecordingPath: try c.decodeIfPresent(String.self, forKey: .savedRecordingPath),
            recordingRetentionProtected: (try? c.decode(Bool.self, forKey: .recordingRetentionProtected)) ?? false,
            status: (try? c.decode(MeetingStatus.self, forKey: .status)) ?? .completed,
            manualNotes: (try? c.decode(String.self, forKey: .manualNotes)) ?? "",
            selectedTemplateID: try c.decodeIfPresent(String.self, forKey: .selectedTemplateID),
            selectedTemplateName: try c.decodeIfPresent(String.self, forKey: .selectedTemplateName),
            selectedTemplateKind: try c.decodeIfPresent(MeetingTemplateKind.self, forKey: .selectedTemplateKind),
            selectedTemplatePrompt: try c.decodeIfPresent(String.self, forKey: .selectedTemplatePrompt),
            source: (try? c.decode(MeetingSource.self, forKey: .source)) ?? .meeting,
            followUpToID: try c.decodeIfPresent(Int64.self, forKey: .followUpToID),
            followUpToRecordName: try c.decodeIfPresent(String.self, forKey: .followUpToRecordName),
            processingMetadata: (try? c.decode(MeetingProcessingMetadata.self, forKey: .processingMetadata)) ?? .empty
        )
    }

    public var notesState: MeetingNotesState {
        let trimmed = formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missing }
        let normalized = trimmed.lowercased()
        if normalized == "## raw transcript" || normalized.hasPrefix("## raw transcript\n") {
            return .rawTranscriptFallback
        }
        return .structuredNotes
    }

    public var appliedTemplateID: String {
        let trimmed = selectedTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "auto" : trimmed
    }

    public var appliedTemplateName: String {
        let trimmed = selectedTemplateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Auto" : trimmed
    }

    public var appliedTemplateKind: MeetingTemplateKind {
        selectedTemplateKind ?? .auto
    }
}

/// A meeting as carried by a text backup file: the `MeetingRecord` content minus audio paths,
/// plus `sourceID` (the original local id) used only to remap `folderID`/`followUpToID` on restore.
public struct MeetingBackupEntry: Codable, Sendable, Equatable {
    public var sourceID: Int64
    public var title: String
    public var startTime: String
    public var durationSeconds: Double
    public var rawTranscript: String
    public var formattedNotes: String
    public var wordCount: Int
    public var folderID: Int64?
    public var calendarEventID: String?
    public var calendarOccurrence: CalendarOccurrenceReference?
    public var recordingRetentionProtected: Bool
    public var status: MeetingStatus
    public var manualNotes: String
    public var selectedTemplateID: String?
    public var selectedTemplateName: String?
    public var selectedTemplateKind: MeetingTemplateKind?
    public var selectedTemplatePrompt: String?
    public var source: MeetingSource
    public var followUpToID: Int64?
    public var followUpToRecordName: String?
    public var processingMetadata: MeetingProcessingMetadata
    /// Versioned, optional structured transcript/speaker evidence. A missing
    /// value is the valid legacy text-only backup representation.
    public var transcriptEvidence: MeetingTranscriptEvidenceBundle?

    public init(
        sourceID: Int64,
        title: String,
        startTime: String,
        durationSeconds: Double,
        rawTranscript: String,
        formattedNotes: String,
        wordCount: Int,
        folderID: Int64?,
        calendarEventID: String?,
        calendarOccurrence: CalendarOccurrenceReference?,
        recordingRetentionProtected: Bool,
        status: MeetingStatus,
        manualNotes: String,
        selectedTemplateID: String?,
        selectedTemplateName: String?,
        selectedTemplateKind: MeetingTemplateKind?,
        selectedTemplatePrompt: String?,
        source: MeetingSource,
        followUpToID: Int64?,
        followUpToRecordName: String?,
        processingMetadata: MeetingProcessingMetadata,
        transcriptEvidence: MeetingTranscriptEvidenceBundle? = nil
    ) {
        self.sourceID = sourceID
        self.title = title
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.rawTranscript = rawTranscript
        self.formattedNotes = formattedNotes
        self.wordCount = wordCount
        self.folderID = folderID
        self.calendarEventID = calendarEventID
        self.calendarOccurrence = calendarOccurrence
        self.recordingRetentionProtected = recordingRetentionProtected
        self.status = status
        self.manualNotes = manualNotes
        self.selectedTemplateID = selectedTemplateID
        self.selectedTemplateName = selectedTemplateName
        self.selectedTemplateKind = selectedTemplateKind
        self.selectedTemplatePrompt = selectedTemplatePrompt
        self.source = source
        self.followUpToID = followUpToID
        self.followUpToRecordName = followUpToRecordName
        self.processingMetadata = processingMetadata
        self.transcriptEvidence = transcriptEvidence
    }

    /// Build from a `MeetingRecord`, dropping audio-path fields (text-only backup).
    public init(
        record: MeetingRecord,
        transcriptEvidence: MeetingTranscriptEvidenceBundle? = nil
    ) {
        self.init(
            sourceID: record.id,
            title: record.title,
            startTime: record.startTime,
            durationSeconds: record.durationSeconds,
            rawTranscript: record.rawTranscript,
            formattedNotes: record.formattedNotes,
            wordCount: record.wordCount,
            folderID: record.folderID,
            calendarEventID: record.calendarEventID,
            calendarOccurrence: record.calendarOccurrence,
            recordingRetentionProtected: record.recordingRetentionProtected,
            status: record.status,
            manualNotes: record.manualNotes,
            selectedTemplateID: record.selectedTemplateID,
            selectedTemplateName: record.selectedTemplateName,
            selectedTemplateKind: record.selectedTemplateKind,
            selectedTemplatePrompt: record.selectedTemplatePrompt,
            source: record.source,
            followUpToID: record.followUpToID,
            followUpToRecordName: record.followUpToRecordName,
            processingMetadata: record.processingMetadata,
            transcriptEvidence: transcriptEvidence
        )
    }
}

public struct MeetingFolder: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public var name: String
    public let parentID: Int64?
    public let createdAt: String

    public init(id: Int64, name: String, parentID: Int64? = nil, createdAt: String) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

public struct DictationStats: Codable, Sendable {
    public let totalWords: Int
    public let totalSessions: Int
    public let averageWordsPerSession: Double
    public let averageWPM: Double
    public let currentStreakDays: Int
    public let longestStreakDays: Int

    public init(totalWords: Int, totalSessions: Int, averageWordsPerSession: Double, averageWPM: Double, currentStreakDays: Int, longestStreakDays: Int) {
        self.totalWords = totalWords
        self.totalSessions = totalSessions
        self.averageWordsPerSession = averageWordsPerSession
        self.averageWPM = averageWPM
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
    }
}

public struct MeetingStats: Codable, Sendable {
    public let totalWords: Int
    public let totalMeetings: Int
    public let averageWPM: Double

    public init(totalWords: Int, totalMeetings: Int, averageWPM: Double) {
        self.totalWords = totalWords
        self.totalMeetings = totalMeetings
        self.averageWPM = averageWPM
    }
}

public enum InsightsRange: String, CaseIterable, Codable, Sendable {
    case thirtyDays
    case ninetyDays
    case twelveMonths
    case allTime

    public func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: today)
        case .ninetyDays:
            return calendar.date(byAdding: .day, value: -89, to: today)
        case .twelveMonths:
            return calendar.date(byAdding: .year, value: -1, to: today)
        case .allTime:
            return nil
        }
    }
}

public struct InsightsTotals: Codable, Sendable, Equatable {
    public let dictationWords: Int
    public let dictationSessions: Int
    public let meetingWords: Int
    public let meetings: Int
    public let averageWPM: Double

    public var totalWords: Int { dictationWords + meetingWords }

    public init(dictationWords: Int, dictationSessions: Int, meetingWords: Int, meetings: Int, averageWPM: Double) {
        self.dictationWords = dictationWords
        self.dictationSessions = dictationSessions
        self.meetingWords = meetingWords
        self.meetings = meetings
        self.averageWPM = averageWPM
    }
}

public struct InsightsDailyActivity: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let words: Int
    public let meetings: Int

    public init(date: Date, words: Int, meetings: Int) {
        self.date = date
        self.words = words
        self.meetings = meetings
    }
}

public struct InsightsWordFrequency: Codable, Sendable, Equatable, Identifiable {
    public var id: String { word }
    public let word: String
    public let count: Int

    public init(word: String, count: Int) {
        self.word = word
        self.count = count
    }
}

public struct InsightsSnapshot: Codable, Sendable, Equatable {
    public let range: InsightsRange
    public let generatedAt: Date
    public let lifetime: InsightsTotals
    public let selected: InsightsTotals
    public let dailyActivity: [InsightsDailyActivity]
    public let currentStreakDays: Int
    public let longestStreakDays: Int
    public let activeDaysInRange: Int
    public let dictationWords: [InsightsWordFrequency]
    public let meetingWords: [InsightsWordFrequency]

    public init(
        range: InsightsRange,
        generatedAt: Date,
        lifetime: InsightsTotals,
        selected: InsightsTotals,
        dailyActivity: [InsightsDailyActivity],
        currentStreakDays: Int,
        longestStreakDays: Int,
        activeDaysInRange: Int,
        dictationWords: [InsightsWordFrequency],
        meetingWords: [InsightsWordFrequency]
    ) {
        self.range = range
        self.generatedAt = generatedAt
        self.lifetime = lifetime
        self.selected = selected
        self.dailyActivity = dailyActivity
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.activeDaysInRange = activeDaysInRange
        self.dictationWords = dictationWords
        self.meetingWords = meetingWords
    }
}
