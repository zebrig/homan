import Foundation

enum MeetingLiveAudioSource: String, Sendable {
    case microphone
    case system

    var speakerLabel: String {
        switch self {
        case .microphone: return "You"
        case .system: return "Others"
        }
    }

    var audioSourceRole: MeetingAudioSourceRole {
        switch self {
        case .microphone: return .microphone
        case .system: return .system
        }
    }

    var transcriptRole: MeetingTranscriptRole {
        switch self {
        case .microphone: return .you
        case .system: return .others
        }
    }
}

actor MeetingChunkedLiveQueue {
    static let maximumQueuedChunks = 2

    struct Work: Sendable {
        let url: URL
        let start: TimeInterval
        let end: TimeInterval
    }

    private let source: MeetingLiveAudioSource
    private let generation: UInt64
    private let transcribe: @Sendable (URL) async throws -> SpeechTranscriptionResult
    private let onSegments: @Sendable ([SpeechSegment], MeetingLiveAudioSource, UInt64) -> Void
    private let onLagChanged: @Sendable (Bool, Int, UInt64) -> Void
    private let onFailure: @Sendable (String, UInt64) -> Void

    private var pending: [Work] = []
    private var worker: Task<Void, Never>?
    private var isStopped = false
    private var isSuspended = false
    private var droppedCount = 0
    private var completionsBelowLimit = 0
    private var isLagging = false

    nonisolated static func attributedTurns(
        from segments: [SpeechSegment],
        source: MeetingLiveAudioSource,
        sessionID: UUID?
    ) -> [AttributedTurn] {
        segments.map {
            AttributedTurn(
                sourceRole: source.transcriptRole,
                remoteSpeaker: nil,
                startSeconds: $0.start,
                endSeconds: $0.end,
                text: $0.text,
                isProvisional: true,
                recordingSessionID: sessionID
            )
        }
    }

    init(
        source: MeetingLiveAudioSource,
        generation: UInt64,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage,
        coordinator: TranscriptionCoordinator,
        onSegments: @escaping @Sendable ([SpeechSegment], MeetingLiveAudioSource, UInt64) -> Void,
        onLagChanged: @escaping @Sendable (Bool, Int, UInt64) -> Void,
        onFailure: @escaping @Sendable (String, UInt64) -> Void
    ) {
        self.source = source
        self.generation = generation
        self.transcribe = { url in
            try await coordinator.transcribeMeetingChunk(
                at: url,
                backend: backend,
                cohereLanguage: cohereLanguage,
                indicASRLanguage: indicASRLanguage
            )
        }
        self.onSegments = onSegments
        self.onLagChanged = onLagChanged
        self.onFailure = onFailure
    }

    init(
        source: MeetingLiveAudioSource,
        generation: UInt64,
        transcribe: @escaping @Sendable (URL) async throws -> SpeechTranscriptionResult,
        onSegments: @escaping @Sendable ([SpeechSegment], MeetingLiveAudioSource, UInt64) -> Void,
        onLagChanged: @escaping @Sendable (Bool, Int, UInt64) -> Void,
        onFailure: @escaping @Sendable (String, UInt64) -> Void
    ) {
        self.source = source
        self.generation = generation
        self.transcribe = transcribe
        self.onSegments = onSegments
        self.onLagChanged = onLagChanged
        self.onFailure = onFailure
    }

    func enqueue(_ work: Work) {
        guard !isStopped, !isSuspended else {
            try? FileManager.default.removeItem(at: work.url)
            return
        }
        pending.append(work)
        if pending.count > Self.maximumQueuedChunks {
            let dropped = pending.removeFirst()
            try? FileManager.default.removeItem(at: dropped.url)
            droppedCount += 1
            completionsBelowLimit = 0
            if !isLagging {
                isLagging = true
            }
            onLagChanged(true, droppedCount, generation)
        }
        if worker == nil {
            worker = Task { [weak self] in
                await self?.drain()
            }
        }
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        let queued = pending
        pending.removeAll()
        queued.forEach { try? FileManager.default.removeItem(at: $0.url) }
        let runningWorker = worker
        worker = nil
        runningWorker?.cancel()
        _ = await runningWorker?.value
    }

    func suspend() {
        guard !isStopped else { return }
        isSuspended = true
        let queued = pending
        pending.removeAll()
        queued.forEach { try? FileManager.default.removeItem(at: $0.url) }
    }

    func resume() {
        guard !isStopped else { return }
        isSuspended = false
    }

    private func drain() async {
        defer { worker = nil }
        while !isStopped, !Task.isCancelled, !pending.isEmpty {
            let work = pending.removeFirst()
            defer { try? FileManager.default.removeItem(at: work.url) }
            do {
                let result = try await transcribe(work.url)
                guard !isStopped, !isSuspended, !Task.isCancelled else {
                    if isSuspended {
                        continue
                    }
                    return
                }
                let segments: [SpeechSegment]
                switch source {
                case .microphone:
                    segments = MicTurnNormalizer.normalize(
                        result: result,
                        startTime: work.start,
                        endTime: work.end
                    )
                case .system:
                    segments = SystemTurnNormalizer.normalize(
                        result: result,
                        startTime: work.start,
                        endTime: work.end
                    )
                }
                if !segments.isEmpty {
                    onSegments(segments, source, generation)
                }
                noteCompletion()
            } catch is CancellationError {
                return
            } catch {
                guard !isStopped else { return }
                onFailure(error.localizedDescription, generation)
                isStopped = true
                let queued = pending
                pending.removeAll()
                queued.forEach { try? FileManager.default.removeItem(at: $0.url) }
                worker = nil
                return
            }
        }
    }

    private func noteCompletion() {
        guard isLagging else { return }
        if pending.count < Self.maximumQueuedChunks {
            completionsBelowLimit += 1
        } else {
            completionsBelowLimit = 0
        }
        if completionsBelowLimit >= 2 {
            isLagging = false
            completionsBelowLimit = 0
            onLagChanged(false, droppedCount, generation)
        }
    }

    func debugSnapshot() -> (
        pendingCount: Int,
        droppedCount: Int,
        isLagging: Bool,
        isStopped: Bool
    ) {
        (pending.count, droppedCount, isLagging, isStopped)
    }
}
