import CryptoKit
import Foundation

/// Durable, provider-neutral source role for recognized meeting text.
///
/// Source roles are evidence. They must not be inferred from the words that
/// were recognized: microphone is the local owner, system is remote audio,
/// and legacyMixed means that the original source identity is unavailable.
public enum MeetingEvidenceSource: String, Codable, Sendable, Equatable, Hashable {
    case microphone
    case system
    case legacyMixed = "legacy_mixed"
}

public enum ASRTimestampPrecision: String, Codable, Sendable, Equatable, Hashable {
    case word
    case modelSegment = "model_segment"
    case vadItem = "vad_item"
    case none
}

public enum MeetingTranscriptRevisionStatus: String, Codable, Sendable, Equatable {
    case staged
    case complete
}

public struct MeetingASRSpan: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let source: MeetingEvidenceSource
    public let startSeconds: TimeInterval?
    public let endSeconds: TimeInterval?
    public let recordingUnitID: String?
    public let localStartSeconds: TimeInterval?
    public let localEndSeconds: TimeInterval?
    public let text: String
    public let confidence: Float?
    public let timestampPrecision: ASRTimestampPrecision

    public init(
        id: String,
        source: MeetingEvidenceSource,
        startSeconds: TimeInterval?,
        endSeconds: TimeInterval?,
        recordingUnitID: String? = nil,
        localStartSeconds: TimeInterval? = nil,
        localEndSeconds: TimeInterval? = nil,
        text: String,
        confidence: Float? = nil,
        timestampPrecision: ASRTimestampPrecision
    ) {
        self.id = id
        self.source = source
        self.startSeconds = Self.validTime(startSeconds)
        self.endSeconds = Self.validTime(endSeconds)
        self.recordingUnitID = recordingUnitID
        self.localStartSeconds = Self.validTime(localStartSeconds)
        self.localEndSeconds = Self.validTime(localEndSeconds)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = confidence?.isFinite == true ? confidence : nil
        self.timestampPrecision = timestampPrecision
    }

    public var hasUsableBounds: Bool {
        guard let startSeconds, let endSeconds else { return false }
        return endSeconds > startSeconds
    }

    private static func validTime(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

public struct MeetingTranscriptRevision: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public let meetingID: Int64
    public let runID: UUID
    public let schemaVersion: Int
    public let createdAt: Date
    public let sourceTimelineDigest: String
    /// Exact source/timeline identity used to place unit-local ASR spans on
    /// the meeting clock. Optional keeps evidence from older builds readable.
    public let sourceTimelineMap: MeetingSystemTimelineMap?
    public let backend: String
    public let model: String
    public let displayName: String
    public let purpose: String
    public let spans: [MeetingASRSpan]
    public let status: MeetingTranscriptRevisionStatus
    public let contentDigest: String

    public init(
        id: UUID = UUID(),
        meetingID: Int64,
        runID: UUID,
        schemaVersion: Int = currentSchemaVersion,
        createdAt: Date = Date(),
        sourceTimelineDigest: String,
        sourceTimelineMap: MeetingSystemTimelineMap? = nil,
        backend: String,
        model: String,
        displayName: String,
        purpose: String,
        spans: [MeetingASRSpan],
        status: MeetingTranscriptRevisionStatus = .complete
    ) {
        self.id = id
        self.meetingID = meetingID
        self.runID = runID
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.sourceTimelineDigest = sourceTimelineDigest
        self.sourceTimelineMap = sourceTimelineMap
        self.backend = backend
        self.model = model
        self.displayName = displayName
        self.purpose = purpose
        self.spans = spans.filter { !$0.text.isEmpty }
        self.status = status
        self.contentDigest = MeetingTranscriptDigest.transcriptSpans(self.spans)
    }
}

public struct MeetingDiarizationProfileSnapshot: Codable, Sendable, Equatable {
    public let profileID: String
    public let profileRevision: Int
    public let engineID: String
    public let engineVersion: String
    public let modelRevision: String
    public let modelDigest: String
    public let effectiveConfigurationDigest: String
    public let maximumSpeakers: Int?

    public init(
        profileID: String,
        profileRevision: Int,
        engineID: String,
        engineVersion: String,
        modelRevision: String,
        modelDigest: String,
        effectiveConfigurationDigest: String,
        maximumSpeakers: Int? = nil
    ) {
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.engineID = engineID
        self.engineVersion = engineVersion
        self.modelRevision = modelRevision
        self.modelDigest = modelDigest
        self.effectiveConfigurationDigest = effectiveConfigurationDigest
        self.maximumSpeakers = maximumSpeakers
    }
}

public struct MeetingDiarizationActivitySegment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let speakerKey: String
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let confidence: Float?

    public init(
        id: UUID = UUID(),
        speakerKey: String,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        confidence: Float? = nil
    ) {
        self.id = id
        self.speakerKey = speakerKey
        self.startSeconds = startSeconds.isFinite ? max(0, startSeconds) : 0
        self.endSeconds = endSeconds.isFinite ? max(0, endSeconds) : 0
        self.confidence = confidence?.isFinite == true ? confidence : nil
    }

    public var isValid: Bool {
        !speakerKey.isEmpty && endSeconds > startSeconds
    }
}

public enum MeetingDiarizationRevisionStatus: String, Codable, Sendable, Equatable {
    case staged
    case complete
}

public struct MeetingDiarizationTimings: Codable, Sendable, Equatable {
    public let modelLoadSeconds: TimeInterval
    public let inferenceSeconds: TimeInterval
    public let postProcessingSeconds: TimeInterval

    public init(
        modelLoadSeconds: TimeInterval = 0,
        inferenceSeconds: TimeInterval = 0,
        postProcessingSeconds: TimeInterval = 0
    ) {
        self.modelLoadSeconds = max(0, modelLoadSeconds)
        self.inferenceSeconds = max(0, inferenceSeconds)
        self.postProcessingSeconds = max(0, postProcessingSeconds)
    }
}

public struct MeetingDiarizationRevision: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public let meetingID: Int64
    public let runID: UUID
    public let schemaVersion: Int
    public let createdAt: Date
    public let completedAt: Date
    public let timelineDigest: String
    /// Full reversible map when the revision was produced by the unified
    /// meeting-wide renderer. Optional for evidence written by older builds.
    public let timelineMap: MeetingSystemTimelineMap?
    public let sourceFingerprints: [String]
    public let profile: MeetingDiarizationProfileSnapshot
    public let activitySegments: [MeetingDiarizationActivitySegment]
    public let detectedSpeakerCount: Int
    public let audioDurationSeconds: TimeInterval
    public let timings: MeetingDiarizationTimings
    public let warnings: [String]
    public let artifactDigest: String
    public let status: MeetingDiarizationRevisionStatus

    public init(
        id: UUID = UUID(),
        meetingID: Int64,
        runID: UUID,
        schemaVersion: Int = currentSchemaVersion,
        createdAt: Date = Date(),
        completedAt: Date = Date(),
        timelineDigest: String,
        timelineMap: MeetingSystemTimelineMap? = nil,
        sourceFingerprints: [String],
        profile: MeetingDiarizationProfileSnapshot,
        activitySegments: [MeetingDiarizationActivitySegment],
        audioDurationSeconds: TimeInterval,
        timings: MeetingDiarizationTimings = .init(),
        warnings: [String] = [],
        status: MeetingDiarizationRevisionStatus = .complete
    ) {
        let valid = activitySegments.filter(\.isValid).sorted {
            if $0.startSeconds == $1.startSeconds {
                if $0.endSeconds == $1.endSeconds {
                    return $0.speakerKey < $1.speakerKey
                }
                return $0.endSeconds < $1.endSeconds
            }
            return $0.startSeconds < $1.startSeconds
        }
        self.id = id
        self.meetingID = meetingID
        self.runID = runID
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.timelineDigest = timelineDigest
        self.timelineMap = timelineMap
        self.sourceFingerprints = sourceFingerprints
        self.profile = profile
        self.activitySegments = valid
        self.detectedSpeakerCount = Set(valid.map(\.speakerKey)).count
        self.audioDurationSeconds = max(0, audioDurationSeconds)
        self.timings = timings
        self.warnings = warnings
        self.artifactDigest = MeetingTranscriptDigest.diarizationSegments(valid)
        self.status = status
    }
}

public enum MeetingSpeakerAssignmentKind: String, Codable, Sendable, Equatable {
    case exactOverlap = "exact_overlap"
    case dominantCoarse = "dominant_coarse"
    case nearestBounded = "nearest_bounded"
    case ambiguous
    case generic
    case sourceAuthoritative = "source_authoritative"
}

public struct MeetingSpanSpeakerAssignment: Codable, Sendable, Equatable {
    public let asrSpanID: String
    public let speakerKey: String?
    public let displayLabel: String
    public let kind: MeetingSpeakerAssignmentKind
    public let overlapSeconds: TimeInterval
    public let coverage: Double

    public init(
        asrSpanID: String,
        speakerKey: String?,
        displayLabel: String,
        kind: MeetingSpeakerAssignmentKind,
        overlapSeconds: TimeInterval = 0,
        coverage: Double = 0
    ) {
        self.asrSpanID = asrSpanID
        self.speakerKey = speakerKey
        self.displayLabel = displayLabel
        self.kind = kind
        self.overlapSeconds = max(0, overlapSeconds)
        self.coverage = min(max(coverage, 0), 1)
    }
}

public struct MeetingAttributionQuality: Codable, Sendable, Equatable {
    public let timedSystemSpanCount: Int
    public let assignedSystemSpanCount: Int
    public let ambiguousSystemSpanCount: Int
    public let assignmentCoverage: Double
    public let publicationReason: String

    public init(
        timedSystemSpanCount: Int,
        assignedSystemSpanCount: Int,
        ambiguousSystemSpanCount: Int,
        assignmentCoverage: Double,
        publicationReason: String
    ) {
        self.timedSystemSpanCount = max(0, timedSystemSpanCount)
        self.assignedSystemSpanCount = max(0, assignedSystemSpanCount)
        self.ambiguousSystemSpanCount = max(0, ambiguousSystemSpanCount)
        self.assignmentCoverage = min(max(assignmentCoverage, 0), 1)
        self.publicationReason = publicationReason
    }
}

public struct MeetingAttributionRevision: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let meetingID: Int64
    public let createdAt: Date
    public let transcriptRevisionID: UUID
    public let diarizationRevisionID: UUID?
    public let algorithmID: String
    public let algorithmRevision: Int
    public let assignments: [MeetingSpanSpeakerAssignment]
    public let speakerLabelMap: [String: String]
    public let quality: MeetingAttributionQuality
    public let separatedEligible: Bool
    public let contentDigest: String

    public init(
        id: UUID = UUID(),
        meetingID: Int64,
        createdAt: Date = Date(),
        transcriptRevisionID: UUID,
        diarizationRevisionID: UUID?,
        algorithmID: String,
        algorithmRevision: Int,
        assignments: [MeetingSpanSpeakerAssignment],
        speakerLabelMap: [String: String],
        quality: MeetingAttributionQuality,
        separatedEligible: Bool
    ) {
        self.id = id
        self.meetingID = meetingID
        self.createdAt = createdAt
        self.transcriptRevisionID = transcriptRevisionID
        self.diarizationRevisionID = diarizationRevisionID
        self.algorithmID = algorithmID
        self.algorithmRevision = algorithmRevision
        self.assignments = assignments
        self.speakerLabelMap = speakerLabelMap
        self.quality = quality
        self.separatedEligible = separatedEligible
        self.contentDigest = MeetingTranscriptDigest.assignments(assignments)
    }
}

public enum MeetingTranscriptPresentationMode: String, Codable, Sendable, Equatable, CaseIterable {
    case separated
    case collapsed
    case manual
    case legacyRendered = "legacy_rendered"
}

public struct MeetingTranscriptPresentation: Codable, Sendable, Equatable {
    public var transcriptRevisionID: UUID?
    public var activeMode: MeetingTranscriptPresentationMode
    public var activeAttributionRevisionID: UUID?
    public var manualText: String?
    public var manualCreatedAt: Date?
    public var legacyText: String?
    public var activeTextDigest: String
    public var updatedAt: Date

    public init(
        transcriptRevisionID: UUID?,
        activeMode: MeetingTranscriptPresentationMode,
        activeAttributionRevisionID: UUID? = nil,
        manualText: String? = nil,
        manualCreatedAt: Date? = nil,
        legacyText: String? = nil,
        activeTextDigest: String = "",
        updatedAt: Date = Date()
    ) {
        self.transcriptRevisionID = transcriptRevisionID
        self.activeMode = activeMode
        self.activeAttributionRevisionID = activeAttributionRevisionID
        self.manualText = manualText
        self.manualCreatedAt = manualCreatedAt
        self.legacyText = legacyText
        self.activeTextDigest = activeTextDigest
        self.updatedAt = updatedAt
    }
}

public struct MeetingTranscriptEvidenceBundle: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var transcriptRevisions: [MeetingTranscriptRevision]
    public var diarizationRevisions: [MeetingDiarizationRevision]
    public var attributionRevisions: [MeetingAttributionRevision]
    public var presentation: MeetingTranscriptPresentation
    /// Non-fatal processing degradations that must remain visible after the
    /// run has completed. Optional keeps bundles written by earlier builds
    /// source-compatible without inventing a failed revision.
    public var processingWarnings: [String]?
    public var updatedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        transcriptRevisions: [MeetingTranscriptRevision] = [],
        diarizationRevisions: [MeetingDiarizationRevision] = [],
        attributionRevisions: [MeetingAttributionRevision] = [],
        presentation: MeetingTranscriptPresentation,
        processingWarnings: [String]? = nil,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.transcriptRevisions = transcriptRevisions
        self.diarizationRevisions = diarizationRevisions
        self.attributionRevisions = attributionRevisions
        self.presentation = presentation
        self.processingWarnings = processingWarnings
        self.updatedAt = updatedAt
    }

    public static func legacy(rawTranscript: String, at date: Date = Date()) -> Self {
        let digest = MeetingTranscriptDigest.text(rawTranscript)
        return Self(
            presentation: MeetingTranscriptPresentation(
                transcriptRevisionID: nil,
                activeMode: .legacyRendered,
                legacyText: rawTranscript,
                activeTextDigest: digest,
                updatedAt: date
            ),
            updatedAt: date
        )
    }

    public var activeTranscriptRevision: MeetingTranscriptRevision? {
        guard let id = presentation.transcriptRevisionID else { return nil }
        return transcriptRevisions.last { $0.id == id && $0.status == .complete }
    }

    public var activeAttributionRevision: MeetingAttributionRevision? {
        guard let id = presentation.activeAttributionRevisionID else { return nil }
        return attributionRevisions.last { $0.id == id }
    }

    public var availablePresentationModes: [MeetingTranscriptPresentationMode] {
        var modes: [MeetingTranscriptPresentationMode] = []
        if presentation.manualText != nil {
            modes.append(.manual)
        }
        if activeTranscriptRevision != nil {
            // Every generated revision has an attribution record so source
            // authority (You/Others) remains auditable, even when no acoustic
            // speaker analysis ran. Offer Separated only when that record is
            // actually backed by a diarization revision and contains at least
            // one accepted numbered remote label.
            if let attribution = activeAttributionRevision,
               attribution.diarizationRevisionID != nil,
               attribution.assignments.contains(where: {
                   $0.kind != .ambiguous && $0.displayLabel.hasPrefix("Speaker ")
               }) {
                modes.append(.separated)
            }
            modes.append(.collapsed)
        } else if presentation.legacyText != nil {
            modes.append(.legacyRendered)
        }
        return modes
    }

    public func summaryInputDescriptor(ownerName: String) -> MeetingSummaryInputDescriptor {
        MeetingSummaryInputDescriptor(
            transcriptRevisionID: presentation.transcriptRevisionID,
            attributionRevisionID: presentation.activeAttributionRevisionID,
            presentationMode: presentation.activeMode,
            transcriptDigest: presentation.activeTextDigest,
            ownerName: ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public func summaryIsStale(
        _ storedInput: MeetingSummaryInputDescriptor?,
        ownerName: String,
        speakerLegendVersion: Int = MeetingSummaryInputDescriptor.currentSpeakerLegendVersion
    ) -> Bool {
        guard let storedInput else { return false }
        let normalizedOwner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Attribution changes affect the summary payload only in Separated
        // view. Manual and Collapsed are rendered independently of Speaker N,
        // so a background/retry analysis that leaves their text untouched must
        // not create a false stale-summary warning.
        let attributionAffectsInput = storedInput.presentationMode == .separated
            || presentation.activeMode == .separated
        return storedInput.transcriptRevisionID != presentation.transcriptRevisionID
            || (attributionAffectsInput
                && storedInput.attributionRevisionID != presentation.activeAttributionRevisionID)
            || storedInput.presentationMode != presentation.activeMode
            || storedInput.transcriptDigest != presentation.activeTextDigest
            || storedInput.ownerName != normalizedOwner
            || storedInput.speakerLegendVersion != speakerLegendVersion
    }

    public func compatibleDiarizationRevision(
        timelineMap: MeetingSystemTimelineMap,
        profileID: MeetingDiarizationProfileID? = nil
    ) -> MeetingDiarizationRevision? {
        diarizationRevisions.last { revision in
            guard revision.status == .complete,
                  revision.schemaVersion == MeetingDiarizationRevision.currentSchemaVersion,
                  revision.timelineDigest == timelineMap.digest,
                  revision.sourceFingerprints == timelineMap.sourceFingerprints,
                  revision.timelineMap?.renderVersion == timelineMap.renderVersion else {
                return false
            }
            guard let profileID else { return true }
            let requested = revision.profile.profileID
            let resolved = profileID == .automatic
                ? MeetingDiarizationProfileID.offlineQuality.rawValue
                : profileID.rawValue
            return requested == profileID.rawValue || requested == resolved
        }
    }

    public mutating func storeManualPresentation(_ text: String, at date: Date = Date()) {
        presentation.manualText = text
        presentation.manualCreatedAt = date
        presentation.activeMode = .manual
        presentation.activeTextDigest = MeetingTranscriptDigest.text(text)
        presentation.updatedAt = date
        updatedAt = date
    }

    /// Assigns the definitive database identity without changing immutable run,
    /// revision, digest, or presentation identities. Fresh recording sessions
    /// can therefore prepare summary input before their row is inserted.
    public func rebased(to meetingID: Int64) -> Self {
        let transcripts = transcriptRevisions.map { revision in
            MeetingTranscriptRevision(
                id: revision.id,
                meetingID: meetingID,
                runID: revision.runID,
                schemaVersion: revision.schemaVersion,
                createdAt: revision.createdAt,
                sourceTimelineDigest: revision.sourceTimelineDigest,
                sourceTimelineMap: revision.sourceTimelineMap,
                backend: revision.backend,
                model: revision.model,
                displayName: revision.displayName,
                purpose: revision.purpose,
                spans: revision.spans,
                status: revision.status
            )
        }
        let diarizations = diarizationRevisions.map { revision in
            MeetingDiarizationRevision(
                id: revision.id,
                meetingID: meetingID,
                runID: revision.runID,
                schemaVersion: revision.schemaVersion,
                createdAt: revision.createdAt,
                completedAt: revision.completedAt,
                timelineDigest: revision.timelineDigest,
                timelineMap: revision.timelineMap,
                sourceFingerprints: revision.sourceFingerprints,
                profile: revision.profile,
                activitySegments: revision.activitySegments,
                audioDurationSeconds: revision.audioDurationSeconds,
                timings: revision.timings,
                warnings: revision.warnings,
                status: revision.status
            )
        }
        let attributions = attributionRevisions.map { revision in
            MeetingAttributionRevision(
                id: revision.id,
                meetingID: meetingID,
                createdAt: revision.createdAt,
                transcriptRevisionID: revision.transcriptRevisionID,
                diarizationRevisionID: revision.diarizationRevisionID,
                algorithmID: revision.algorithmID,
                algorithmRevision: revision.algorithmRevision,
                assignments: revision.assignments,
                speakerLabelMap: revision.speakerLabelMap,
                quality: revision.quality,
                separatedEligible: revision.separatedEligible
            )
        }
        return Self(
            schemaVersion: schemaVersion,
            transcriptRevisions: transcripts,
            diarizationRevisions: diarizations,
            attributionRevisions: attributions,
            presentation: presentation,
            processingWarnings: processingWarnings,
            updatedAt: updatedAt
        )
    }
}

public struct MeetingSummaryInputDescriptor: Codable, Sendable, Equatable {
    public static let currentSpeakerLegendVersion = 2

    public let transcriptRevisionID: UUID?
    public let attributionRevisionID: UUID?
    public let presentationMode: MeetingTranscriptPresentationMode
    public let transcriptDigest: String
    public let ownerName: String
    public let speakerLegendVersion: Int

    public init(
        transcriptRevisionID: UUID?,
        attributionRevisionID: UUID?,
        presentationMode: MeetingTranscriptPresentationMode,
        transcriptDigest: String,
        ownerName: String,
        speakerLegendVersion: Int = currentSpeakerLegendVersion
    ) {
        self.transcriptRevisionID = transcriptRevisionID
        self.attributionRevisionID = attributionRevisionID
        self.presentationMode = presentationMode
        self.transcriptDigest = transcriptDigest
        self.ownerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.speakerLegendVersion = speakerLegendVersion
    }
}

public enum MeetingTranscriptDigest {
    public static func text(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    public static func transcriptSpans(_ spans: [MeetingASRSpan]) -> String {
        encodedDigest(spans)
    }

    public static func diarizationSegments(
        _ segments: [MeetingDiarizationActivitySegment]
    ) -> String {
        encodedDigest(segments)
    }

    public static func assignments(_ assignments: [MeetingSpanSpeakerAssignment]) -> String {
        encodedDigest(assignments)
    }

    public static func encodedDigest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256((try? encoder.encode(value)) ?? Data())
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum MeetingTranscriptProjectionError: Error, LocalizedError, Equatable {
    case transcriptRevisionUnavailable
    case attributionRevisionUnavailable
    case manualPresentationUnavailable

    public var errorDescription: String? {
        switch self {
        case .transcriptRevisionUnavailable:
            return "The structured transcript is unavailable."
        case .attributionRevisionUnavailable:
            return "The separated speaker analysis is unavailable."
        case .manualPresentationUnavailable:
            return "No manually edited transcript is available."
        }
    }
}

public enum MeetingTranscriptProjection {
    private struct RenderedTurn {
        let start: TimeInterval?
        let end: TimeInterval?
        let label: String
        var text: String
        let recordingUnitID: String?
    }

    public static func render(
        bundle: MeetingTranscriptEvidenceBundle,
        mode: MeetingTranscriptPresentationMode,
        meetingStart: Date
    ) throws -> String {
        switch mode {
        case .manual:
            guard let text = bundle.presentation.manualText else {
                throw MeetingTranscriptProjectionError.manualPresentationUnavailable
            }
            return text
        case .legacyRendered:
            return bundle.presentation.legacyText ?? ""
        case .collapsed, .separated:
            guard let transcript = bundle.activeTranscriptRevision else {
                throw MeetingTranscriptProjectionError.transcriptRevisionUnavailable
            }
            let attribution: MeetingAttributionRevision?
            if mode == .separated {
                guard let active = bundle.activeAttributionRevision else {
                    throw MeetingTranscriptProjectionError.attributionRevisionUnavailable
                }
                attribution = active
            } else {
                attribution = nil
            }
            return render(
                transcript: transcript,
                attribution: attribution,
                separated: mode == .separated,
                meetingStart: meetingStart
            )
        }
    }

    public static func render(
        transcript: MeetingTranscriptRevision,
        attribution: MeetingAttributionRevision?,
        separated: Bool,
        meetingStart: Date
    ) -> String {
        let assignmentBySpan = Dictionary(
            uniqueKeysWithValues: (attribution?.assignments ?? []).map { ($0.asrSpanID, $0) }
        )
        let sorted = transcript.spans.sorted { lhs, rhs in
            let lhsStart = lhs.startSeconds ?? .greatestFiniteMagnitude
            let rhsStart = rhs.startSeconds ?? .greatestFiniteMagnitude
            if lhsStart == rhsStart { return lhs.id < rhs.id }
            return lhsStart < rhsStart
        }
        var turns: [RenderedTurn] = []
        for span in sorted where !span.text.isEmpty {
            let label: String
            switch span.source {
            case .microphone:
                label = "You"
            case .system:
                if separated,
                   let assignment = assignmentBySpan[span.id],
                   assignment.kind != .ambiguous,
                   assignment.displayLabel.hasPrefix("Speaker ") {
                    label = assignment.displayLabel
                } else {
                    label = "Others"
                }
            case .legacyMixed:
                if separated,
                   let assignment = assignmentBySpan[span.id],
                   assignment.kind != .ambiguous,
                   assignment.displayLabel.hasPrefix("Speaker ") {
                    label = assignment.displayLabel
                } else {
                    label = "Speaker"
                }
            }

            if var previous = turns.last,
               previous.label == label,
               previous.recordingUnitID == span.recordingUnitID,
               canMerge(previousEnd: previous.end, nextStart: span.startSeconds) {
                previous.text += " " + span.text
                turns[turns.count - 1] = previous
            } else {
                turns.append(RenderedTurn(
                    start: span.startSeconds,
                    end: span.endSeconds,
                    label: label,
                    text: span.text,
                    recordingUnitID: span.recordingUnitID
                ))
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return turns.map { turn in
            let timestamp: String
            if let start = turn.start, start.isFinite {
                timestamp = formatter.string(from: meetingStart.addingTimeInterval(max(0, start)))
            } else {
                timestamp = formatter.string(from: meetingStart)
            }
            return "[\(timestamp)] \(turn.label): \(turn.text)"
        }.joined(separator: "\n")
    }

    public static func activated(
        _ bundle: MeetingTranscriptEvidenceBundle,
        mode: MeetingTranscriptPresentationMode,
        meetingStart: Date,
        at date: Date = Date()
    ) throws -> (bundle: MeetingTranscriptEvidenceBundle, text: String) {
        var copy = bundle
        let text = try render(bundle: copy, mode: mode, meetingStart: meetingStart)
        copy.presentation.activeMode = mode
        copy.presentation.activeTextDigest = MeetingTranscriptDigest.text(text)
        copy.presentation.updatedAt = date
        copy.updatedAt = date
        return (copy, text)
    }

    private static func canMerge(
        previousEnd: TimeInterval?,
        nextStart: TimeInterval?
    ) -> Bool {
        guard let previousEnd, let nextStart else { return true }
        return nextStart - previousEnd <= 2
    }
}
