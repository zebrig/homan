import FluidAudio
import Foundation
import MuesliCore

struct MeetingTranscriptEvidencePublication: Sendable {
    let evidence: MeetingTranscriptEvidenceBundle
    let activeTranscript: String
    let transcriptRevision: MeetingTranscriptRevision
    let diarizationRevision: MeetingDiarizationRevision?
    let attributionRevision: MeetingAttributionRevision
}

enum MeetingTranscriptEvidenceFactory {
    static let speakerAnalysisUnavailableWarning =
        "Remote speaker analysis was unavailable. Showing remote audio as Others."

    static let legacyProfile = MeetingDiarizationProfileSnapshot(
        profileID: "legacy",
        profileRevision: 1,
        engineID: "fluidaudio-online-pyannote",
        engineVersion: "0.15.1",
        modelRevision: "legacy",
        modelDigest: "managed-by-fluidaudio",
        effectiveConfigurationDigest: MeetingTranscriptDigest.text(
            "legacy|runtime-policy|system-only"
        )
    )

    static func makePublication(
        meetingID: Int64,
        meetingStart: Date,
        result: MeetingTranscriptionResult,
        backend: BackendOption,
        purpose: MeetingProcessingPurpose,
        runID: UUID,
        profile: MeetingDiarizationProfileSnapshot? = nil,
        reusedDiarization: MeetingDiarizationRevision? = nil,
        priorEvidence: MeetingTranscriptEvidenceBundle? = nil,
        now: Date = Date()
    ) throws -> MeetingTranscriptEvidencePublication {
        let orderedUnits = result.units.sorted {
            if $0.startedAt == $1.startedAt {
                return ($0.sessionID?.uuidString ?? "") < ($1.sessionID?.uuidString ?? "")
            }
            return $0.startedAt < $1.startedAt
        }
        var spans: [MeetingASRSpan] = []
        var activity: [MeetingDiarizationActivitySegment] = []
        var sourceFingerprints: [String] = []
        var maximumEnd: TimeInterval = 0
        let timelineEntryByUnit = Dictionary(
            uniqueKeysWithValues: (result.systemTimelineMap?.entries ?? []).map {
                ($0.unitID, $0)
            }
        )

        for (unitIndex, unit) in orderedUnits.enumerated() {
            let unitID = unit.unitID.isEmpty
                ? (unit.sessionID?.uuidString.lowercased()
                    ?? String(format: "unit-%04d", unitIndex))
                : unit.unitID
            let offset = timelineEntryByUnit[unitID]?.globalStartSeconds
                ?? max(0, unit.startedAt.timeIntervalSince(meetingStart))
            sourceFingerprints.append(MeetingTranscriptDigest.text(
                "\(unitID)|\(unit.startedAt.timeIntervalSince1970)|\(unit.recognizedSegments.count)"
            ))
            for (spanIndex, segment) in unit.recognizedSegments.enumerated() where !segment.text.isEmpty {
                let localStart = max(0, segment.startSeconds)
                let localEnd = max(localStart, segment.endSeconds)
                let globalStart = offset + localStart
                let globalEnd = offset + localEnd
                maximumEnd = max(maximumEnd, globalEnd)
                spans.append(MeetingASRSpan(
                    id: "\(unitID)/\(segment.id.isEmpty ? String(spanIndex) : segment.id)",
                    source: evidenceSource(segment.source),
                    startSeconds: globalStart,
                    endSeconds: globalEnd,
                    recordingUnitID: unitID,
                    localStartSeconds: localStart,
                    localEndSeconds: localEnd,
                    text: segment.text,
                    confidence: segment.confidence,
                    timestampPrecision: segment.timestampPrecision
                ))
            }
            for segment in unit.diarizationSegments ?? [] {
                let localStart = max(0, TimeInterval(segment.startTimeSeconds))
                let localEnd = max(localStart, TimeInterval(segment.endTimeSeconds))
                let globalStart = offset + localStart
                let globalEnd = offset + localEnd
                maximumEnd = max(maximumEnd, globalEnd)
                activity.append(MeetingDiarizationActivitySegment(
                    speakerKey: segment.speakerId,
                    startSeconds: globalStart,
                    endSeconds: globalEnd,
                    confidence: segment.qualityScore
                ))
            }
        }

        guard !spans.isEmpty else {
            throw MeetingTranscriptionPipelineError.emptyTranscript
        }
        if let map = result.systemTimelineMap {
            sourceFingerprints = map.sourceFingerprints
            maximumEnd = max(maximumEnd, map.totalDurationSeconds)
        }
        let timelineDigest = result.systemTimelineMap?.digest
            ?? MeetingTranscriptDigest.encodedDigest(sourceFingerprints)
        let transcript = MeetingTranscriptRevision(
            meetingID: meetingID,
            runID: runID,
            createdAt: now,
            sourceTimelineDigest: timelineDigest,
            sourceTimelineMap: result.systemTimelineMap,
            backend: backend.backend,
            model: backend.model,
            displayName: backend.label,
            purpose: purpose.rawValue,
            spans: spans
        )
        let diarization: MeetingDiarizationRevision?
        let createdNewDiarization: Bool
        let validatedReuse: MeetingDiarizationRevision?
        if let reusedDiarization,
           reusedDiarization.status == .complete,
           reusedDiarization.timelineDigest == timelineDigest,
           reusedDiarization.sourceFingerprints == sourceFingerprints,
           reusedDiarization.profile == result.diarizationProfile {
            validatedReuse = reusedDiarization
        } else {
            validatedReuse = nil
        }
        if let reused = validatedReuse {
            diarization = reused
            createdNewDiarization = false
        } else if activity.isEmpty {
            diarization = nil
            createdNewDiarization = false
        } else {
            diarization = MeetingDiarizationRevision(
                meetingID: meetingID,
                runID: runID,
                createdAt: now,
                completedAt: now,
                timelineDigest: timelineDigest,
                timelineMap: result.systemTimelineMap,
                sourceFingerprints: sourceFingerprints,
                profile: result.diarizationProfile ?? profile ?? legacyProfile,
                activitySegments: activity,
                audioDurationSeconds: maximumEnd,
                timings: result.diarizationTimings ?? .init()
            )
            createdNewDiarization = true
        }
        let attribution = MeetingSpeakerAttribution.makeRevision(
            meetingID: meetingID,
            transcript: transcript,
            diarization: diarization,
            now: now
        )

        var transcriptRevisions = priorEvidence?.transcriptRevisions ?? []
        transcriptRevisions.append(transcript)
        var diarizationRevisions = priorEvidence?.diarizationRevisions ?? []
        if let diarization, createdNewDiarization {
            diarizationRevisions.append(diarization)
        }
        var attributionRevisions = priorEvidence?.attributionRevisions ?? []
        attributionRevisions.append(attribution)
        let generatedMode: MeetingTranscriptPresentationMode = attribution.separatedEligible
            ? .separated
            : .collapsed
        var presentation = MeetingTranscriptPresentation(
            transcriptRevisionID: transcript.id,
            activeMode: generatedMode,
            activeAttributionRevisionID: attribution.id,
            manualText: priorEvidence?.presentation.manualText,
            manualCreatedAt: priorEvidence?.presentation.manualCreatedAt,
            legacyText: priorEvidence?.presentation.legacyText,
            updatedAt: now
        )
        var evidence = MeetingTranscriptEvidenceBundle(
            transcriptRevisions: transcriptRevisions,
            diarizationRevisions: diarizationRevisions,
            attributionRevisions: attributionRevisions,
            presentation: presentation,
            processingWarnings: result.degradations.contains(.optionalDiarizationFailed)
                ? [speakerAnalysisUnavailableWarning]
                : nil,
            updatedAt: now
        )
        let activeTranscript = try MeetingTranscriptProjection.render(
            bundle: evidence,
            mode: generatedMode,
            meetingStart: meetingStart
        )
        presentation.activeTextDigest = MeetingTranscriptDigest.text(activeTranscript)
        evidence.presentation = presentation

        return MeetingTranscriptEvidencePublication(
            evidence: evidence,
            activeTranscript: activeTranscript,
            transcriptRevision: transcript,
            diarizationRevision: diarization,
            attributionRevision: attribution
        )
    }

    /// Adds a newly recognized recording segment to an existing meeting while
    /// retaining both the structured history and a user-edited presentation.
    /// The segment may have been analyzed independently during crash recovery,
    /// so generated output is conservatively collapsed until a meeting-wide
    /// speaker pass is run over all retained units.
    static func makeAppendedPublication(
        meetingID: Int64,
        meetingStart: Date,
        result: MeetingTranscriptionResult,
        backend: BackendOption,
        purpose: MeetingProcessingPurpose,
        runID: UUID,
        priorEvidence: MeetingTranscriptEvidenceBundle,
        now: Date = Date()
    ) throws -> MeetingTranscriptEvidencePublication {
        let currentStart = result.units.map(\.startedAt).min() ?? meetingStart
        let currentOffset = max(0, currentStart.timeIntervalSince(meetingStart))
        let current = try makePublication(
            meetingID: meetingID,
            meetingStart: currentStart,
            result: result,
            backend: backend,
            purpose: purpose,
            runID: runID,
            priorEvidence: nil,
            now: now
        )
        guard let priorTranscript = priorEvidence.activeTranscriptRevision else {
            return try makePublication(
                meetingID: meetingID,
                meetingStart: meetingStart,
                result: result,
                backend: backend,
                purpose: purpose,
                runID: runID,
                priorEvidence: priorEvidence,
                now: now
            )
        }

        let combinedTimeline = combinedTimelineMap(
            prior: priorTranscript.sourceTimelineMap,
            appended: current.transcriptRevision.sourceTimelineMap,
            requestedAppendOffset: currentOffset
        )
        let appendedTimelineShift = combinedTimeline?.appendedShift ?? currentOffset
        var usedIDs = Set(priorTranscript.spans.map(\.id))
        let appendedSpans = current.transcriptRevision.spans.map { span -> MeetingASRSpan in
            var id = span.id
            if usedIDs.contains(id) {
                id = "\(runID.uuidString.lowercased())/\(id)"
            }
            usedIDs.insert(id)
            return MeetingASRSpan(
                id: id,
                source: span.source,
                startSeconds: span.startSeconds.map { $0 + appendedTimelineShift },
                endSeconds: span.endSeconds.map { $0 + appendedTimelineShift },
                recordingUnitID: span.recordingUnitID,
                localStartSeconds: span.localStartSeconds,
                localEndSeconds: span.localEndSeconds,
                text: span.text,
                confidence: span.confidence,
                timestampPrecision: span.timestampPrecision
            )
        }
        let combinedTranscript = MeetingTranscriptRevision(
            meetingID: meetingID,
            runID: runID,
            createdAt: now,
            sourceTimelineDigest: combinedTimeline?.map.digest
                ?? MeetingTranscriptDigest.text(
                    "\(priorTranscript.sourceTimelineDigest)|\(current.transcriptRevision.sourceTimelineDigest)"
                ),
            sourceTimelineMap: combinedTimeline?.map,
            backend: backend.backend,
            model: backend.model,
            displayName: backend.label,
            purpose: purpose.rawValue,
            spans: priorTranscript.spans + appendedSpans
        )
        let attribution = MeetingSpeakerAttribution.makeRevision(
            meetingID: meetingID,
            transcript: combinedTranscript,
            diarization: nil,
            now: now
        )
        var presentation = MeetingTranscriptPresentation(
            transcriptRevisionID: combinedTranscript.id,
            activeMode: .collapsed,
            activeAttributionRevisionID: attribution.id,
            manualText: priorEvidence.presentation.manualText,
            manualCreatedAt: priorEvidence.presentation.manualCreatedAt,
            legacyText: priorEvidence.presentation.legacyText,
            updatedAt: now
        )
        var evidence = MeetingTranscriptEvidenceBundle(
            schemaVersion: priorEvidence.schemaVersion,
            transcriptRevisions: priorEvidence.transcriptRevisions + [combinedTranscript],
            diarizationRevisions: priorEvidence.diarizationRevisions
                + current.evidence.diarizationRevisions,
            attributionRevisions: priorEvidence.attributionRevisions + [attribution],
            presentation: presentation,
            processingWarnings: mergedWarnings(
                priorEvidence.processingWarnings,
                current.evidence.processingWarnings
            ),
            updatedAt: now
        )
        let generatedText = try MeetingTranscriptProjection.render(
            bundle: evidence,
            mode: .collapsed,
            meetingStart: meetingStart
        )
        let activeText: String
        if priorEvidence.presentation.activeMode == .manual,
           let priorManual = priorEvidence.presentation.manualText {
            let currentCollapsed = try MeetingTranscriptProjection.render(
                bundle: current.evidence,
                mode: .collapsed,
                meetingStart: currentStart
            )
            activeText = [priorManual, currentCollapsed]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            presentation.manualText = activeText
            presentation.manualCreatedAt = now
            presentation.activeMode = .manual
        } else {
            activeText = generatedText
        }
        presentation.activeTextDigest = MeetingTranscriptDigest.text(activeText)
        evidence.presentation = presentation

        return MeetingTranscriptEvidencePublication(
            evidence: evidence,
            activeTranscript: activeText,
            transcriptRevision: combinedTranscript,
            diarizationRevision: current.diarizationRevision,
            attributionRevision: attribution
        )
    }

    /// Publishes a new acoustic/attribution revision over the currently active
    /// structured ASR evidence. No recognized text is created or changed here.
    /// Manual text remains active and untouched when the user selected it.
    static func makeRediarizationPublication(
        meetingID: Int64,
        meetingStart: Date,
        priorEvidence: MeetingTranscriptEvidenceBundle,
        timelineMap: MeetingSystemTimelineMap,
        analysis: MeetingDiarizationTimelineResult,
        runID: UUID,
        now: Date = Date()
    ) throws -> MeetingTranscriptEvidencePublication {
        guard let transcript = priorEvidence.activeTranscriptRevision else {
            throw MeetingTranscriptProjectionError.transcriptRevisionUnavailable
        }
        if let capturedMap = transcript.sourceTimelineMap,
           capturedMap.digest != timelineMap.digest {
            throw MeetingSpeakerAnalysisError.retainedSystemAudioChanged
        }
        let activity = analysis.activitySegments.filter(\.isValid)
        guard !activity.isEmpty else {
            throw MeetingSpeakerAnalysisError.noSpeakerActivity
        }
        let diarization = MeetingDiarizationRevision(
            meetingID: meetingID,
            runID: runID,
            createdAt: now,
            completedAt: now,
            timelineDigest: timelineMap.digest,
            timelineMap: timelineMap,
            sourceFingerprints: timelineMap.sourceFingerprints,
            profile: analysis.profile,
            activitySegments: activity,
            audioDurationSeconds: timelineMap.totalDurationSeconds,
            timings: analysis.timings,
            warnings: analysis.warnings
        )
        let attribution = MeetingSpeakerAttribution.makeRevision(
            meetingID: meetingID,
            transcript: transcript,
            diarization: diarization,
            now: now
        )

        var presentation = priorEvidence.presentation
        presentation.transcriptRevisionID = transcript.id
        presentation.activeAttributionRevisionID = attribution.id
        switch presentation.activeMode {
        case .manual:
            break
        case .separated, .collapsed, .legacyRendered:
            presentation.activeMode = attribution.separatedEligible
                ? .separated
                : .collapsed
        }
        presentation.updatedAt = now

        var evidence = MeetingTranscriptEvidenceBundle(
            schemaVersion: priorEvidence.schemaVersion,
            transcriptRevisions: priorEvidence.transcriptRevisions,
            diarizationRevisions: priorEvidence.diarizationRevisions + [diarization],
            attributionRevisions: priorEvidence.attributionRevisions + [attribution],
            presentation: presentation,
            processingWarnings: analysis.warnings.isEmpty ? nil : analysis.warnings,
            updatedAt: now
        )
        let activeTranscript = try MeetingTranscriptProjection.render(
            bundle: evidence,
            mode: presentation.activeMode,
            meetingStart: meetingStart
        )
        evidence.presentation.activeTextDigest = MeetingTranscriptDigest.text(activeTranscript)

        return MeetingTranscriptEvidencePublication(
            evidence: evidence,
            activeTranscript: activeTranscript,
            transcriptRevision: transcript,
            diarizationRevision: diarization,
            attributionRevision: attribution
        )
    }

    private static func evidenceSource(
        _ source: MeetingAudioSourceRole
    ) -> MeetingEvidenceSource {
        switch source {
        case .microphone: return .microphone
        case .system: return .system
        case .legacyMixed: return .legacyMixed
        }
    }

    /// Appends a resumed recording to the exact prior logical clock. The
    /// renderer compacts overlap by placing a later unit no earlier than the
    /// previous timeline end; mirroring that rule keeps stored ASR spans and a
    /// future meeting-wide Re-diarize on the same clock.
    private static func combinedTimelineMap(
        prior: MeetingSystemTimelineMap?,
        appended: MeetingSystemTimelineMap?,
        requestedAppendOffset: TimeInterval
    ) -> (map: MeetingSystemTimelineMap, appendedShift: TimeInterval)? {
        guard let prior, let appended,
              prior.schemaVersion == appended.schemaVersion,
              prior.renderVersion == appended.renderVersion,
              let first = appended.entries.first else {
            return nil
        }
        let priorEnd = prior.totalDurationSeconds
        let requestedFirstStart = max(0, requestedAppendOffset + first.globalStartSeconds)
        let actualFirstStart = max(priorEnd, requestedFirstStart)
        let shift = actualFirstStart - first.globalStartSeconds
        let shifted = appended.entries.enumerated().map { index, entry in
            let boundary: MeetingSystemTimelineMapEntry.BoundaryKind
            if index == 0 {
                if prior.entries.isEmpty {
                    boundary = .first
                } else if requestedFirstStart > priorEnd {
                    boundary = .explicitGap
                } else if requestedFirstStart < priorEnd {
                    boundary = .overlapCompacted
                } else {
                    boundary = .continuous
                }
            } else {
                boundary = entry.boundaryKind
            }
            return MeetingSystemTimelineMapEntry(
                unitID: entry.unitID,
                sourceFingerprint: entry.sourceFingerprint,
                unitStartSeconds: entry.unitStartSeconds,
                unitEndSeconds: entry.unitEndSeconds,
                globalStartSeconds: entry.globalStartSeconds + shift,
                globalEndSeconds: entry.globalEndSeconds + shift,
                boundaryKind: boundary
            )
        }
        let entries = prior.entries + shifted
        let total = max(priorEnd, shifted.map(\.globalEndSeconds).max() ?? priorEnd)
        return (
            MeetingSystemTimelineMap(
                schemaVersion: prior.schemaVersion,
                renderVersion: prior.renderVersion,
                totalDurationSeconds: total,
                entries: entries
            ),
            shift
        )
    }

    private static func mergedWarnings(
        _ lhs: [String]?,
        _ rhs: [String]?
    ) -> [String]? {
        var seen: Set<String> = []
        let values = (lhs ?? []) + (rhs ?? [])
        let merged = values.filter { seen.insert($0).inserted }
        return merged.isEmpty ? nil : merged
    }
}

enum MeetingSpeakerAnalysisError: Error, LocalizedError, Equatable {
    case structuredTranscriptUnavailable
    case retainedSystemAudioUnavailable
    case retainedSystemAudioChanged
    case noSpeakerActivity
    case controllerUnavailable

    var errorDescription: String? {
        switch self {
        case .structuredTranscriptUnavailable:
            return "Re-transcribe this meeting once before analyzing speakers."
        case .retainedSystemAudioUnavailable:
            return "Original system audio is no longer available."
        case .retainedSystemAudioChanged:
            return "The retained system audio no longer matches this transcript. Re-transcribe the meeting before analyzing speakers again."
        case .noSpeakerActivity:
            return "No usable remote speaker activity was found. The current transcript was not changed."
        case .controllerUnavailable:
            return "Speaker analysis is temporarily unavailable."
        }
    }
}
