import Foundation
import MuesliCore

/// Shared, compact formatting for model download status shown in the native UI.
enum ModelDownloadDisplayFormatting {
    static func isActiveJob(_ snapshot: ModelDownloadProgress?) -> Bool {
        snapshot?.phase == .downloading || snapshot?.phase == .preparing
    }

    static func blocksActivation(_ snapshot: ModelDownloadProgress?) -> Bool {
        snapshot?.phase == .failed
    }

    static func bytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB", value / 1_000) }
        return "\(bytes) B"
    }

    static func eta(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let roundedSeconds = seconds.rounded()
        // An ETA beyond one year is not useful to display and must not be
        // converted to Int, where an extreme finite Double can overflow.
        let maximumDisplayableSeconds = Double(365 * 24 * 60 * 60)
        guard roundedSeconds <= maximumDisplayableSeconds else { return nil }
        let totalSeconds = Int(roundedSeconds)
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        if minutes < 60 { return "\(minutes)m \(String(format: "%02d", remainingSeconds))s" }
        let hours = minutes / 60
        return "\(hours)h \(String(format: "%02d", minutes % 60))m"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "" }
        if bytesPerSecond >= 1_000_000_000 {
            return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }

    static func detail(_ snapshot: ModelDownloadProgress) -> String {
        if snapshot.phase != .downloading, let message = snapshot.message, !message.isEmpty {
            return message
        }
        var components: [String] = []
        if let total = snapshot.totalBytes, total > 0 {
            components.append("\(bytes(snapshot.completedBytes)) of \(bytes(total))")
        } else if snapshot.completedBytes > 0 {
            components.append(bytes(snapshot.completedBytes))
        } else if let message = snapshot.message, !message.isEmpty {
            components.append(message)
        }
        let transferRate = rate(snapshot.bytesPerSecond)
        if !transferRate.isEmpty { components.append(transferRate) }
        if let remaining = snapshot.estimatedSecondsRemaining,
           let eta = eta(remaining) {
            components.append("\(eta) remaining")
        }
        return components.isEmpty ? "Starting download..." : components.joined(separator: " • ")
    }
}
