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
}
