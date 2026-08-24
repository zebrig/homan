import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting recording leases")
struct MeetingRecordingLeaseRegistryTests {
    @Test("multiple readers share a recording and block deletion")
    func readersBlockDeletion() throws {
        let registry = MeetingRecordingLeaseRegistry()
        let key = MeetingRecordingLeaseKey.recordingID(42)
        let first = try #require(registry.acquireRead(for: key))
        let second = try #require(registry.acquireRead(for: key))

        #expect(registry.isBusy(key))
        #expect(registry.acquireDeletion(for: key) == nil)

        first.release()
        #expect(registry.acquireDeletion(for: key) == nil)
        second.release()
        #expect(!registry.isBusy(key))
    }

    @Test("exclusive deletion blocks readers until released")
    func deletionBlocksReaders() throws {
        let registry = MeetingRecordingLeaseRegistry()
        let key = MeetingRecordingLeaseKey.sessionID(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        let deletion = try #require(registry.acquireDeletion(for: key))

        #expect(registry.acquireRead(for: key) == nil)
        #expect(registry.acquireDeletion(for: key) == nil)

        deletion.release()
        let read = try #require(registry.acquireRead(for: key))
        read.release()
    }

    @Test("release is idempotent")
    func releaseIsIdempotent() throws {
        let registry = MeetingRecordingLeaseRegistry()
        let key = MeetingRecordingLeaseKey.recordingID(7)
        let read = try #require(registry.acquireRead(for: key))

        read.release()
        read.release()

        let deletion = try #require(registry.acquireDeletion(for: key))
        deletion.release()
    }

    @Test("batch readers protect every unique recording across suspension")
    func batchReadersProtectEveryRecording() async throws {
        let registry = MeetingRecordingLeaseRegistry()
        let first = MeetingRecordingLeaseKey.recordingID(11)
        let second = MeetingRecordingLeaseKey.recordingID(12)
        let readers = try #require(registry.acquireReads(
            for: [first, second, first]
        ))

        // Model the await between source resolution and model preload. The
        // composite reader must remain live throughout that suspension.
        await Task.yield()

        #expect(registry.acquireDeletion(for: first) == nil)
        #expect(registry.acquireDeletion(for: second) == nil)
        readers.release()
        readers.release()

        let firstDeletion = try #require(registry.acquireDeletion(for: first))
        let secondDeletion = try #require(registry.acquireDeletion(for: second))
        firstDeletion.release()
        secondDeletion.release()
    }

    @Test("batch read acquisition is atomic when one recording is deleting")
    func batchReadAcquisitionIsAtomic() throws {
        let registry = MeetingRecordingLeaseRegistry()
        let available = MeetingRecordingLeaseKey.recordingID(21)
        let deleting = MeetingRecordingLeaseKey.recordingID(22)
        let deletion = try #require(registry.acquireDeletion(for: deleting))

        #expect(registry.acquireReads(for: [available, deleting]) == nil)

        // A failed set acquisition must not have incremented the available
        // member's reader count.
        let availableDeletion = try #require(
            registry.acquireDeletion(for: available)
        )
        availableDeletion.release()
        deletion.release()
    }
}
