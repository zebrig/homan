import FluidAudio
import Foundation
import MuesliCore

enum TranscriptFormatter {
    /// Backward-compatible merge without diarization.
    static func merge(micSegments: [SpeechSegment], systemSegments: [SpeechSegment], meetingStart: Date) -> String {
        merge(micSegments: micSegments, systemSegments: systemSegments, diarizationSegments: nil, meetingStart: meetingStart)
    }

    /// Merge with optional speaker diarization for system audio.
    static func merge(
        micSegments: [SpeechSegment],
        systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?,
        meetingStart: Date
    ) -> String {
        format(
            attributedTurns: attributedTurns(
                micSegments: micSegments,
                systemSegments: systemSegments,
                diarizationSegments: diarizationSegments,
                recordingSessionID: nil,
                isProvisional: false
            ),
            meetingStart: meetingStart
        )
    }

    static func attributedTurns(
        micSegments: [SpeechSegment],
        systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?,
        recordingSessionID: UUID?,
        isProvisional: Bool
    ) -> [AttributedTurn] {
        let speakerLabelMap = remoteSpeakerLabelMap(for: diarizationSegments ?? [])
        let microphoneTurns = micSegments.map {
            AttributedTurn(
                sourceRole: .you,
                remoteSpeaker: nil,
                startSeconds: $0.start,
                endSeconds: $0.end,
                text: $0.text,
                isProvisional: isProvisional,
                recordingSessionID: recordingSessionID
            )
        }
        let systemTurns = systemSegments.map { segment in
            let speaker: String?
            if let diarizationSegments, !diarizationSegments.isEmpty {
                let resolved = findSpeaker(
                    for: segment,
                    in: diarizationSegments,
                    labelMap: speakerLabelMap
                )
                speaker = resolved == "Others" ? nil : resolved
            } else {
                speaker = nil
            }
            return AttributedTurn(
                sourceRole: .others,
                remoteSpeaker: speaker,
                startSeconds: segment.start,
                endSeconds: segment.end,
                text: segment.text,
                isProvisional: isProvisional,
                recordingSessionID: recordingSessionID
            )
        }
        return consolidateTurns(
            (microphoneTurns + systemTurns).enumerated().sorted { lhs, rhs in
                if lhs.element.startSeconds == rhs.element.startSeconds {
                    let lhsRank = sourceRank(lhs.element.sourceRole)
                    let rhsRank = sourceRank(rhs.element.sourceRole)
                    return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
                }
                return lhs.element.startSeconds < rhs.element.startSeconds
            }.map(\.element)
        )
    }

    static func legacyAttributedTurns(
        segments: [SpeechSegment],
        recordingSessionID: UUID?,
        isProvisional: Bool
    ) -> [AttributedTurn] {
        consolidateTurns(segments.map {
            AttributedTurn(
                sourceRole: .legacyUnknown,
                remoteSpeaker: nil,
                startSeconds: $0.start,
                endSeconds: $0.end,
                text: $0.text,
                isProvisional: isProvisional,
                recordingSessionID: recordingSessionID
            )
        })
    }

    static func format(
        attributedTurns: [AttributedTurn],
        meetingStart: Date
    ) -> String {
        let consolidated = consolidateTurns(attributedTurns)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"

        return consolidated.map { turn in
            let timestamp = meetingStart.addingTimeInterval(turn.startSeconds)
            let text = turn.text.trimmingCharacters(in: .whitespaces)
            return "[\(formatter.string(from: timestamp))] \(speakerLabel(for: turn)): \(text)"
        }.joined(separator: "\n")
    }

    /// Merge consecutive segments from the same speaker into single entries,
    /// but only when they're temporally close (within 2s). This prevents
    /// token-level fragmentation while preserving chronological ordering —
    /// segments from the same speaker that are far apart in time stay separate
    /// so they interleave correctly with other speakers.
    private static let consolidationGapThreshold: TimeInterval = 2.0

    private static func consolidateTurns(_ turns: [AttributedTurn]) -> [AttributedTurn] {
        guard !turns.isEmpty else { return [] }

        var result: [AttributedTurn] = []
        var current = turns[0]

        for turn in turns.dropFirst() {
            let gap = max(0, turn.startSeconds - current.endSeconds)
            if turn.sourceRole == current.sourceRole,
               turn.remoteSpeaker == current.remoteSpeaker,
               turn.recordingSessionID == current.recordingSessionID,
               turn.isProvisional == current.isProvisional,
               gap <= consolidationGapThreshold {
                // Same speaker, temporally close — accumulate text
                current = AttributedTurn(
                    sourceRole: current.sourceRole,
                    remoteSpeaker: current.remoteSpeaker,
                    startSeconds: current.startSeconds,
                    endSeconds: max(current.endSeconds, turn.endSeconds),
                    text: appendText(current.text, turn.text, gap: gap),
                    isProvisional: current.isProvisional,
                    recordingSessionID: current.recordingSessionID
                )
            } else {
                // Different speaker or too far apart — emit and start new segment
                result.append(current)
                current = turn
            }
        }
        result.append(current)
        return result
    }

    private static func remoteSpeakerLabelMap(
        for diarizationSegments: [TimedSpeakerSegment]
    ) -> [String: String] {
        var speakerLabelMap: [String: String] = [:]
        var nextSpeakerNumber = 1
        for segment in diarizationSegments.sorted(by: {
            $0.startTimeSeconds < $1.startTimeSeconds
        }) where speakerLabelMap[segment.speakerId] == nil {
            speakerLabelMap[segment.speakerId] = "Speaker \(nextSpeakerNumber)"
            nextSpeakerNumber += 1
        }
        return speakerLabelMap
    }

    private static func speakerLabel(for turn: AttributedTurn) -> String {
        switch turn.sourceRole {
        case .you:
            return "You"
        case .others:
            return turn.remoteSpeaker ?? "Others"
        case .legacyUnknown:
            return "Speaker"
        }
    }

    private static func sourceRank(_ role: MeetingTranscriptRole) -> Int {
        switch role {
        case .you: return 0
        case .others: return 1
        case .legacyUnknown: return 2
        }
    }

    /// Find the best-matching speaker for an ASR segment by time overlap with diarization segments.
    private static func findSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        labelMap: [String: String]
    ) -> String {
        if labelMap.count == 1 {
            return labelMap.values.first ?? "Others"
        }

        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1)) // ensure non-zero duration

        var bestOverlap: Float = 0
        var bestSpeakerId: String?

        for diarSeg in diarizationSegments {
            let overlapStart = max(segStart, diarSeg.startTimeSeconds)
            let overlapEnd = min(segEnd, diarSeg.endTimeSeconds)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeakerId = diarSeg.speakerId
            }
        }

        if let bestSpeakerId, bestOverlap > 0 {
            return labelMap[bestSpeakerId] ?? "Others"
        }

        if let nearestSpeakerId = nearestSpeaker(
            for: segment,
            in: diarizationSegments,
            maxGapSeconds: 2.0
        ) {
            return labelMap[nearestSpeakerId] ?? "Others"
        }
        return "Others"
    }


    private static func nearestSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        maxGapSeconds: Float
    ) -> String? {
        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1))
        let segMidpoint = (segStart + segEnd) / 2

        let nearest = diarizationSegments.min { lhs, rhs in
            temporalGap(between: segMidpoint, and: lhs) < temporalGap(between: segMidpoint, and: rhs)
        }

        guard let nearest else { return nil }
        return temporalGap(between: segMidpoint, and: nearest) <= maxGapSeconds ? nearest.speakerId : nil
    }

    private static func temporalGap(
        between point: Float,
        and diarizationSegment: TimedSpeakerSegment
    ) -> Float {
        if point < diarizationSegment.startTimeSeconds {
            return diarizationSegment.startTimeSeconds - point
        }
        if point > diarizationSegment.endTimeSeconds {
            return point - diarizationSegment.endTimeSeconds
        }
        return 0
    }

    private static func appendText(_ lhs: String, _ rhs: String, gap: TimeInterval) -> String {
        if shouldConcatenateDirectly(lhs, rhs, gap: gap) {
            return lhs + rhs
        }
        return joinText(lhs, rhs)
    }

    private static func shouldConcatenateDirectly(_ lhs: String, _ rhs: String, gap: TimeInterval) -> Bool {
        guard gap <= 0.35 else { return false }
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        guard !rhs.contains(where: \.isWhitespace) else { return false }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else { return false }
        guard !lhsLast.isWhitespace, !rhsFirst.isWhitespace, !rhsFirst.isPunctuation else { return false }

        let lhsLastToken = lhs.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? lhs
        guard !lhsLastToken.contains(where: \.isWhitespace) else { return false }

        let lhsVisibleLength = visibleLength(of: lhsLastToken)
        let rhsVisibleLength = visibleLength(of: rhs)
        return lhsVisibleLength + rhsVisibleLength <= 8
    }

    private static func joinText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else {
            return lhs + rhs
        }

        if lhsLast.isWhitespace || rhsFirst.isWhitespace || rhsFirst.isPunctuation {
            return lhs + rhs
        }

        if lhsLast.isPunctuation {
            return lhs + " " + rhs
        }

        return lhs + " " + rhs
    }

    private static func visibleLength(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + (CharacterSet.whitespacesAndNewlines.contains(scalar) ? 0 : 1)
        }
    }

}
