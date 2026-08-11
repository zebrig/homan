import Foundation
import MuesliCore

extension MeetingProcessingProgress {
    /// "3/7 Transcribing · 0:42 · 2:15" — phase, per-phase elapsed, total elapsed.
    func displayTitle(now: Date) -> String {
        "\(phaseIndex)/\(phaseCount) \(phaseLabel) · \(Self.elapsedString(from: phaseStartedAt, to: now)) · \(Self.elapsedString(from: totalStartedAt, to: now))"
    }

    /// "m:ss" with zero padding, e.g. `0:12`, `1:03`, `10:00`.
    static func elapsedString(from start: Date, to end: Date) -> String {
        let total = max(Int(end.timeIntervalSince(start)), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
