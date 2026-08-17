@preconcurrency import CoreML
import FluidAudio
import Foundation
import MuesliCore

/// A private Sortformer instance for one provisional Live epoch. Final uses a
/// different run and retained audio, so Live state can never leak into durable
/// evidence or race a Final model reset.
actor MeetingLiveDiarizationEngine {
    /// Captions only resolve recent speech. Retaining the entire provisional
    /// meeting would make every two-second update progressively more costly.
    private static let activityRetentionSeconds: TimeInterval = 120

    private let assets: MeetingDiarizationAssetStore
    private var manager: SortformerDiarizer?
    private var speakerLabels: [String: String] = [:]
    private var nextSpeakerNumber = 1

    init(assets: MeetingDiarizationAssetStore = .shared) {
        self.assets = assets
    }

    func prepare() async throws {
        let definition = MeetingDiarizationProfiles.resolve(.stableFourSpeaker)
        let ready = try await assets.requireReady(definition)
        try Task.checkCancellation()
        var timelineConfig = DiarizerTimelineConfig.sortformerDefault
        // Live needs segments, not the raw frame-probability history.
        timelineConfig.maxStoredFrames = 0
        let loaded = try MeetingDiarizationRuntime.loadSortformerManager(
            from: ready.directory,
            timelineConfig: timelineConfig
        )
        do {
            try Task.checkCancellation()
        } catch {
            loaded.cleanup()
            throw error
        }
        manager = loaded
        speakerLabels.removeAll(keepingCapacity: true)
        nextSpeakerNumber = 1
    }

    /// Processes one bounded buffer and returns the current provisional
    /// timeline. The caller shifts its epoch-relative times onto the Live
    /// transcript clock.
    func process(_ samples: [Float]) throws -> [MeetingDiarizationActivitySegment] {
        try Task.checkCancellation()
        guard let manager else {
            throw MeetingDiarizationAssetError.incomplete("Stable up to 4")
        }
        _ = try manager.process(samples: samples, sourceSampleRate: 16_000)
        try Task.checkCancellation()

        let timeline = manager.timeline
        let cutoff = max(0, TimeInterval(timeline.duration) - Self.activityRetentionSeconds)
        let speakers = timeline.speakers

        // Slot labels remain stable for the epoch even after old activity is
        // pruned. A newly active slot is numbered by its first observed turn.
        let newlyActive = speakers.compactMap { index, speaker -> (String, Float)? in
            let key = "slot-\(index)"
            guard speakerLabels[key] == nil,
                  let first = (speaker.finalizedSegments + speaker.tentativeSegments)
                    .min(by: { $0.startTime < $1.startTime }) else {
                return nil
            }
            return (key, first.startTime)
        }.sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        for (key, _) in newlyActive {
            speakerLabels[key] = "Speaker \(nextSpeakerNumber)"
            nextSpeakerNumber += 1
        }

        let raw = speakers
            .flatMap { index, speaker -> [(String, DiarizerSegment)] in
                let key = "slot-\(index)"
                let retainedFinalized = speaker.finalizedSegments.filter {
                    TimeInterval($0.endTime) >= cutoff
                }
                speaker.finalizedSegments = retainedFinalized
                return (retainedFinalized + speaker.tentativeSegments)
                    .map { (key, $0) }
            }
            .sorted { lhs, rhs in
                if lhs.1.startTime == rhs.1.startTime {
                    return lhs.0 < rhs.0
                }
                return lhs.1.startTime < rhs.1.startTime
            }
        return raw.map { key, segment in
            MeetingDiarizationActivitySegment(
                speakerKey: speakerLabels[key] ?? "Speaker",
                startSeconds: TimeInterval(segment.startTime),
                endSeconds: TimeInterval(segment.endTime),
                confidence: segment.activity
            )
        }
    }

    func stop() {
        manager?.cleanup()
        manager = nil
        speakerLabels.removeAll()
        nextSpeakerNumber = 1
    }
}

enum MeetingLiveSpeakerResolver {
    /// Conservative dominant-overlap attribution for provisional captions.
    /// Ambiguity intentionally remains `Others`.
    static func label(
        forStart start: TimeInterval,
        end: TimeInterval,
        activity: [MeetingDiarizationActivitySegment]
    ) -> String {
        guard start.isFinite, end.isFinite, end > start else { return "Others" }
        var overlapBySpeaker: [String: TimeInterval] = [:]
        for segment in activity {
            let overlap = max(0, min(end, segment.endSeconds) - max(start, segment.startSeconds))
            if overlap > 0 {
                overlapBySpeaker[segment.speakerKey, default: 0] += overlap
            }
        }
        let ordered = overlapBySpeaker.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        guard let dominant = ordered.first else { return "Others" }
        let total = ordered.reduce(0) { $0 + $1.value }
        let spanDuration = end - start
        guard dominant.value >= min(0.25, spanDuration * 0.25),
              total > 0,
              dominant.value / total >= 0.65,
              dominant.key.hasPrefix("Speaker ") else {
            return "Others"
        }
        return dominant.key
    }
}
