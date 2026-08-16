import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting background processing registry")
@MainActor
struct MeetingBackgroundProcessingRegistryTests {
    @Test("cancels and awaits every owned task")
    func cancellationBarrier() async {
        let registry = MeetingBackgroundProcessingRegistry()
        let probe = CancellationProbe()
        let task = Task {
            await probe.runUntilCancelled()
        }
        registry.insert(task, id: UUID())

        await probe.waitUntilStarted()
        await registry.cancelAllAndWait()

        #expect(registry.count == 0)
        #expect(registry.isQuiescing)
        #expect(await probe.didFinish)
    }

    @Test("work registered after quiescing is cancelled and awaited")
    func lateRegistrationDuringQuiescing() async {
        let registry = MeetingBackgroundProcessingRegistry()
        await registry.cancelAllAndWait()

        let probe = CancellationProbe()
        let task = Task {
            await probe.runUntilCancelled()
        }
        registry.insert(task, id: UUID())
        await registry.cancelAllAndWait()

        #expect(registry.count == 0)
        #expect(await probe.didObserveCancellation)
        #expect(await probe.didFinish)
    }
}

private actor CancellationProbe {
    private(set) var didObserveCancellation = false
    private(set) var didFinish = false
    private var started = false

    func runUntilCancelled() async {
        started = true
        while !Task.isCancelled {
            await Task.yield()
        }
        didObserveCancellation = true

        // Make the distinction between cancel and cancel-and-wait observable.
        for _ in 0..<8 {
            await Task.yield()
        }
        didFinish = true
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}
