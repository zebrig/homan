import Testing
@testable import MuesliNativeApp

@Suite("Meeting recording playback leases")
struct MeetingRecordingPlayerTests {
    @Test("playback holds a read lease until released")
    func playbackLeaseLifetime() throws {
        let registry = MeetingRecordingLeaseRegistry()
        let playback = try #require(
            MeetingRecordingPlaybackLease(recordingID: 42, registry: registry)
        )

        #expect(registry.acquireDeletion(for: .recordingID(42)) == nil)
        playback.release()
        let deletion = try #require(
            registry.acquireDeletion(for: .recordingID(42))
        )
        deletion.release()
    }
}
