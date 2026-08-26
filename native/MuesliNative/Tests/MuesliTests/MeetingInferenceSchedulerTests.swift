import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting inference scheduler")
struct MeetingInferenceSchedulerTests {
    @Test("capture never waits and inference resumes only after every capture owner leaves")
    func multipleCaptureOwners() async throws {
        let scheduler = MeetingInferenceScheduler()
        let first = UUID()
        let second = UUID()
        scheduler.beginCapture(ownerID: first)
        scheduler.beginCapture(ownerID: second)

        let admitted = Task {
            try await scheduler.waitUntilCaptureAllowsInference()
            return true
        }
        await Task.yield()
        #expect(scheduler.isCaptureActive)

        scheduler.endCapture(ownerID: first)
        #expect(scheduler.isCaptureActive)
        scheduler.endCapture(ownerID: second)

        #expect(try await admitted.value)
        #expect(!scheduler.isCaptureActive)
    }

    @Test("cancelled inference waiter is removed without waiting for capture end")
    func waiterCancellation() async throws {
        let scheduler = MeetingInferenceScheduler()
        let owner = UUID()
        scheduler.beginCapture(ownerID: owner)

        let waiter = Task {
            try await scheduler.waitUntilCaptureAllowsInference()
        }
        await Task.yield()
        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        scheduler.endCapture(ownerID: owner)
        try await scheduler.waitUntilCaptureAllowsInference()
    }

    @Test("ending an unknown owner cannot resume inference early")
    func unknownOwnerIsHarmless() async throws {
        let scheduler = MeetingInferenceScheduler()
        let owner = UUID()
        scheduler.beginCapture(ownerID: owner)
        scheduler.endCapture(ownerID: UUID())
        #expect(scheduler.isCaptureActive)
        scheduler.endCapture(ownerID: owner)
        try await scheduler.waitUntilCaptureAllowsInference()
    }

    @Test("capture cancels registered non-capture work without blocking capture")
    func captureCancellationRegistration() {
        let scheduler = MeetingInferenceScheduler()
        let probe = CaptureCancellationProbe()
        let registration = scheduler.registerCancellationOnCapture {
            probe.noteCancellation()
        }
        let owner = UUID()

        scheduler.beginCapture(ownerID: owner)
        #expect(probe.cancellationCount == 1)

        scheduler.unregisterCancellationOnCapture(registration)
        scheduler.beginCapture(ownerID: UUID())
        #expect(probe.cancellationCount == 1)
        scheduler.endCapture(ownerID: owner)
    }

    @Test("registration during capture is cancelled immediately")
    func lateCaptureCancellationRegistration() {
        let scheduler = MeetingInferenceScheduler()
        let owner = UUID()
        scheduler.beginCapture(ownerID: owner)
        let probe = CaptureCancellationProbe()

        let registration = scheduler.registerCancellationOnCapture {
            probe.noteCancellation()
        }

        #expect(probe.cancellationCount == 1)
        scheduler.unregisterCancellationOnCapture(registration)
        scheduler.endCapture(ownerID: owner)
    }

    @Test("async wait reports only the interval actually blocked by capture")
    func asyncWaitObservation() async throws {
        let scheduler = MeetingInferenceScheduler()
        let owner = UUID()
        let probe = InferenceWaitProbe()
        let observer = MeetingInferenceWaitObserver { probe.append($0) }
        scheduler.beginCapture(ownerID: owner)

        let waiter = Task {
            try await MeetingInferenceWaitContext.$observer.withValue(observer) {
                try await scheduler.waitUntilCaptureAllowsInference()
            }
        }

        #expect(await probe.waitForSnapshotCount(1))
        #expect(probe.snapshots.last?.isWaitingForCapture == true)
        scheduler.endCapture(ownerID: owner)
        try await waiter.value
        #expect(await probe.waitForSnapshotCount(2))
        #expect(probe.snapshots.map(\.isWaitingForCapture) == [true, false])
        #expect(probe.snapshots.map(\.revision) == [1, 2])
    }

    @Test("cancelled async wait clears its reported pause")
    func cancelledWaitObservation() async throws {
        let scheduler = MeetingInferenceScheduler()
        let owner = UUID()
        let probe = InferenceWaitProbe()
        let observer = MeetingInferenceWaitObserver { probe.append($0) }
        scheduler.beginCapture(ownerID: owner)

        let waiter = Task {
            try await MeetingInferenceWaitContext.$observer.withValue(observer) {
                try await scheduler.waitUntilCaptureAllowsInference()
            }
        }

        #expect(await probe.waitForSnapshotCount(1))
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(await probe.waitForSnapshotCount(2))
        #expect(probe.snapshots.map(\.isWaitingForCapture) == [true, false])
        scheduler.endCapture(ownerID: owner)
    }

    @Test("synchronous checkpoint reports a balanced capture wait")
    func synchronousWaitObservation() async throws {
        let scheduler = MeetingInferenceScheduler()
        let owner = UUID()
        let probe = InferenceWaitProbe()
        let observer = MeetingInferenceWaitObserver { probe.append($0) }
        scheduler.beginCapture(ownerID: owner)

        let waiter = Task.detached {
            MeetingInferenceWaitContext.$observer.withValue(observer) {
                scheduler.waitAtInferenceCheckpoint()
            }
        }

        #expect(await probe.waitForSnapshotCount(1))
        scheduler.endCapture(ownerID: owner)
        await waiter.value
        #expect(await probe.waitForSnapshotCount(2))
        #expect(probe.snapshots.map(\.isWaitingForCapture) == [true, false])
    }

    @Test("unblocked inference emits no pause status")
    func unblockedInferenceObservation() async throws {
        let scheduler = MeetingInferenceScheduler()
        let probe = InferenceWaitProbe()
        let observer = MeetingInferenceWaitObserver { probe.append($0) }

        try await MeetingInferenceWaitContext.$observer.withValue(observer) {
            try await scheduler.waitUntilCaptureAllowsInference()
            scheduler.waitAtInferenceCheckpoint()
        }

        #expect(probe.snapshots.isEmpty)
    }
}

private final class CaptureCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var cancellationCount: Int {
        lock.withLock { count }
    }

    func noteCancellation() {
        lock.withLock { count += 1 }
    }
}

private final class InferenceWaitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MeetingInferenceWaitSnapshot] = []

    var snapshots: [MeetingInferenceWaitSnapshot] {
        lock.withLock { storage }
    }

    func append(_ snapshot: MeetingInferenceWaitSnapshot) {
        lock.withLock { storage.append(snapshot) }
    }

    func waitForSnapshotCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while snapshots.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return snapshots.count >= count
    }
}
