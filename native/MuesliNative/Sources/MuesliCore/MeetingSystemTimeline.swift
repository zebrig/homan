import CryptoKit
import Foundation

/// Describes how one retained recording unit is placed on the meeting-wide
/// system-audio clock used by local speaker analysis.
public struct MeetingSystemTimelineMapEntry: Codable, Sendable, Equatable {
    public enum BoundaryKind: String, Codable, Sendable, Equatable {
        case first
        case continuous
        case explicitGap = "explicit_gap"
        case overlapCompacted = "overlap_compacted"
    }

    public let unitID: String
    public let sourceFingerprint: String
    public let unitStartSeconds: TimeInterval
    public let unitEndSeconds: TimeInterval
    public let globalStartSeconds: TimeInterval
    public let globalEndSeconds: TimeInterval
    public let boundaryKind: BoundaryKind

    public init(
        unitID: String,
        sourceFingerprint: String,
        unitStartSeconds: TimeInterval,
        unitEndSeconds: TimeInterval,
        globalStartSeconds: TimeInterval,
        globalEndSeconds: TimeInterval,
        boundaryKind: BoundaryKind
    ) {
        self.unitID = unitID
        self.sourceFingerprint = sourceFingerprint
        self.unitStartSeconds = unitStartSeconds
        self.unitEndSeconds = unitEndSeconds
        self.globalStartSeconds = globalStartSeconds
        self.globalEndSeconds = globalEndSeconds
        self.boundaryKind = boundaryKind
    }
}

/// Durable, reversible map for the disposable meeting-global system render.
/// The render itself is temporary; this small map follows transcript retention.
public struct MeetingSystemTimelineMap: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let currentRenderVersion = "homan-system-pcm16-v1"

    public let schemaVersion: Int
    public let renderVersion: String
    public let totalDurationSeconds: TimeInterval
    public let entries: [MeetingSystemTimelineMapEntry]
    public let sourceFingerprints: [String]
    public let digest: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        renderVersion: String = currentRenderVersion,
        totalDurationSeconds: TimeInterval,
        entries: [MeetingSystemTimelineMapEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.renderVersion = renderVersion
        self.totalDurationSeconds = max(0, totalDurationSeconds)
        self.entries = entries
        self.sourceFingerprints = entries.map(\.sourceFingerprint)
        self.digest = Self.makeDigest(
            schemaVersion: schemaVersion,
            renderVersion: renderVersion,
            totalDurationSeconds: max(0, totalDurationSeconds),
            entries: entries
        )
    }

    private struct DigestPayload: Encodable {
        let schemaVersion: Int
        let renderVersion: String
        let totalDurationMicroseconds: Int64
        let entries: [MeetingSystemTimelineMapEntry]
    }

    private static func makeDigest(
        schemaVersion: Int,
        renderVersion: String,
        totalDurationSeconds: TimeInterval,
        entries: [MeetingSystemTimelineMapEntry]
    ) -> String {
        let payload = DigestPayload(
            schemaVersion: schemaVersion,
            renderVersion: renderVersion,
            totalDurationMicroseconds: Int64(
                (totalDurationSeconds * 1_000_000).rounded()
            ),
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
