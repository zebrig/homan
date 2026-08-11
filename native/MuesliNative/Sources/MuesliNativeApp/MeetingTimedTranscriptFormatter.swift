import Foundation
import MuesliCore

enum MeetingTimedTranscriptFormatter {
    private struct Cue {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    private struct ParsedTurn {
        let rawTimestamp: TimeInterval
        var text: String
    }

    static func timedText(meeting: MeetingRecord) -> String {
        cues(for: meeting).map { cue in
            "[\(formatCentiseconds(cue.start)) - \(formatCentiseconds(cue.end))] \(cue.text)"
        }.joined(separator: "\n")
    }

    static func webVTT(meeting: MeetingRecord) -> String {
        let cues = cues(for: meeting)
        guard !cues.isEmpty else { return "WEBVTT\n" }

        let body = cues.map { cue in
            let end = max(cue.end, cue.start + 0.001)
            return "\(formatMilliseconds(cue.start)) --> \(formatMilliseconds(end))\n\(cue.text)"
        }.joined(separator: "\n\n")
        return "WEBVTT\n\n\(body)\n"
    }

    private static func cues(for meeting: MeetingRecord) -> [Cue] {
        let turns = parseTurns(meeting.rawTranscript)
        guard !turns.isEmpty else { return [] }

        let duration = max(0, meeting.durationSeconds)
        let startSeconds = meetingStartSecondsOfDay(meeting.startTime)
        let timestampsAreWallClock = shouldTreatAsWallClock(
            firstTimestamp: turns[0].rawTimestamp,
            meetingStartSecondsOfDay: startSeconds,
            duration: duration
        )

        var starts: [TimeInterval] = []
        starts.reserveCapacity(turns.count)
        for turn in turns {
            var resolved = turn.rawTimestamp
            if timestampsAreWallClock, let startSeconds {
                resolved -= startSeconds
                while resolved < 0 { resolved += 86_400 }
            }
            if let previous = starts.last {
                while timestampsAreWallClock, resolved + 0.001 < previous {
                    resolved += 86_400
                }
                resolved = max(previous, resolved)
            }
            starts.append(max(0, resolved))
        }

        return turns.indices.map { index in
            let start = starts[index]
            let end: TimeInterval
            if starts.indices.contains(index + 1) {
                end = max(start, starts[index + 1])
            } else if duration > start {
                end = duration
            } else {
                end = start
            }
            return Cue(start: start, end: end, text: turns[index].text)
        }
    }

    private static func parseTurns(_ transcript: String) -> [ParsedTurn] {
        let pattern = #"^\[(\d+):(\d{2}):(\d{2})(?:[\.,](\d{1,3}))?\]\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var turns: [ParsedTurn] = []
        var untimedPrefix: [String] = []

        for rawLine in transcript.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)

            guard let match = regex.firstMatch(in: line, range: range), match.range == range,
                  let hours = integerCapture(1, match: match, in: line),
                  let minutes = integerCapture(2, match: match, in: line),
                  let seconds = integerCapture(3, match: match, in: line),
                  minutes < 60, seconds < 60 else {
                if turns.isEmpty {
                    untimedPrefix.append(line)
                } else {
                    turns[turns.count - 1].text += " " + line
                }
                continue
            }

            let fraction = fractionalCapture(4, match: match, in: line)
            let text = stringCapture(5, match: match, in: line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !untimedPrefix.isEmpty {
                turns.append(ParsedTurn(rawTimestamp: 0, text: untimedPrefix.joined(separator: " ")))
                untimedPrefix.removeAll(keepingCapacity: true)
            }
            turns.append(ParsedTurn(
                rawTimestamp: TimeInterval(hours * 3600 + minutes * 60 + seconds) + fraction,
                text: text
            ))
        }

        if turns.isEmpty, !untimedPrefix.isEmpty {
            return [ParsedTurn(rawTimestamp: 0, text: untimedPrefix.joined(separator: " "))]
        }
        return turns.filter { !$0.text.isEmpty }
    }

    private static func integerCapture(
        _ index: Int,
        match: NSTextCheckingResult,
        in text: String
    ) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return Int(text[range])
    }

    private static func fractionalCapture(
        _ index: Int,
        match: NSTextCheckingResult,
        in text: String
    ) -> TimeInterval {
        guard let range = Range(match.range(at: index), in: text) else { return 0 }
        let digits = String(text[range])
        guard let value = Int(digits) else { return 0 }
        return TimeInterval(value) / pow(10, Double(digits.count))
    }

    private static func stringCapture(
        _ index: Int,
        match: NSTextCheckingResult,
        in text: String
    ) -> String {
        guard let range = Range(match.range(at: index), in: text) else { return "" }
        return String(text[range])
    }

    private static func shouldTreatAsWallClock(
        firstTimestamp: TimeInterval,
        meetingStartSecondsOfDay: TimeInterval?,
        duration: TimeInterval
    ) -> Bool {
        guard let meetingStartSecondsOfDay else { return false }
        var wallOffset = firstTimestamp - meetingStartSecondsOfDay
        while wallOffset < 0 { wallOffset += 86_400 }

        let tolerance = max(60, min(300, duration * 0.1))
        let directIsPlausible = firstTimestamp <= duration + tolerance
        let wallClockIsPlausible = wallOffset <= duration + tolerance
        if wallClockIsPlausible != directIsPlausible {
            return wallClockIsPlausible
        }
        if wallClockIsPlausible, directIsPlausible {
            return abs(firstTimestamp - meetingStartSecondsOfDay) <= 60
        }
        return false
    }

    private static func meetingStartSecondsOfDay(_ raw: String) -> TimeInterval? {
        let date: Date?
        if let parsed = ISO8601DateFormatter().date(from: raw) {
            date = parsed
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            date = formatter.date(from: raw)
        }
        guard let date else { return nil }
        let components = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return TimeInterval((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0))
            + TimeInterval(components.nanosecond ?? 0) / 1_000_000_000
    }

    private static func formatCentiseconds(_ interval: TimeInterval) -> String {
        format(interval, unitsPerSecond: 100, fractionDigits: 2)
    }

    private static func formatMilliseconds(_ interval: TimeInterval) -> String {
        format(interval, unitsPerSecond: 1_000, fractionDigits: 3)
    }

    private static func format(
        _ interval: TimeInterval,
        unitsPerSecond: Int64,
        fractionDigits: Int
    ) -> String {
        let units = Int64((max(0, interval) * Double(unitsPerSecond)).rounded())
        let hours = units / (3_600 * unitsPerSecond)
        let minutes = (units / (60 * unitsPerSecond)) % 60
        let seconds = (units / unitsPerSecond) % 60
        let fraction = units % unitsPerSecond
        return String(
            format: "%02lld:%02lld:%02lld.%0*lld",
            hours,
            minutes,
            seconds,
            fractionDigits,
            fraction
        )
    }
}
