import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting session pipeline")
struct MeetingSessionPipelineTests {
    @Test("streaming, chunked, and Final preserve the same role sequence")
    func adaptersPreserveRoleSequence() {
        let sessionID = UUID()
        let engine = NoopMeetingPartialEngine()
        let streaming = [
            MeetingStreamingPartialSession(
                engine: engine,
                source: .microphone
            ).provisionalAttributedTurn(
                text: "local",
                start: 0,
                end: 1,
                sessionID: sessionID
            ),
            MeetingStreamingPartialSession(
                engine: engine,
                source: .system
            ).provisionalAttributedTurn(
                text: "remote",
                start: 1,
                end: 2,
                sessionID: sessionID
            ),
        ].compactMap { $0 }
        let segments = [
            SpeechSegment(start: 0, end: 1, text: "local"),
            SpeechSegment(start: 1, end: 2, text: "remote"),
        ]
        let chunked = [
            MeetingChunkedLiveQueue.attributedTurns(
                from: [segments[0]],
                source: .microphone,
                sessionID: sessionID
            ),
            MeetingChunkedLiveQueue.attributedTurns(
                from: [segments[1]],
                source: .system,
                sessionID: sessionID
            ),
        ].flatMap { $0 }
        let final = TranscriptFormatter.attributedTurns(
            micSegments: [segments[0]],
            systemSegments: [segments[1]],
            diarizationSegments: nil,
            recordingSessionID: sessionID,
            isProvisional: false
        )

        let expected: [MeetingTranscriptRole] = [.you, .others]
        #expect(streaming.map(\.sourceRole) == expected)
        #expect(chunked.map(\.sourceRole) == expected)
        #expect(final.map(\.sourceRole) == expected)
        #expect(streaming.allSatisfy { $0.isProvisional })
        #expect(chunked.allSatisfy { $0.isProvisional })
        #expect(final.allSatisfy { !$0.isProvisional })
    }

    @Test("ten Live transitions do not alter canonical Final input or roles")
    func repeatedLiveTransitionsDoNotAlterFinalInput() throws {
        let support = try MeetingRecordingBundleTestSupport(testName: "live-transitions")
        defer { support.cleanup() }
        let capture = try MeetingProcessingCapture(
            meetingID: 42,
            startedAt: Date(timeIntervalSince1970: 1_000),
            finalModelID: BackendOption.whisperLargeTurbo.asrModelID,
            supportDirectory: support.supportDirectory
        )
        let microphone = MeetingAudioTestFixtures.overlapping().microphone
        let system = MeetingAudioTestFixtures.overlapping().system

        for index in 0..<10 {
            let micRange = index * microphone.count / 10..<(index + 1) * microphone.count / 10
            let systemRange = index * system.count / 10..<(index + 1) * system.count / 10
            capture.appendMicrophone(Array(microphone[micRange]))
            capture.appendSystem(Array(system[systemRange]))
            _ = MeetingChunkedLiveQueue.attributedTurns(
                from: [.init(start: Double(index), end: Double(index + 1), text: "preview")],
                source: index.isMultiple(of: 2) ? .microphone : .system,
                sessionID: nil
            )
        }
        let staged = try capture.finalize(endedAt: Date(timeIntervalSince1970: 1_010))
        let finalTurns = TranscriptFormatter.attributedTurns(
            micSegments: [.init(start: 0, end: 1, text: "local")],
            systemSegments: [.init(start: 0, end: 1, text: "remote")],
            diarizationSegments: nil,
            recordingSessionID: staged.manifest.sessionID,
            isProvisional: false
        )

        #expect(staged.manifest.microphoneSampleCount == microphone.count)
        #expect(staged.manifest.systemSampleCount == system.count)
        #expect(staged.manifest.finalModelID == BackendOption.whisperLargeTurbo.asrModelID)
        #expect(finalTurns.map(\.sourceRole) == [.you, .others])
    }
}

private final class NoopMeetingPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {}
    func process(samples: [Float]) async throws {}
    func shutdown() async {}
}
