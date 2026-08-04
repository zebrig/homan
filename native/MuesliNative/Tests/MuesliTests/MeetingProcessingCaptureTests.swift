import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting processing capture")
struct MeetingProcessingCaptureTests {
    @Test("finalize preserves full microphone and system WAVs")
    func finalizePreservesBothSources() throws {
        let supportDirectory = temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let capture = try MeetingProcessingCapture(
            meetingID: 42,
            sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            startedAt: startedAt,
            finalModelID: BackendOption.whisperLargeTurbo.asrModelID,
            supportDirectory: supportDirectory
        )
        let microphone: [Int16] = [100, -200, 300, -400]
        let system: [Int16] = [500, -600, 700]

        capture.appendMicrophone(microphone)
        capture.appendSystem(system)
        let staged = try capture.finalize(endedAt: startedAt.addingTimeInterval(1))

        #expect(staged.manifest.state == .captureComplete)
        #expect(staged.manifest.microphoneSampleCount == microphone.count)
        #expect(staged.manifest.systemSampleCount == system.count)
        #expect(staged.manifest.finalModelID == BackendOption.whisperLargeTurbo.asrModelID)
        #expect(try WavReader.readFloatMonoWAV(from: staged.microphoneURL).samples.count == microphone.count)
        #expect(try WavReader.readFloatMonoWAV(from: staged.systemURL).samples.count == system.count)
    }

    @Test("recovery repairs interrupted WAV headers from append-only file length")
    func recoveryRepairsInterruptedHeaders() throws {
        let supportDirectory = temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var capture: MeetingProcessingCapture? = try MeetingProcessingCapture(
            meetingID: 7,
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 2_000),
            finalModelID: BackendOption.parakeetMultilingual.asrModelID,
            supportDirectory: supportDirectory
        )
        let directoryURL = try #require(capture?.directoryURL)
        capture?.appendMicrophone([1, 2, 3, 4, 5])
        capture?.appendSystem([6, 7, 8])
        capture = nil

        let recovered = try MeetingProcessingCapture.recover(
            directoryURL: directoryURL,
            supportDirectory: supportDirectory,
            endedAt: Date(timeIntervalSince1970: 2_005)
        )

        #expect(recovered.manifest.state == .captureComplete)
        #expect(recovered.manifest.microphoneSampleCount == 5)
        #expect(recovered.manifest.systemSampleCount == 3)
        #expect(try WavReader.readFloatMonoWAV(from: recovered.microphoneURL).samples.count == 5)
        #expect(try WavReader.readFloatMonoWAV(from: recovered.systemURL).samples.count == 3)
    }

    @Test("recovery rejects paths outside the processing root")
    func recoveryRejectsExternalPath() throws {
        let supportDirectory = temporarySupportDirectory()
        let externalDirectory = temporarySupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
            try? FileManager.default.removeItem(at: externalDirectory)
        }

        #expect(throws: MeetingProcessingCaptureError.self) {
            try MeetingProcessingCapture.recover(
                directoryURL: externalDirectory,
                supportDirectory: supportDirectory
            )
        }
    }

    @Test("canonical capture stores only prepared mic and compacts inactive gaps")
    func preparedMicAndCompactedTimeline() throws {
        let supportDirectory = temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let capture = try MeetingProcessingCapture(
            meetingID: 99,
            startedAt: Date(timeIntervalSince1970: 4_000),
            finalModelID: BackendOption.parakeetMultilingual.asrModelID,
            supportDirectory: supportDirectory
        )
        let rawMicThatMustNotBeStored: [Int16] = [30_000, 30_000, 30_000]
        let preparedBeforePause: [Int16] = [100, 200]
        let preparedAfterPause: [Int16] = [300, 400]
        _ = rawMicThatMustNotBeStored

        capture.appendMicrophone(preparedBeforePause)
        // A pause or any number of Live/model transitions performs no capture
        // append. The next accepted samples follow immediately on the compacted
        // canonical timeline.
        for _ in 0..<10 {}
        capture.appendMicrophone(preparedAfterPause)
        capture.appendSystem([500])
        let staged = try capture.finalize(endedAt: Date(timeIntervalSince1970: 4_010))
        let stored = try readPCM16(staged.microphoneURL)

        #expect(stored == preparedBeforePause + preparedAfterPause)
        #expect(!stored.contains(30_000))
        #expect(staged.manifest.timelinePolicy == .activeCaptureCompacted)
        #expect(staged.manifest.preprocessing == .current)
        #expect(staged.manifest.sampleFormat == "signed_int16")
        #expect(staged.manifest.microphoneSampleCount == 4)
        #expect(staged.manifest.systemSampleCount == 1)
    }

    @Test("discovery preserves model language and retry state")
    func discoveryAndRetryState() throws {
        let supportDirectory = temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let capture = try MeetingProcessingCapture(
            meetingID: 88,
            startedAt: Date(timeIntervalSince1970: 3_000),
            finalModelID: BackendOption.cohereTranscribe.asrModelID,
            cohereLanguage: .polish,
            indicASRLanguage: .tamil,
            nemotron35Language: .russian,
            supportDirectory: supportDirectory
        )
        capture.appendMicrophone([1, 2, 3])
        let finalized = try capture.finalize(endedAt: Date(timeIntervalSince1970: 3_001))

        let processing = try MeetingProcessingCapture.markProcessing(finalized)
        #expect(processing.manifest.attemptCount == 1)
        #expect(processing.manifest.cohereLanguage == CohereTranscribeLanguage.polish.rawValue)
        #expect(processing.manifest.indicASRLanguage == IndicASRLanguage.tamil.rawValue)
        #expect(processing.manifest.nemotron35Language == Nemotron35Language.russian.rawValue)
        let failed = try MeetingProcessingCapture.markFailed(
            processing,
            error: CocoaError(.fileReadCorruptFile)
        )
        #expect(failed.manifest.state == .failed)
        #expect(failed.manifest.lastError?.isEmpty == false)

        let discovered = MeetingProcessingCapture.recoverableSessions(
            meetingID: 88,
            supportDirectory: supportDirectory
        )
        #expect(discovered.count == 1)
        #expect(discovered.first?.manifest.sessionID == failed.manifest.sessionID)
        #expect(MeetingProcessingCapture.hasRecoverableSession(
            meetingID: 88,
            supportDirectory: supportDirectory
        ))

        try MeetingProcessingCapture.discardAll(
            meetingID: 88,
            supportDirectory: supportDirectory
        )
        #expect(!MeetingProcessingCapture.hasRecoverableSession(
            meetingID: 88,
            supportDirectory: supportDirectory
        ))
    }

    private func temporarySupportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-processing-capture-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func readPCM16(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        return data[44...].withUnsafeBytes {
            $0.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) }
        }
    }
}
