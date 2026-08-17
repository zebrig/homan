import Foundation

/// Deterministic, source-authoritative join between recognized spans and
/// acoustic speaker activity. It deliberately contains no model code and may
/// be rerun after either evidence revision changes.
public enum MeetingSpeakerAttribution {
    public static let algorithmID = "homan-boundary-overlap"
    public static let algorithmRevision = 2

    public struct Policy: Sendable, Equatable {
        public var fineMinimumCoverage: Double
        public var fineMinimumDominanceMargin: Double
        public var coarseMinimumCoverage: Double
        public var coarseMinimumDominanceMargin: Double
        public var publicationMinimumCoverage: Double
        public var publicationMaximumAmbiguousFraction: Double

        public init(
            fineMinimumCoverage: Double = 0.20,
            fineMinimumDominanceMargin: Double = 0.15,
            coarseMinimumCoverage: Double = 0.60,
            coarseMinimumDominanceMargin: Double = 0.15,
            publicationMinimumCoverage: Double = 0.60,
            publicationMaximumAmbiguousFraction: Double = 0.40
        ) {
            self.fineMinimumCoverage = fineMinimumCoverage
            self.fineMinimumDominanceMargin = fineMinimumDominanceMargin
            self.coarseMinimumCoverage = coarseMinimumCoverage
            self.coarseMinimumDominanceMargin = coarseMinimumDominanceMargin
            self.publicationMinimumCoverage = publicationMinimumCoverage
            self.publicationMaximumAmbiguousFraction = publicationMaximumAmbiguousFraction
        }

        public static let `default` = Policy()
    }

    public static func makeRevision(
        meetingID: Int64,
        transcript: MeetingTranscriptRevision,
        diarization: MeetingDiarizationRevision?,
        policy: Policy = .default,
        now: Date = Date()
    ) -> MeetingAttributionRevision {
        let activity = diarization?.activitySegments ?? []
        var labelMap: [String: String] = [:]
        var nextSpeakerNumber = 1

        var assignments: [MeetingSpanSpeakerAssignment] = []
        var timedSystemCount = 0
        var assignedSystemCount = 0
        var ambiguousSystemCount = 0

        // Speaker numbers follow the first accepted ASR appearance, not model
        // activity in silence and not provider array order.
        let orderedSpans = transcript.spans.sorted { lhs, rhs in
            let lhsStart = lhs.startSeconds ?? .greatestFiniteMagnitude
            let rhsStart = rhs.startSeconds ?? .greatestFiniteMagnitude
            if lhsStart == rhsStart { return lhs.id < rhs.id }
            return lhsStart < rhsStart
        }
        for span in orderedSpans {
            switch span.source {
            case .microphone:
                assignments.append(MeetingSpanSpeakerAssignment(
                    asrSpanID: span.id,
                    speakerKey: nil,
                    displayLabel: "You",
                    kind: .sourceAuthoritative,
                    coverage: 1
                ))
            case .system, .legacyMixed:
                let genericLabel = span.source == .system ? "Others" : "Speaker"
                guard span.hasUsableBounds,
                      span.timestampPrecision != .none,
                      let start = span.startSeconds,
                      let end = span.endSeconds else {
                    assignments.append(MeetingSpanSpeakerAssignment(
                        asrSpanID: span.id,
                        speakerKey: nil,
                        displayLabel: genericLabel,
                        kind: .ambiguous
                    ))
                    ambiguousSystemCount += 1
                    continue
                }
                timedSystemCount += 1
                let duration = max(end - start, 0.001)
                var overlapBySpeaker: [String: TimeInterval] = [:]
                for segment in activity {
                    let overlap = max(0, min(end, segment.endSeconds) - max(start, segment.startSeconds))
                    if overlap > 0 {
                        overlapBySpeaker[segment.speakerKey, default: 0] += overlap
                    }
                }
                let ranked = overlapBySpeaker.sorted { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key < rhs.key }
                    return lhs.value > rhs.value
                }
                guard let best = ranked.first else {
                    assignments.append(MeetingSpanSpeakerAssignment(
                        asrSpanID: span.id,
                        speakerKey: nil,
                        displayLabel: genericLabel,
                        kind: .ambiguous
                    ))
                    ambiguousSystemCount += 1
                    continue
                }

                let bestCoverage = min(best.value / duration, 1)
                let secondCoverage = min((ranked.dropFirst().first?.value ?? 0) / duration, 1)
                let accepted: Bool
                let kind: MeetingSpeakerAssignmentKind
                switch span.timestampPrecision {
                case .word, .modelSegment:
                    accepted = bestCoverage >= policy.fineMinimumCoverage
                        && bestCoverage - secondCoverage >= policy.fineMinimumDominanceMargin
                    kind = .exactOverlap
                case .vadItem:
                    accepted = bestCoverage >= policy.coarseMinimumCoverage
                        && bestCoverage - secondCoverage >= policy.coarseMinimumDominanceMargin
                    kind = .dominantCoarse
                case .none:
                    accepted = false
                    kind = .ambiguous
                }

                if accepted {
                    let label: String
                    if let existing = labelMap[best.key] {
                        label = existing
                    } else {
                        label = "Speaker \(nextSpeakerNumber)"
                        nextSpeakerNumber += 1
                        labelMap[best.key] = label
                    }
                    assignments.append(MeetingSpanSpeakerAssignment(
                        asrSpanID: span.id,
                        speakerKey: best.key,
                        displayLabel: label,
                        kind: kind,
                        overlapSeconds: best.value,
                        coverage: bestCoverage
                    ))
                    assignedSystemCount += 1
                } else {
                    assignments.append(MeetingSpanSpeakerAssignment(
                        asrSpanID: span.id,
                        speakerKey: nil,
                        displayLabel: genericLabel,
                        kind: .ambiguous,
                        overlapSeconds: best.value,
                        coverage: bestCoverage
                    ))
                    ambiguousSystemCount += 1
                }
            }
        }

        let coverage = timedSystemCount > 0
            ? Double(assignedSystemCount) / Double(timedSystemCount)
            : 0
        let remoteSpanCount = transcript.spans.filter {
            $0.source == .system || $0.source == .legacyMixed
        }.count
        let ambiguousFraction = remoteSpanCount > 0
            ? Double(ambiguousSystemCount) / Double(remoteSpanCount)
            : 0
        let usefulSpeakers = labelMap.count
        let separatedEligible = usefulSpeakers >= 2
            && coverage >= policy.publicationMinimumCoverage
            && ambiguousFraction <= policy.publicationMaximumAmbiguousFraction
        let reason: String
        if diarization == nil {
            reason = "speaker analysis unavailable"
        } else if usefulSpeakers < 2 {
            reason = "fewer than two useful remote speakers"
        } else if coverage < policy.publicationMinimumCoverage {
            reason = "insufficient timestamp assignment coverage"
        } else if ambiguousFraction > policy.publicationMaximumAmbiguousFraction {
            reason = "too much ambiguous remote speech"
        } else {
            reason = "speaker separation quality accepted"
        }

        return MeetingAttributionRevision(
            meetingID: meetingID,
            createdAt: now,
            transcriptRevisionID: transcript.id,
            diarizationRevisionID: diarization?.id,
            algorithmID: algorithmID,
            algorithmRevision: algorithmRevision,
            assignments: assignments,
            speakerLabelMap: labelMap,
            quality: MeetingAttributionQuality(
                timedSystemSpanCount: timedSystemCount,
                assignedSystemSpanCount: assignedSystemCount,
                ambiguousSystemSpanCount: ambiguousSystemCount,
                assignmentCoverage: coverage,
                publicationReason: reason
            ),
            separatedEligible: separatedEligible
        )
    }
}
