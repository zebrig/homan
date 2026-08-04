import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting final processing service")
struct MeetingFinalProcessingServiceTests {
    @Test("normal Final and crash recovery produce equivalent attributed turns")
    func finalAndRecoveryAreEquivalent() async throws {
        let support = try MeetingRecordingBundleTestSupport(testName: "final-recovery")
        defer { support.cleanup() }
        let capture = try MeetingProcessingCapture(
            meetingID: 42,
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000),
            finalModelID: BackendOption.parakeetMultilingual.asrModelID,
            supportDirectory: support.supportDirectory
        )
        capture.appendMicrophone(MeetingAudioTestFixtures.microphoneOnly().microphone)
        capture.appendSystem(MeetingAudioTestFixtures.systemOnly().system)
        let staged = try capture.finalize(endedAt: Date(timeIntervalSince1970: 1_010))
        let provider = FinalRecoveryProvider()
        let pipeline = MeetingTranscriptionPipeline(provider: provider)

        let final = try await pipeline.process(
            stagedAudio: staged,
            backend: .parakeetMultilingual,
            languages: .init(),
            purpose: .final,
            systemDiarization: .optionalPost
        )
        let recovery = try await pipeline.process(
            stagedAudio: staged,
            backend: .parakeetMultilingual,
            languages: .init(),
            purpose: .recovery,
            systemDiarization: .optionalPost
        )

        #expect(final.attributedTurns == recovery.attributedTurns)
        #expect(final.formattedTranscript == recovery.formattedTranscript)
        #expect(final.attributedTurns.map(\.sourceRole) == [.you, .others])
    }
}

private struct FinalRecoveryProvider: MeetingTranscriptionProviding {
    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        let text = url.lastPathComponent == "mic-cleaned.wav" ? "local" : "remote"
        return SpeechTranscriptionResult(
            text: text,
            segments: [.init(start: 0, end: 0.1, text: text)]
        )
    }

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]? {
        nil
    }
}
