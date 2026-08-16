import Foundation

/// Owns final meeting-processing tasks until they have fully unwound.
///
/// Application termination must not unload native inference libraries while a
/// stopped meeting is still using them. The registry therefore supports a
/// quiescing state: existing work is cancelled and awaited, and any work that
/// races with shutdown is immediately cancelled and included in the wait.
@MainActor
final class MeetingBackgroundProcessingRegistry {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var isQuiescing = false

    var count: Int { tasks.count }

    func insert(_ task: Task<Void, Never>, id: UUID) {
        tasks[id] = task
        if isQuiescing {
            task.cancel()
        }
    }

    func remove(id: UUID) {
        tasks[id] = nil
    }

    func cancelAllAndWait() async {
        isQuiescing = true

        // MainActor reentrancy permits a just-stopped meeting to register while
        // an earlier snapshot is being awaited. Loop until no owned work is
        // left, so shutdown cannot miss that race.
        while !tasks.isEmpty {
            let snapshot = tasks
            snapshot.values.forEach { $0.cancel() }
            for task in snapshot.values {
                await task.value
            }
            for id in snapshot.keys {
                tasks[id] = nil
            }
        }
    }
}
