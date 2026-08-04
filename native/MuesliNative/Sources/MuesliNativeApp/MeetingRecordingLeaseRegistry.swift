import Foundation
import os

struct MeetingRecordingLeaseKey: Hashable, Sendable {
    let rawValue: String

    static func recordingID(_ id: Int64) -> MeetingRecordingLeaseKey {
        MeetingRecordingLeaseKey(rawValue: "recording:\(id)")
    }

    static func sessionID(_ id: UUID) -> MeetingRecordingLeaseKey {
        MeetingRecordingLeaseKey(rawValue: "session:\(id.uuidString.lowercased())")
    }
}

final class MeetingRecordingLease: @unchecked Sendable {
    private let released = OSAllocatedUnfairLock(initialState: false)
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    func release() {
        let shouldRelease = released.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease {
            onRelease()
        }
    }

    deinit {
        release()
    }
}

final class MeetingRecordingLeaseRegistry: @unchecked Sendable {
    static let shared = MeetingRecordingLeaseRegistry()

    private struct State {
        var readers: [MeetingRecordingLeaseKey: Int] = [:]
        var deleting: Set<MeetingRecordingLeaseKey> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func acquireRead(for key: MeetingRecordingLeaseKey) -> MeetingRecordingLease? {
        let acquired = state.withLock { state in
            guard !state.deleting.contains(key) else { return false }
            state.readers[key, default: 0] += 1
            return true
        }
        guard acquired else { return nil }
        return MeetingRecordingLease { [weak self] in
            self?.releaseRead(for: key)
        }
    }

    func acquireDeletion(for key: MeetingRecordingLeaseKey) -> MeetingRecordingLease? {
        let acquired = state.withLock { state in
            guard !state.deleting.contains(key),
                  state.readers[key, default: 0] == 0 else {
                return false
            }
            state.deleting.insert(key)
            return true
        }
        guard acquired else { return nil }
        return MeetingRecordingLease { [weak self] in
            self?.releaseDeletion(for: key)
        }
    }

    func isBusy(_ key: MeetingRecordingLeaseKey) -> Bool {
        state.withLock {
            $0.deleting.contains(key) || $0.readers[key, default: 0] > 0
        }
    }

    private func releaseRead(for key: MeetingRecordingLeaseKey) {
        state.withLock { state in
            let count = state.readers[key, default: 0]
            if count <= 1 {
                state.readers.removeValue(forKey: key)
            } else {
                state.readers[key] = count - 1
            }
        }
    }

    private func releaseDeletion(for key: MeetingRecordingLeaseKey) {
        _ = state.withLock { $0.deleting.remove(key) }
    }
}
