import Foundation
import os

final class MeetingMicHandoffStartLease: @unchecked Sendable {
    let id: UUID
    let startedAtNanoseconds: UInt64

    private let released = OSAllocatedUnfairLock(initialState: false)
    private let releaseAction: @Sendable (UUID) -> Void

    init(
        id: UUID,
        startedAtNanoseconds: UInt64,
        releaseAction: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.startedAtNanoseconds = startedAtNanoseconds
        self.releaseAction = releaseAction
    }

    func release() {
        let shouldRelease = released.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease {
            releaseAction(id)
        }
    }

    deinit {
        release()
    }
}

enum MeetingMicHandoffStartAcquisition {
    case acquired(MeetingMicHandoffStartLease)
    case waiting(blockingLeaseID: UUID)
}

final class MeetingMicHandoffStartGate: @unchecked Sendable {
    static let shared = MeetingMicHandoffStartGate()

    private struct Waiter {
        let wake: @Sendable () -> Void
    }

    private struct State {
        var leaseID: UUID?
        var waitersByOwnerID: [UUID: Waiter] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let wakeQueue: DispatchQueue

    init(
        wakeQueue: DispatchQueue = DispatchQueue(
            label: "com.muesli.route-aware-meeting-mic-recorder-start-gate-wake",
            qos: .userInitiated,
            attributes: .concurrent
        )
    ) {
        self.wakeQueue = wakeQueue
    }

    func acquireOrWait(
        ownerID: UUID,
        wake: @escaping @Sendable () -> Void
    ) -> MeetingMicHandoffStartAcquisition {
        let leaseID = UUID()
        let blockingLeaseID = state.withLock { state -> UUID? in
            if let blockingLeaseID = state.leaseID {
                state.waitersByOwnerID[ownerID] = Waiter(wake: wake)
                return blockingLeaseID
            }
            state.leaseID = leaseID
            state.waitersByOwnerID.removeValue(forKey: ownerID)
            return nil
        }
        if let blockingLeaseID {
            return .waiting(blockingLeaseID: blockingLeaseID)
        }
        let lease = MeetingMicHandoffStartLease(
            id: leaseID,
            startedAtNanoseconds: AudioLifecycleDiagnostics.monotonicNowNanoseconds()
        ) { [self] leaseID in
            release(leaseID: leaseID)
        }
        return .acquired(lease)
    }

    func cancelWaiter(ownerID: UUID) {
        _ = state.withLock { $0.waitersByOwnerID.removeValue(forKey: ownerID) }
    }

    func unfinishedLeaseCountForDebug() -> Int {
        state.withLock { $0.leaseID == nil ? 0 : 1 }
    }

    func waiterCountForDebug() -> Int {
        state.withLock { $0.waitersByOwnerID.count }
    }

    private func release(leaseID: UUID) {
        let wakeups = state.withLock { state -> [@Sendable () -> Void] in
            guard state.leaseID == leaseID else { return [] }
            state.leaseID = nil
            let wakeups = state.waitersByOwnerID.values.map(\.wake)
            state.waitersByOwnerID.removeAll()
            return wakeups
        }
        for wake in wakeups {
            wakeQueue.async(execute: wake)
        }
    }
}
