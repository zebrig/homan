import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting chunked Live queue")
struct MeetingChunkedLiveQueueTests {
    @Test("chunked results map to source-stable provisional turns")
    func sourceAwareProvisionalTurns() {
        let segments = [
            SpeechSegment(start: 1, end: 2, text: "first"),
            SpeechSegment(start: 1, end: 3, text: "second"),
        ]
        let sessionID = UUID()

        let local = MeetingChunkedLiveQueue.attributedTurns(
            from: segments,
            source: .microphone,
            sessionID: sessionID
        )
        let remote = MeetingChunkedLiveQueue.attributedTurns(
            from: segments,
            source: .system,
            sessionID: sessionID
        )

        #expect(local.map(\.sourceRole) == [.you, .you])
        #expect(remote.map(\.sourceRole) == [.others, .others])
        #expect(local.allSatisfy { $0.isProvisional })
        #expect(remote.allSatisfy { $0.isProvisional })
        #expect(local.map(\.text) == ["first", "second"])
        #expect(remote.map(\.text) == ["first", "second"])
        #expect(local.allSatisfy { $0.recordingSessionID == sessionID })
    }

    @Test("keeps at most two queued chunks and drops the oldest preview work")
    func boundsPendingPreviewWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-live-queue-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("\(index).wav")
            try Data([UInt8(index)]).write(to: url)
            return url
        }
        let transcriber = ControlledLiveTranscriber()
        let callbacks = LiveQueueCallbackCollector()
        let queue = MeetingChunkedLiveQueue(
            source: .microphone,
            generation: 17,
            transcribe: { url in
                await transcriber.transcribe(url)
            },
            onSegments: { segments, source, generation in
                callbacks.recordSegments(segments, source: source, generation: generation)
            },
            onLagChanged: { lagging, dropped, generation in
                callbacks.recordLag(lagging, dropped: dropped, generation: generation)
            },
            onFailure: { message, generation in
                callbacks.recordFailure(message, generation: generation)
            }
        )

        await queue.enqueue(.init(url: urls[0], start: 0, end: 1))
        #expect(await waitUntil { await transcriber.callCount == 1 })
        for index in 1..<5 {
            await queue.enqueue(.init(
                url: urls[index],
                start: Double(index),
                end: Double(index + 1)
            ))
        }

        let saturated = await queue.debugSnapshot()
        #expect(saturated.pendingCount == MeetingChunkedLiveQueue.maximumQueuedChunks)
        #expect(saturated.droppedCount == 2)
        #expect(saturated.isLagging)
        #expect(!FileManager.default.fileExists(atPath: urls[1].path))
        #expect(!FileManager.default.fileExists(atPath: urls[2].path))
        let lag = try #require(callbacks.latestLag)
        #expect(lag.0)
        #expect(lag.1 == 2)
        #expect(lag.2 == 17)

        await transcriber.releaseAll()
        #expect(await waitUntil {
            let snapshot = await queue.debugSnapshot()
            let callCount = await transcriber.callCount
            return snapshot.pendingCount == 0 && callCount == 3
        })
        await queue.stop()

        #expect(callbacks.segmentGenerations.allSatisfy { $0 == 17 })
        #expect(callbacks.sources.allSatisfy { $0 == .microphone })
        #expect(callbacks.failures.isEmpty)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private actor ControlledLiveTranscriber {
    private(set) var callCount = 0
    private var shouldBlock = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func transcribe(_ url: URL) async -> SpeechTranscriptionResult {
        callCount += 1
        if shouldBlock {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        let text = url.deletingPathExtension().lastPathComponent
        return SpeechTranscriptionResult(
            text: text,
            segments: [SpeechSegment(start: 0, end: 1, text: text)]
        )
    }

    func releaseAll() {
        shouldBlock = false
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class LiveQueueCallbackCollector: @unchecked Sendable {
    private struct State {
        var latestLag: (Bool, Int, UInt64)?
        var segmentGenerations: [UInt64] = []
        var sources: [MeetingLiveAudioSource] = []
        var failures: [(String, UInt64)] = []
    }

    private let lock = NSLock()
    private var state = State()

    var latestLag: (Bool, Int, UInt64)? {
        lock.withLock { state.latestLag }
    }

    var segmentGenerations: [UInt64] {
        lock.withLock { state.segmentGenerations }
    }

    var sources: [MeetingLiveAudioSource] {
        lock.withLock { state.sources }
    }

    var failures: [(String, UInt64)] {
        lock.withLock { state.failures }
    }

    func recordSegments(
        _ segments: [SpeechSegment],
        source: MeetingLiveAudioSource,
        generation: UInt64
    ) {
        guard !segments.isEmpty else { return }
        lock.withLock {
            state.segmentGenerations.append(generation)
            state.sources.append(source)
        }
    }

    func recordLag(_ lagging: Bool, dropped: Int, generation: UInt64) {
        lock.withLock {
            state.latestLag = (lagging, dropped, generation)
        }
    }

    func recordFailure(_ message: String, generation: UInt64) {
        lock.withLock {
            state.failures.append((message, generation))
        }
    }
}
