import Foundation

/// Coordinates heavyweight meeting inference with raw audio capture without
/// ever putting a permit in the capture callback path.
///
/// Capture merely publishes an owner token. New background inference waits
/// asynchronously, while already-running engines yield at their next bounded
/// checkpoint. Multiple recording sessions are supported so an old session
/// cannot accidentally resume work while a newer one is still capturing.
final class MeetingInferenceScheduler: @unchecked Sendable {
    static let shared = MeetingInferenceScheduler()

    private let condition = NSCondition()
    private var captureOwners: Set<UUID> = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var cancelledWaiters: Set<UUID> = []
    private var cancelOnCaptureHandlers: [UUID: @Sendable () -> Void] = [:]

    func beginCapture(ownerID: UUID) {
        condition.lock()
        captureOwners.insert(ownerID)
        let handlers = Array(cancelOnCaptureHandlers.values)
        condition.unlock()

        // Handlers are deliberately invoked after releasing the condition.
        // They may cancel tasks which promptly re-enter this scheduler.
        handlers.forEach { $0() }
    }

    func endCapture(ownerID: UUID) {
        condition.lock()
        captureOwners.remove(ownerID)
        guard captureOwners.isEmpty else {
            condition.unlock()
            return
        }
        let continuations = Array(waiters.values)
        waiters.removeAll()
        condition.broadcast()
        condition.unlock()

        continuations.forEach { $0.resume(returning: true) }
    }

    var isCaptureActive: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !captureOwners.isEmpty
    }

    /// Registers non-capture work which must be cancelled when recording
    /// starts (for example an explicit model download/compile). Registration
    /// is race-safe: if capture already began, the handler fires immediately.
    func registerCancellationOnCapture(
        _ handler: @escaping @Sendable () -> Void
    ) -> UUID {
        let id = UUID()
        condition.lock()
        cancelOnCaptureHandlers[id] = handler
        let isAlreadyCapturing = !captureOwners.isEmpty
        condition.unlock()
        if isAlreadyCapturing {
            handler()
        }
        return id
    }

    func unregisterCancellationOnCapture(_ id: UUID) {
        condition.lock()
        cancelOnCaptureHandlers.removeValue(forKey: id)
        condition.unlock()
    }

    /// Async boundary used before model load/inference and between engines.
    func waitUntilCaptureAllowsInference() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                condition.lock()
                if cancelledWaiters.remove(waiterID) != nil {
                    condition.unlock()
                    continuation.resume(returning: false)
                } else if captureOwners.isEmpty {
                    condition.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiters[waiterID] = continuation
                    condition.unlock()
                }
            }
        } onCancel: {
            self.cancelWaiter(waiterID)
        }
        clearCancelledWaiter(waiterID)
        guard admitted else { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Synchronous checkpoint for dependency callbacks which cannot be async.
    /// It is never called from capture or UI paths; blocking one inference
    /// worker here is intentional and prevents the following Core ML chunk
    /// from competing with an active recording.
    func waitAtInferenceCheckpoint() {
        condition.lock()
        while !captureOwners.isEmpty {
            condition.wait()
        }
        condition.unlock()
    }

    private func cancelWaiter(_ id: UUID) {
        condition.lock()
        if let continuation = waiters.removeValue(forKey: id) {
            condition.unlock()
            continuation.resume(returning: false)
            return
        }
        cancelledWaiters.insert(id)
        condition.unlock()
    }

    private func clearCancelledWaiter(_ id: UUID) {
        condition.lock()
        cancelledWaiters.remove(id)
        condition.unlock()
    }
}
