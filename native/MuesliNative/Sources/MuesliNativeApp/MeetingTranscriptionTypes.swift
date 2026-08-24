import FluidAudio
import Foundation
import MuesliCore

enum MeetingAudioSourceRole: String, Codable, Sendable, Hashable {
    case microphone
    case system
    case legacyMixed = "legacy_mixed"
}

enum MeetingTranscriptRole: String, Codable, Sendable, Hashable {
    case you
    case others
    case legacyUnknown = "legacy_unknown"
}

enum MeetingProcessingPurpose: String, Codable, Sendable, Hashable {
    case liveStreaming = "live_streaming"
    case liveChunked = "live_chunked"
    case final
    case recovery
    case retranscribe
}

enum MeetingTranscriptionAudioSource: String, Codable, Sendable, Hashable {
    case rawSourceBundle = "raw_source_bundle"
    case derivedSourceBundle = "derived_source_bundle"
    case separatedPlayback = "separated_playback"
    case legacyMixed = "legacy_mixed"
}

enum SystemDiarizationPolicy: String, Codable, Sendable, Hashable {
    case disabled
    case reuseCompatible = "reuse_compatible"
    case optionalPost = "optional_post"
}

enum MeetingProcessingDegradation: Hashable, Sendable {
    case sourceEmpty(MeetingAudioSourceRole)
    case sourceMissing(MeetingAudioSourceRole)
    case sourceCorrupt(MeetingAudioSourceRole)
    case sourceRecognitionFailed(MeetingAudioSourceRole)
    case optionalDiarizationFailed
    case legacySourceIdentityUnavailable
    case sourceBundleVersionUnsupported(Int)
}

struct MeetingLanguageSnapshot: Codable, Equatable, Sendable {
    let cohereLanguage: String?
    let indicASRLanguage: String?
    let nemotron35Language: String?

    init(
        cohereLanguage: String? = nil,
        indicASRLanguage: String? = nil,
        nemotron35Language: String? = nil
    ) {
        self.cohereLanguage = cohereLanguage
        self.indicASRLanguage = indicASRLanguage
        self.nemotron35Language = nemotron35Language
    }
}

struct SourceRecognizedSegment: Equatable, Sendable {
    let id: String
    let source: MeetingAudioSourceRole
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String
    let confidence: Float?
    let timestampPrecision: ASRTimestampPrecision
}

struct AttributedTurn: Equatable, Sendable {
    let sourceRole: MeetingTranscriptRole
    let remoteSpeaker: String?
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String
    let isProvisional: Bool
    let recordingSessionID: UUID?
}

struct MeetingSourceBundleInput: Sendable {
    let recording: MeetingRecordingRecord?
    let playbackURL: URL?
    let bundle: MeetingRecordingBundle
}

struct MeetingLegacyRecordingInput: Sendable {
    let recording: MeetingRecordingRecord
    let playbackURL: URL
    let degradations: [MeetingProcessingDegradation]

    init(
        recording: MeetingRecordingRecord,
        playbackURL: URL,
        degradations: [MeetingProcessingDegradation] = []
    ) {
        self.recording = recording
        self.playbackURL = playbackURL
        self.degradations = degradations
    }
}

struct MeetingSeparatedRecordingInput: Sendable {
    let recording: MeetingRecordingRecord
    let recordingURL: URL
    let sourceLayout: MeetingRecordingSourceLayout
}

enum MeetingRecordingUnitInput: Sendable {
    case sourceBundle(MeetingSourceBundleInput)
    case separatedChannels(MeetingSeparatedRecordingInput)
    case legacyMixed(MeetingLegacyRecordingInput)

    var transcriptionAudioSource: MeetingTranscriptionAudioSource {
        switch self {
        case .sourceBundle(let input):
            return input.bundle.rawAudio == nil
                ? .derivedSourceBundle
                : .rawSourceBundle
        case .separatedChannels:
            return .separatedPlayback
        case .legacyMixed:
            return .legacyMixed
        }
    }

    var reappliesRequestedAEC: Bool {
        if case .sourceBundle(let input) = self {
            return input.bundle.rawAudio != nil
        }
        return false
    }

    func hasUsableAudio(onDisk fileManager: FileManager = .default) -> Bool {
        switch self {
        case .sourceBundle(let input):
            if let rawAudio = input.bundle.rawAudio {
                return rawAudio.epochs.contains {
                    fileManager.fileExists(
                        atPath: rawAudio.payloadURL(for: $0).path
                    )
                }
            }
            return [input.bundle.microphoneURL, input.bundle.systemURL]
                .compactMap { $0 }
                .contains { fileManager.fileExists(atPath: $0.path) }
        case .separatedChannels(let input):
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(
                atPath: input.recordingURL.path,
                isDirectory: &isDirectory
            ) && !isDirectory.boolValue
        case .legacyMixed(let input):
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(
                atPath: input.playbackURL.path,
                isDirectory: &isDirectory
            ) && !isDirectory.boolValue
        }
    }

    var createdAt: Date {
        switch self {
        case .sourceBundle(let input):
            return input.recording?.createdAt ?? input.bundle.manifest.startedAt
        case .separatedChannels(let input):
            return input.recording.createdAt
        case .legacyMixed(let input):
            return input.recording.createdAt
        }
    }

    var stableOrder: String {
        switch self {
        case .sourceBundle(let input):
            return input.bundle.manifest.sessionID.uuidString
        case .separatedChannels(let input):
            return String(format: "%020lld", input.recording.id)
        case .legacyMixed(let input):
            return String(format: "%020lld", input.recording.id)
        }
    }
}

enum MeetingTranscriptionProvenance {
    static func audioSource(for units: [MeetingRecordingUnitInput]) -> String? {
        let sources = Set(units.map(\.transcriptionAudioSource.rawValue)).sorted()
        return sources.isEmpty ? nil : sources.joined(separator: "+")
    }

    static func requestedAECModel(
        for units: [MeetingRecordingUnitInput],
        requested model: MeetingAecModel
    ) -> String? {
        units.contains(where: \.reappliesRequestedAEC) ? model.rawValue : nil
    }
}

struct MeetingTranscriptionRequest: Sendable {
    let units: [MeetingRecordingUnitInput]
    let backend: BackendOption
    let languages: MeetingLanguageSnapshot
    let purpose: MeetingProcessingPurpose
    let systemDiarization: SystemDiarizationPolicy
    let diarizationProfileID: MeetingDiarizationProfileID
    let aecModel: MeetingAecModel
    let reusableDiarization: MeetingDiarizationRevision?
    /// Present only for recovery/finalization from Homan's durable processing
    /// capture. Homan Whisper may keep its VAD/AAC request checkpoint beside
    /// that capture so a remote failure resumes without preparing audio again.
    let persistentRemoteBatchAudio: MeetingStagedAudio?
    let progress: @Sendable (MeetingTranscriptionPipelineStage) -> Void

    init(
        units: [MeetingRecordingUnitInput],
        backend: BackendOption,
        languages: MeetingLanguageSnapshot,
        purpose: MeetingProcessingPurpose,
        systemDiarization: SystemDiarizationPolicy,
        diarizationProfileID: MeetingDiarizationProfileID = .automatic,
        aecModel: MeetingAecModel = .defaultModel,
        reusableDiarization: MeetingDiarizationRevision? = nil,
        persistentRemoteBatchAudio: MeetingStagedAudio? = nil,
        progress: @escaping @Sendable (MeetingTranscriptionPipelineStage) -> Void = { _ in }
    ) {
        self.units = units
        self.backend = backend
        self.languages = languages
        self.purpose = purpose
        self.systemDiarization = systemDiarization
        self.diarizationProfileID = diarizationProfileID
        self.aecModel = aecModel
        self.reusableDiarization = reusableDiarization
        self.persistentRemoteBatchAudio = persistentRemoteBatchAudio
        self.progress = progress
    }
}

enum MeetingTranscriptionPipelineStage: Sendable, Equatable {
    case processingAudio
    case transcribing
    case preparingDiarizer
    case diarizing
    case applyingSpeakerLabels
}

struct MeetingUnitTranscriptionResult: Sendable {
    let unitID: String
    let sessionID: UUID?
    let startedAt: Date
    let attributedTurns: [AttributedTurn]
    let formattedTranscript: String
    let degradations: [MeetingProcessingDegradation]
    let recognizedSegments: [SourceRecognizedSegment]
    let microphoneSegments: [SpeechSegment]
    let systemSegments: [SpeechSegment]
    let diarizationSegments: [TimedSpeakerSegment]?
    let aecDiagnostics: MeetingAecDiagnosticsSnapshot?

    init(
        unitID: String,
        sessionID: UUID?,
        startedAt: Date,
        attributedTurns: [AttributedTurn],
        formattedTranscript: String,
        degradations: [MeetingProcessingDegradation],
        recognizedSegments: [SourceRecognizedSegment],
        microphoneSegments: [SpeechSegment],
        systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?,
        aecDiagnostics: MeetingAecDiagnosticsSnapshot? = nil
    ) {
        self.unitID = unitID
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.attributedTurns = attributedTurns
        self.formattedTranscript = formattedTranscript
        self.degradations = degradations
        self.recognizedSegments = recognizedSegments
        self.microphoneSegments = microphoneSegments
        self.systemSegments = systemSegments
        self.diarizationSegments = diarizationSegments
        self.aecDiagnostics = aecDiagnostics
    }
}

struct MeetingTranscriptionResult: Sendable {
    let units: [MeetingUnitTranscriptionResult]
    let attributedTurns: [AttributedTurn]
    let formattedTranscript: String
    let degradations: [MeetingProcessingDegradation]
    let systemTimelineMap: MeetingSystemTimelineMap?
    let diarizationProfile: MeetingDiarizationProfileSnapshot?
    let diarizationTimings: MeetingDiarizationTimings?
    let reusedDiarizationRevisionID: UUID?
}

enum MeetingTranscriptionPipelineError: Error, LocalizedError, Equatable {
    case noRecordingUnits
    case noUsableAudio
    case emptyTranscript
    case compatibleDiarizationUnavailable
    case sourceBundleVersionUnsupported(Int)

    var errorDescription: String? {
        switch self {
        case .noRecordingUnits:
            return "No retained meeting recording is available."
        case .noUsableAudio:
            return "The retained meeting recording does not contain usable audio."
        case .emptyTranscript:
            return "The selected model did not produce any meeting transcript."
        case .compatibleDiarizationUnavailable:
            return "The saved speaker analysis no longer matches this recording or the current speaker profile."
        case .sourceBundleVersionUnsupported(let version):
            return "This meeting uses a newer source-audio format (version \(version)). Playback is still available."
        }
    }
}
