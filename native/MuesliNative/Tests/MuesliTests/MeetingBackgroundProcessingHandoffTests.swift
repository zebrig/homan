import Foundation
import Testing

@Suite("Meeting background processing handoff")
struct MeetingBackgroundProcessingHandoffTests {
    @Test("stopping publishes capture availability before background transcription")
    func stoppingPublishesCaptureAvailability() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MuesliNativeApp/MuesliController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let handoffStart = try #require(
            source.range(of: "// Unblock new recordings immediately")
        )
        let backgroundTaskStart = try #require(
            source.range(of: "Task { [weak self] in", range: handoffStart.upperBound..<source.endIndex)
        )
        let handoff = source[handoffStart.lowerBound..<backgroundTaskStart.lowerBound]

        let releaseSession = try #require(handoff.range(of: "activeMeetingSession = nil"))
        let finishStopping = try #require(handoff.range(of: "isStoppingMeetingRecording = false"))
        let publishState = try #require(handoff.range(of: "syncAppState()"))

        #expect(releaseSession.lowerBound < finishStopping.lowerBound)
        #expect(finishStopping.lowerBound < publishState.lowerBound)
    }
}
