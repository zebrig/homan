import Foundation

enum MeetingMicHealthEpisodeKind: String, Equatable {
    case degraded
    case recovered
    case unrecovered
}

struct MeetingMicHealthEpisodeEvent: Equatable {
    let kind: MeetingMicHealthEpisodeKind
    let episodeID: UUID
    let reason: String
    let state: MeetingMicHealthState
    let durationSeconds: TimeInterval
    let flapCount: Int
    let recoveryAttempts: Int
}

enum MeetingMicHealthIncidentPolicy {
    /// Terminal recovery failures are emitted while `MeetingSession.stop()` is
    /// finishing. By then the controller has intentionally released active
    /// capture ownership so another meeting can start, but the session-scoped
    /// callback still belongs to the meeting that just stopped.
    static func shouldRecordCaptureFailure(for event: MeetingMicHealthEpisodeEvent) -> Bool {
        event.kind == .unrecovered
    }
}

/// Collapses the raw health stream into bounded degradation episodes and asks
/// the route-aware recorder to rebuild the current route when it silently dies.
final class MeetingMicRecoveryCoordinator {
    struct Policy: Equatable {
        var attemptCooldown: TimeInterval = 15
        /// Each attempt starts one Homan handoff chain; the recorder performs
        /// its own initial + 0.5 s + 1 s candidate retries inside that chain.
        var maxAttemptsPerEpisode: Int = 2

        static let `default` = Policy()
    }

    private struct Episode {
        let id: UUID
        let startedAt: Date
        let initialReason: String
        let initialState: MeetingMicHealthState
        var flapCount = 0
        var recoveryAttempts = 0
        var lastRequestAt: Date?
    }

    var recoveryRequest: (String) -> Bool = { _ in false }
    var onEpisodeEvent: ((MeetingMicHealthEpisodeEvent) -> Void)?

    private let policy: Policy
    private let now: () -> Date
    private let lock = NSLock()
    private var episode: Episode?
    private var previousState: MeetingMicHealthState?
    private var finished = false

    init(policy: Policy = .default, now: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.now = now
    }

    func process(_ snapshot: MeetingMicHealthSnapshot) {
        var event: MeetingMicHealthEpisodeEvent?
        var request: RecoveryRequest?

        lock.lock()
        if !finished {
            let timestamp = now()
            let current = snapshot.state
            let prior = previousState
            previousState = current

            if Self.isDegraded(current), var active = episode {
                if let prior, prior != current {
                    active.flapCount += 1
                }
                request = reserveIfDue(&active, at: timestamp)
                episode = active
            } else if Self.isDegraded(current) {
                let reason = snapshot.transitions.last?.reason ?? "unknown"
                var opened = Episode(
                    id: UUID(),
                    startedAt: timestamp,
                    initialReason: reason,
                    initialState: current
                )
                event = makeEvent(kind: .degraded, episode: opened, at: timestamp)
                request = reserveIfDue(&opened, at: timestamp)
                episode = opened
            } else if current == .healthy, let active = episode {
                episode = nil
                event = makeEvent(kind: .recovered, episode: active, at: timestamp)
            }
        }
        lock.unlock()

        if let event { onEpisodeEvent?(event) }
        if let request, isCurrent(request), !recoveryRequest(request.reason) {
            releaseAttempt(request)
        }
    }

    /// Seals the coordinator so callbacks already queued during teardown cannot
    /// create an episode after its terminal event has been emitted.
    func finishMeeting() {
        var event: MeetingMicHealthEpisodeEvent?
        lock.lock()
        if !finished {
            finished = true
            if let active = episode {
                episode = nil
                event = makeEvent(kind: .unrecovered, episode: active, at: now())
            }
        }
        lock.unlock()
        if let event { onEpisodeEvent?(event) }
    }

    var hasActiveEpisode: Bool {
        lock.withLock { episode != nil }
    }

    private struct RecoveryRequest {
        let episodeID: UUID
        let reason: String
        let requestedAt: Date
    }

    private static func isDegraded(_ state: MeetingMicHealthState) -> Bool {
        state == .micCallbacksMissing || state == .micAllZeroWhileSystemActive
    }

    private func reserveIfDue(_ active: inout Episode, at timestamp: Date) -> RecoveryRequest? {
        guard active.recoveryAttempts < policy.maxAttemptsPerEpisode else { return nil }
        if let lastRequestAt = active.lastRequestAt,
           timestamp.timeIntervalSince(lastRequestAt) < policy.attemptCooldown {
            return nil
        }
        active.recoveryAttempts += 1
        active.lastRequestAt = timestamp
        return RecoveryRequest(
            episodeID: active.id,
            reason: active.initialReason,
            requestedAt: timestamp
        )
    }

    private func releaseAttempt(_ request: RecoveryRequest) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = episode,
              active.id == request.episodeID,
              active.lastRequestAt == request.requestedAt else { return }
        active.recoveryAttempts = max(0, active.recoveryAttempts - 1)
        // Keep the request timestamp as a throttle. Without it, every audio
        // callback would immediately retry while another handoff is pending.
        episode = active
    }

    private func isCurrent(_ request: RecoveryRequest) -> Bool {
        lock.withLock {
            !finished
                && episode?.id == request.episodeID
                && episode?.lastRequestAt == request.requestedAt
        }
    }

    private func makeEvent(
        kind: MeetingMicHealthEpisodeKind,
        episode: Episode,
        at timestamp: Date
    ) -> MeetingMicHealthEpisodeEvent {
        MeetingMicHealthEpisodeEvent(
            kind: kind,
            episodeID: episode.id,
            reason: episode.initialReason,
            state: episode.initialState,
            durationSeconds: max(0, timestamp.timeIntervalSince(episode.startedAt)),
            flapCount: episode.flapCount,
            recoveryAttempts: episode.recoveryAttempts
        )
    }
}
