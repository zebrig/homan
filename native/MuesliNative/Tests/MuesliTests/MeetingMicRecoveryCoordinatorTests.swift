import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting microphone recovery coordinator")
struct MeetingMicRecoveryCoordinatorTests {
    private final class Harness {
        let tracker = MeetingMicHealthTracker()
        var coordinator: MeetingMicRecoveryCoordinator!
        var events: [MeetingMicHealthEpisodeEvent] = []
        var requests: [String] = []
        var now = Date(timeIntervalSince1970: 1_000_000)

        init(cooldown: TimeInterval = 15, maxAttempts: Int = 2) {
            coordinator = MeetingMicRecoveryCoordinator(
                policy: .init(
                    attemptCooldown: cooldown,
                    maxAttemptsPerEpisode: maxAttempts
                ),
                now: { [weak self] in self?.now ?? Date() }
            )
            coordinator.recoveryRequest = { [weak self] reason in
                self?.requests.append(reason)
                return true
            }
            coordinator.onEpisodeEvent = { [weak self] event in
                self?.events.append(event)
            }
        }

        func systemActive(seconds: Int) {
            for _ in 0..<(seconds * 10) {
                coordinator.process(tracker.noteSystemSamples(
                    Array(repeating: 2_000, count: 1_600),
                    now: now
                ))
                now = now.addingTimeInterval(0.1)
            }
        }

        func micSignal() {
            coordinator.process(tracker.noteRawMicSamples(
                Array(repeating: 1_000, count: 1_600),
                now: now
            ))
        }

        func micSilence() {
            coordinator.process(tracker.noteRawMicSamples(
                Array(repeating: 0, count: 1_600),
                now: now
            ))
        }
    }

    @Test("confirmed degradation opens one episode and starts recovery")
    func confirmedDegradationStartsRecovery() {
        let harness = Harness()
        harness.systemActive(seconds: 4)

        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.requests == ["system_audio_active_without_mic_callbacks"])
        #expect(harness.coordinator.hasActiveEpisode)
    }

    @Test("continued degradation observes cooldown and bounded chain count")
    func cooldownAndAttemptCap() {
        let harness = Harness(cooldown: 0.5, maxAttempts: 2)
        harness.systemActive(seconds: 3)
        harness.systemActive(seconds: 1)
        harness.systemActive(seconds: 1)

        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.requests.count == 2)
    }

    @Test("healthy microphone closes the active episode")
    func healthySignalClosesEpisode() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.micSignal()
        harness.micSignal()

        #expect(harness.events.map(\.kind) == [.degraded, .recovered])
        #expect(harness.events.last?.recoveryAttempts == 1)
        #expect(!harness.coordinator.hasActiveEpisode)
    }

    @Test("a later degradation opens a distinct episode")
    func laterDegradationIsDistinct() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.micSignal()
        harness.systemActive(seconds: 4)

        #expect(harness.events.map(\.kind) == [.degraded, .recovered, .degraded])
        #expect(harness.events[0].episodeID != harness.events[2].episodeID)
    }

    @Test("changing degraded mode is one episode")
    func degradedModeChangeStaysInEpisode() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.micSilence()
        harness.systemActive(seconds: 4)
        harness.coordinator.finishMeeting()

        #expect(harness.events.map(\.kind) == [.degraded, .unrecovered])
        #expect(harness.events.last?.flapCount == 1)
    }

    @Test("meeting end emits one unrecovered terminal event")
    func meetingEndIsTerminal() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.coordinator.finishMeeting()
        harness.coordinator.finishMeeting()

        #expect(harness.events.map(\.kind) == [.degraded, .unrecovered])
        #expect(!harness.coordinator.hasActiveEpisode)
    }

    @Test("terminal failure remains reportable after active capture is released")
    func terminalFailureRemainsReportableAfterCaptureRelease() throws {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.coordinator.finishMeeting()

        let terminalEvent = try #require(harness.events.last)
        #expect(MeetingMicHealthIncidentPolicy.shouldRecordCaptureFailure(for: terminalEvent))

        let nonterminalEvent = try #require(harness.events.first)
        #expect(!MeetingMicHealthIncidentPolicy.shouldRecordCaptureFailure(for: nonterminalEvent))
    }

    @Test("late callbacks after finish cannot create a dangling episode")
    func lateCallbacksAreIgnored() {
        let harness = Harness()
        harness.coordinator.finishMeeting()
        harness.systemActive(seconds: 4)

        #expect(harness.events.isEmpty)
        #expect(harness.requests.isEmpty)
    }

    @Test("a rejected request is not counted and remains throttled")
    func rejectedRequestIsReleasedButThrottled() {
        let harness = Harness(cooldown: 15, maxAttempts: 1)
        harness.coordinator.recoveryRequest = { [weak harness] reason in
            harness?.requests.append(reason)
            return false
        }
        harness.systemActive(seconds: 4)
        harness.coordinator.finishMeeting()

        #expect(harness.requests.count == 1)
        #expect(harness.events.last?.recoveryAttempts == 0)
    }

    @Test("quiet microphone without active system audio is not degraded")
    func quietRoomIsNotDegraded() {
        let harness = Harness()
        harness.micSilence()
        harness.micSilence()

        #expect(harness.events.isEmpty)
        #expect(harness.requests.isEmpty)
    }

    @Test("callbacks can synchronously re-enter without deadlock")
    func callbacksCanReenter() {
        let harness = Harness()
        var reentered = false
        harness.coordinator.onEpisodeEvent = { [weak harness] event in
            harness?.events.append(event)
            guard !reentered else { return }
            reentered = true
            harness?.micSignal()
        }

        harness.systemActive(seconds: 4)

        #expect(harness.events.contains { $0.kind == .degraded })
    }
}
