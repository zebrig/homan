import FluidAudio
import Foundation
import MuesliCore

protocol MeetingTranscriptionProviding: Sendable {
    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult

    func meetingSpeechSegments(at url: URL) async throws -> [VadSegment]?

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]?

    func meetingDiarizationSegments(
        at url: URL,
        profileID: MeetingDiarizationProfileID
    ) async throws -> [TimedSpeakerSegment]?

    func meetingDiarizationTimeline(
        _ timeline: MeetingSystemTimelineInput,
        profileID: MeetingDiarizationProfileID,
        progress: @escaping @Sendable (MeetingDiarizationProgress) -> Void
    ) async throws -> MeetingDiarizationTimelineResult?
}

extension MeetingTranscriptionProviding {
    func meetingSpeechSegments(at url: URL) async throws -> [VadSegment]? {
        nil
    }

    func meetingDiarizationSegments(
        at url: URL,
        profileID: MeetingDiarizationProfileID
    ) async throws -> [TimedSpeakerSegment]? {
        try await meetingDiarizationSegments(at: url)
    }

    func meetingDiarizationTimeline(
        _ timeline: MeetingSystemTimelineInput,
        profileID: MeetingDiarizationProfileID,
        progress: @escaping @Sendable (MeetingDiarizationProgress) -> Void
    ) async throws -> MeetingDiarizationTimelineResult? {
        guard let segments = try await meetingDiarizationSegments(
            at: timeline.url,
            profileID: profileID
        ) else { return nil }
        progress(.init(completedUnits: 1, totalUnits: 1))
        let definition = MeetingDiarizationProfiles.resolve(profileID)
        return MeetingDiarizationTimelineResult(
            descriptor: DiarizationEngineDescriptor(
                engineID: definition.engineID.rawValue,
                engineVersion: definition.engineVersion,
                supportsOverlap: true,
                maximumSpeakers: definition.maximumSpeakers
            ),
            profile: definition.snapshot(
                modelDigest: "test-or-legacy-provider:\(definition.modelRevision)"
            ),
            activitySegments: segments.map {
                MeetingDiarizationActivitySegment(
                    speakerKey: $0.speakerId,
                    startSeconds: TimeInterval($0.startTimeSeconds),
                    endSeconds: TimeInterval($0.endTimeSeconds),
                    confidence: $0.qualityScore
                )
            },
            timings: .init(),
            warnings: []
        )
    }
}

extension TranscriptionCoordinator: MeetingTranscriptionProviding {
    func meetingSpeechSegments(at url: URL) async throws -> [VadSegment]? {
        guard let vadManager = getVadManager() else { return nil }
        let samples = try AudioConverter().resampleAudioFile(url)
        return try await vadManager.segmentSpeech(
            samples,
            config: VadSegmentationConfig(
                minSpeechDuration: 0.15,
                minSilenceDuration: 0.55,
                maxSpeechDuration: 30,
                speechPadding: 0.15
            )
        )
    }

    func meetingDiarizationSegments(
        at url: URL,
        profileID: MeetingDiarizationProfileID
    ) async throws -> [TimedSpeakerSegment]? {
        try await diarizeSystemAudio(at: url, profileID: profileID)?.segments
    }

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]? {
        try await meetingDiarizationSegments(at: url, profileID: .automatic)
    }

    func meetingDiarizationTimeline(
        _ timeline: MeetingSystemTimelineInput,
        profileID: MeetingDiarizationProfileID,
        progress: @escaping @Sendable (MeetingDiarizationProgress) -> Void
    ) async throws -> MeetingDiarizationTimelineResult? {
        try await diarizeSystemTimeline(
            timeline,
            profileID: profileID,
            progress: progress
        )
    }
}

struct MeetingTranscriptionPipeline: Sendable {
    private struct CanonicalSourceUnit: Sendable {
        let unitID: String
        let sessionID: UUID?
        let startedAt: Date
        let microphoneURL: URL?
        let systemURL: URL?
        let microphoneSampleCount: Int
        let systemSampleCount: Int
        let degradations: [MeetingProcessingDegradation]
        let leaseKey: MeetingRecordingLeaseKey?
        let aecDiagnostics: MeetingAecDiagnosticsSnapshot?

        init(
            unitID: String,
            sessionID: UUID?,
            startedAt: Date,
            microphoneURL: URL?,
            systemURL: URL?,
            microphoneSampleCount: Int,
            systemSampleCount: Int,
            degradations: [MeetingProcessingDegradation],
            leaseKey: MeetingRecordingLeaseKey?,
            aecDiagnostics: MeetingAecDiagnosticsSnapshot? = nil
        ) {
            self.unitID = unitID
            self.sessionID = sessionID
            self.startedAt = startedAt
            self.microphoneURL = microphoneURL
            self.systemURL = systemURL
            self.microphoneSampleCount = microphoneSampleCount
            self.systemSampleCount = systemSampleCount
            self.degradations = degradations
            self.leaseKey = leaseKey
            self.aecDiagnostics = aecDiagnostics
        }
    }

    private enum RecognitionOutcome: Sendable {
        case success([SpeechSegment])
        case failure
        case unavailable
        case cancelled
    }

    private struct PreparedRemoteBatch: Sendable {
        let items: [RemoteMeetingSpeechItem]
        let requestID: UUID
        let responseCacheURL: URL?
        let removesItemsAfterUse: Bool

        func removeTemporaryFiles() {
            guard removesItemsAfterUse else { return }
            for item in items {
                try? FileManager.default.removeItem(at: item.audioURL)
            }
        }
    }

    private struct PreparedMeetingRemoteBatch: Sendable {
        let batch: PreparedRemoteBatch
        let unitIDByItemID: [String: String]
        let timeOffsetByItemID: [String: TimeInterval]
    }

    private struct HomanBatchSource: Sendable {
        let unitID: String
        let source: MeetingAudioSourceRole
        let url: URL?
        let sampleCount: Int
        let meetingTimeOffset: TimeInterval
    }

    private final class OwnedCanonicalUnit: @unchecked Sendable {
        let unit: CanonicalSourceUnit
        private let temporaryURLs: [URL]
        private let lease: MeetingRecordingLease?
        private var cleaned = false

        init(
            unit: CanonicalSourceUnit,
            temporaryURLs: [URL] = [],
            lease: MeetingRecordingLease? = nil
        ) {
            self.unit = unit
            self.temporaryURLs = temporaryURLs
            self.lease = lease
        }

        func cleanup() {
            guard !cleaned else { return }
            cleaned = true
            temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            lease?.release()
        }

        deinit { cleanup() }
    }

    private enum PreparedGenericUnit: Sendable {
        case canonical(OwnedCanonicalUnit)
        case legacy(MeetingLegacyRecordingInput, MeetingRecordingLease)

        func cleanup() {
            switch self {
            case .canonical(let owned): owned.cleanup()
            case .legacy(_, let lease): lease.release()
            }
        }
    }

    private let provider: any MeetingTranscriptionProviding
    private let leaseRegistry: MeetingRecordingLeaseRegistry
    private let inferenceScheduler: MeetingInferenceScheduler
    private let aecFactory: @Sendable (MeetingAecModel) -> MeetingNeuralAec
    private let cancellationCheck: @Sendable () throws -> Void

    init(
        provider: any MeetingTranscriptionProviding,
        leaseRegistry: MeetingRecordingLeaseRegistry = .shared,
        inferenceScheduler: MeetingInferenceScheduler = .shared,
        aecFactory: @escaping @Sendable (MeetingAecModel) -> MeetingNeuralAec = {
            MeetingNeuralAec(localVQEModel: $0)
        },
        cancellationCheck: @escaping @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
    ) {
        self.provider = provider
        self.leaseRegistry = leaseRegistry
        self.inferenceScheduler = inferenceScheduler
        self.aecFactory = aecFactory
        self.cancellationCheck = cancellationCheck
    }

    init(
        coordinator: TranscriptionCoordinator,
        leaseRegistry: MeetingRecordingLeaseRegistry = .shared,
        inferenceScheduler: MeetingInferenceScheduler = .shared,
        aecFactory: @escaping @Sendable (MeetingAecModel) -> MeetingNeuralAec = {
            MeetingNeuralAec(localVQEModel: $0)
        },
        cancellationCheck: @escaping @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
    ) {
        self.init(
            provider: coordinator,
            leaseRegistry: leaseRegistry,
            inferenceScheduler: inferenceScheduler,
            aecFactory: aecFactory,
            cancellationCheck: cancellationCheck
        )
    }

    func process(_ request: MeetingTranscriptionRequest) async throws -> MeetingTranscriptionResult {
        guard !request.units.isEmpty else {
            throw MeetingTranscriptionPipelineError.noRecordingUnits
        }
        request.progress(.processingAudio)

        if request.backend.backend == BackendOption.homanWhisper.backend,
           request.units.allSatisfy({ input in
               if case .legacyMixed = input { return false }
               return true
           }) {
            let unitResults = try await processHomanWhisperMeeting(request)
            return try await applyMeetingWideDiarizationIfNeeded(
                to: unitResults,
                request: request,
                renderTimeline: {
                    try MeetingSystemTimelineRenderer.render(
                        units: request.units,
                        meetingStart: request.units.map(\.createdAt).min() ?? Date(),
                        leaseRegistry: leaseRegistry
                    )
                }
            )
        }

        var preparedUnits: [PreparedGenericUnit] = []
        defer { preparedUnits.forEach { $0.cleanup() } }
        for input in request.units.sorted(by: Self.unitComesBefore) {
            try cancellationCheck()
            switch input {
            case .sourceBundle, .separatedChannels:
                preparedUnits.append(.canonical(
                    try await prepareOwnedCanonicalUnit(
                        input,
                        aecModel: request.aecModel
                    )
                ))
            case .legacyMixed(let legacyInput):
                guard MeetingRecordingUnitInput
                    .legacyMixed(legacyInput)
                    .hasUsableAudio(onDisk: .default),
                      let lease = leaseRegistry.acquireRead(
                          for: .recordingID(legacyInput.recording.id)
                      ) else {
                    throw MeetingTranscriptionPipelineError.noUsableAudio
                }
                preparedUnits.append(.legacy(legacyInput, lease))
            }
            try cancellationCheck()
        }
        request.progress(.transcribing)
        var unitResults: [MeetingUnitTranscriptionResult] = []
        for prepared in preparedUnits {
            switch prepared {
            case .canonical(let owned):
                unitResults.append(try await processCanonical(owned.unit, request: request))
            case .legacy(let input, _):
                unitResults.append(try await processLegacy(input, request: request))
            }
        }
        preparedUnits.forEach { $0.cleanup() }
        return try await applyMeetingWideDiarizationIfNeeded(
            to: unitResults,
            request: request,
            renderTimeline: {
                try MeetingSystemTimelineRenderer.render(
                    units: request.units,
                    meetingStart: request.units.map(\.createdAt).min() ?? Date(),
                    leaseRegistry: leaseRegistry
                )
            }
        )
    }

    func process(
        stagedAudio: MeetingStagedAudio,
        backend: BackendOption,
        languages: MeetingLanguageSnapshot,
        purpose: MeetingProcessingPurpose,
        systemDiarization: SystemDiarizationPolicy,
        diarizationProfileID: MeetingDiarizationProfileID = .automatic,
        progress: @escaping @Sendable (MeetingTranscriptionPipelineStage) -> Void = { _ in }
    ) async throws -> MeetingTranscriptionResult {
        let manifest = stagedAudio.manifest
        let unit = CanonicalSourceUnit(
            unitID: manifest.sessionID.uuidString.lowercased(),
            sessionID: manifest.sessionID,
            startedAt: manifest.startedAt,
            microphoneURL: manifest.microphoneSampleCount > 0 ? stagedAudio.microphoneURL : nil,
            systemURL: manifest.systemSampleCount > 0 ? stagedAudio.systemURL : nil,
            microphoneSampleCount: manifest.microphoneSampleCount,
            systemSampleCount: manifest.systemSampleCount,
            degradations: [
                manifest.microphoneSampleCount == 0 ? .sourceEmpty(.microphone) : nil,
                manifest.systemSampleCount == 0 ? .sourceEmpty(.system) : nil,
            ].compactMap { $0 },
            leaseKey: .sessionID(manifest.sessionID)
        )
        let request = MeetingTranscriptionRequest(
            units: [],
            backend: backend,
            languages: languages,
            purpose: purpose,
            systemDiarization: systemDiarization,
            diarizationProfileID: diarizationProfileID,
            persistentRemoteBatchAudio: stagedAudio,
            progress: progress
        )
        request.progress(.transcribing)
        let unitResult = try await processCanonical(unit, request: request)
        return try await applyMeetingWideDiarizationIfNeeded(
            to: [unitResult],
            request: request,
            renderTimeline: {
                guard manifest.systemSampleCount > 0 else {
                    throw MeetingSystemTimelineError.noSystemAudio
                }
                return try MeetingSystemTimelineRenderer.render(
                    sources: [MeetingSystemTimelineAudioSource(
                        unitID: unit.unitID,
                        startedAt: manifest.startedAt,
                        url: stagedAudio.systemURL,
                        sourceFingerprint: "staged-v1|\(try MeetingSystemTimelineRenderer.fingerprintFile(at: stagedAudio.systemURL))"
                    )],
                    meetingStart: manifest.startedAt
                )
            }
        )
    }

    private func processHomanWhisperMeeting(
        _ request: MeetingTranscriptionRequest
    ) async throws -> [MeetingUnitTranscriptionResult] {
        var ownedUnits: [OwnedCanonicalUnit] = []
        do {
            for input in request.units.sorted(by: Self.unitComesBefore) {
                try cancellationCheck()
                ownedUnits.append(try await prepareOwnedCanonicalUnit(
                    input,
                    aecModel: request.aecModel
                ))
                try cancellationCheck()
            }
            request.progress(.transcribing)
            let meetingStart = ownedUnits.map(\.unit.startedAt).min() ?? Date()
            let sources = ownedUnits.flatMap { owned -> [HomanBatchSource] in
                let unit = owned.unit
                let timeOffset = max(0, unit.startedAt.timeIntervalSince(meetingStart))
                return [
                    HomanBatchSource(
                        unitID: unit.unitID,
                        source: .microphone,
                        url: unit.microphoneURL,
                        sampleCount: unit.microphoneSampleCount,
                        meetingTimeOffset: timeOffset
                    ),
                    HomanBatchSource(
                        unitID: unit.unitID,
                        source: .system,
                        url: unit.systemURL,
                        sampleCount: unit.systemSampleCount,
                        meetingTimeOffset: timeOffset
                    ),
                ]
            }
            let prepared = try await prepareHomanWhisperBatch(sources: sources)
            defer { prepared.batch.removeTemporaryFiles() }
            guard let batchProvider = provider as? any MeetingBatchTranscriptionProviding else {
                throw HomanWhisperError.invalidResponse("batch provider unavailable")
            }
            let remote = try await batchProvider.transcribeMeetingBatch(
                items: prepared.batch.items,
                requestID: prepared.batch.requestID,
                responseCacheURL: prepared.batch.responseCacheURL
            )
            let itemIDs = Set(remote.map(\.id))
            guard itemIDs.count == remote.count else {
                throw HomanWhisperError.invalidResponse("duplicate response item id")
            }
            let grouped = Dictionary(grouping: remote) { result in
                prepared.unitIDByItemID[result.id] ?? ""
            }
            guard !grouped.keys.contains("") else {
                throw HomanWhisperError.invalidResponse("unknown response item id")
            }
            return try ownedUnits.map { owned in
                let localResults = (grouped[owned.unit.unitID] ?? []).map { item in
                    Self.rebasedRemoteResult(
                        item,
                        subtracting: prepared.timeOffsetByItemID[item.id] ?? 0
                    )
                }
                let recognized = Self.sourceSegments(
                    from: localResults
                )
                return try makeCanonicalResult(
                    unit: owned.unit,
                    recognizedSegments: recognized,
                    degradations: owned.unit.degradations
                )
            }
        } catch {
            ownedUnits.forEach { $0.cleanup() }
            throw error
        }
    }

    private func prepareHomanWhisperBatch(
        sources: [HomanBatchSource]
    ) async throws -> PreparedMeetingRemoteBatch {
        var allItems: [RemoteMeetingSpeechItem] = []
        var unitIDByItemID: [String: String] = [:]
        var timeOffsetByItemID: [String: TimeInterval] = [:]
        do {
            for (sourceIndex, source) in sources.enumerated() {
                guard source.sampleCount > 0, let url = source.url else { continue }
                guard let speechSegments = try await provider.meetingSpeechSegments(at: url) else {
                    throw HomanWhisperError.vadUnavailable
                }
                let samples = try AudioConverter().resampleAudioFile(url)
                for (segmentIndex, segment) in speechSegments
                    .sorted(by: { $0.startTime < $1.startTime })
                    .enumerated() {
                    try Task.checkCancellation()
                    let startSample = max(
                        0,
                        min(samples.count, segment.startSample(sampleRate: VadManager.sampleRate))
                    )
                    let endSample = max(
                        startSample,
                        min(samples.count, segment.endSample(sampleRate: VadManager.sampleRate))
                    )
                    guard endSample > startSample else { continue }
                    let id = String(
                        format: "u%04d-%@-%04d",
                        sourceIndex / 2,
                        source.source.rawValue,
                        segmentIndex
                    )
                    let audioURL = try await encodeRemoteSpeechItem(
                        samples: Array(samples[startSample..<endSample])
                    )
                    let localStart = Double(startSample) / Double(VadManager.sampleRate)
                    let localEnd = Double(endSample) / Double(VadManager.sampleRate)
                    allItems.append(RemoteMeetingSpeechItem(
                        id: id,
                        source: source.source,
                        start: source.meetingTimeOffset + localStart,
                        end: source.meetingTimeOffset + localEnd,
                        audioURL: audioURL
                    ))
                    unitIDByItemID[id] = source.unitID
                    timeOffsetByItemID[id] = source.meetingTimeOffset
                }
            }
            guard !allItems.isEmpty else { throw HomanWhisperError.noSpeechItems }
            guard allItems.count <= 2048 else {
                throw HomanWhisperError.tooManyItems(allItems.count)
            }
            return PreparedMeetingRemoteBatch(
                batch: PreparedRemoteBatch(
                    items: allItems,
                    requestID: UUID(),
                    responseCacheURL: nil,
                    removesItemsAfterUse: true
                ),
                unitIDByItemID: unitIDByItemID,
                timeOffsetByItemID: timeOffsetByItemID
            )
        } catch {
            allItems.forEach { try? FileManager.default.removeItem(at: $0.audioURL) }
            throw error
        }
    }

    private func prepareOwnedCanonicalUnit(
        _ input: MeetingRecordingUnitInput,
        aecModel: MeetingAecModel
    ) async throws -> OwnedCanonicalUnit {
        switch input {
        case .sourceBundle(let sourceInput):
            let bundle = sourceInput.bundle
            let recordingID = sourceInput.recording?.id ?? bundle.manifest.recordingID
            let leaseKey = recordingID.map(MeetingRecordingLeaseKey.recordingID)
                ?? .sessionID(bundle.manifest.sessionID)
            guard let lease = leaseRegistry.acquireRead(for: leaseKey) else {
                throw MeetingTranscriptionPipelineError.noUsableAudio
            }
            do {
                if let rawAudio = bundle.rawAudio {
                    let prepared = try await MeetingRawAudioPostProcessor.renderProcessingView(
                        rawAudio,
                        aec: aecFactory(aecModel),
                        inferenceScheduler: inferenceScheduler
                    )
                    let urls = [prepared.microphoneURL, prepared.systemURL].compactMap { $0 }
                    return OwnedCanonicalUnit(
                        unit: CanonicalSourceUnit(
                            unitID: bundle.manifest.sessionID.uuidString.lowercased(),
                            sessionID: bundle.manifest.sessionID,
                            startedAt: bundle.manifest.startedAt,
                            microphoneURL: prepared.microphoneURL,
                            systemURL: prepared.systemURL,
                            microphoneSampleCount: prepared.microphoneSampleCount,
                            systemSampleCount: prepared.systemSampleCount,
                            degradations: bundle.degradations,
                            leaseKey: nil,
                            aecDiagnostics: prepared.aecDiagnostics
                        ),
                        temporaryURLs: urls,
                        lease: lease
                    )
                }
                return OwnedCanonicalUnit(
                    unit: CanonicalSourceUnit(
                        unitID: bundle.manifest.sessionID.uuidString.lowercased(),
                        sessionID: bundle.manifest.sessionID,
                        startedAt: bundle.manifest.startedAt,
                        microphoneURL: bundle.microphoneURL,
                        systemURL: bundle.systemURL,
                        microphoneSampleCount: bundle.manifest.microphone.sampleCount,
                        systemSampleCount: bundle.manifest.system.sampleCount,
                        degradations: bundle.degradations,
                        leaseKey: nil
                    ),
                    lease: lease
                )
            } catch {
                lease.release()
                throw error
            }
        case .separatedChannels(let separated):
            guard MeetingRecordingUnitInput.separatedChannels(separated)
                .hasUsableAudio(onDisk: .default),
                  let lease = leaseRegistry.acquireRead(
                      for: .recordingID(separated.recording.id)
                  ) else {
                throw MeetingTranscriptionPipelineError.noUsableAudio
            }
            do {
                let extracted = try MeetingRecordingWriter.extractSeparatedChannels(
                    from: separated.recordingURL,
                    sourceLayout: separated.sourceLayout,
                    cancellationCheck: cancellationCheck
                )
                return OwnedCanonicalUnit(
                    unit: CanonicalSourceUnit(
                        unitID: "recording-\(separated.recording.id)",
                        sessionID: nil,
                        startedAt: separated.recording.createdAt,
                        microphoneURL: extracted.microphoneURL,
                        systemURL: extracted.systemURL,
                        microphoneSampleCount: extracted.microphoneSampleCount,
                        systemSampleCount: extracted.systemSampleCount,
                        degradations: [],
                        leaseKey: nil
                    ),
                    temporaryURLs: [
                        extracted.microphoneURL,
                        extracted.systemURL,
                    ].compactMap { $0 },
                    lease: lease
                )
            } catch {
                lease.release()
                throw error
            }
        case .legacyMixed:
            throw MeetingTranscriptionPipelineError.noUsableAudio
        }
    }

    private func makeCanonicalResult(
        unit: CanonicalSourceUnit,
        recognizedSegments: [SourceRecognizedSegment],
        degradations: [MeetingProcessingDegradation]
    ) throws -> MeetingUnitTranscriptionResult {
        let microphoneSegments = Self.speechSegments(
            from: recognizedSegments,
            source: .microphone
        )
        let systemSegments = Self.speechSegments(
            from: recognizedSegments,
            source: .system
        )
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: microphoneSegments,
            systemSegments: systemSegments,
            diarizationSegments: nil
        )
        let turns = TranscriptFormatter.attributedTurns(
            micSegments: reconciled.micSegments,
            systemSegments: reconciled.systemSegments,
            diarizationSegments: nil,
            recordingSessionID: unit.sessionID,
            isProvisional: false
        )
        guard !turns.isEmpty else {
            let hasAvailableSource = unit.microphoneURL != nil || unit.systemURL != nil
            throw hasAvailableSource
                ? MeetingTranscriptionPipelineError.emptyTranscript
                : MeetingTranscriptionPipelineError.noUsableAudio
        }
        return MeetingUnitTranscriptionResult(
            unitID: unit.unitID,
            sessionID: unit.sessionID,
            startedAt: unit.startedAt,
            attributedTurns: turns,
            formattedTranscript: TranscriptFormatter.format(
                attributedTurns: turns,
                meetingStart: unit.startedAt
            ),
            degradations: Self.uniqued(degradations),
            recognizedSegments: recognizedSegments,
            microphoneSegments: reconciled.micSegments,
            systemSegments: reconciled.systemSegments,
            diarizationSegments: nil,
            aecDiagnostics: unit.aecDiagnostics
        )
    }

    private func processCanonical(
        _ unit: CanonicalSourceUnit,
        request: MeetingTranscriptionRequest
    ) async throws -> MeetingUnitTranscriptionResult {
        let lease = unit.leaseKey.flatMap { leaseRegistry.acquireRead(for: $0) }
        if unit.leaseKey != nil, lease == nil {
            throw MeetingTranscriptionPipelineError.noUsableAudio
        }
        defer { lease?.release() }

        var degradations = unit.degradations
        let microphoneSegments: [SpeechSegment]
        let systemSegments: [SpeechSegment]
        let recognizedSegments: [SourceRecognizedSegment]
        if request.backend.backend == BackendOption.homanWhisper.backend {
            let remote = try await recognizeHomanWhisperBatch(
                sources: [
                    (.microphone, unit.microphoneURL, unit.microphoneSampleCount),
                    (.system, unit.systemURL, unit.systemSampleCount),
                ],
                checkpointAudio: request.persistentRemoteBatchAudio
            )
            recognizedSegments = Self.sourceSegments(from: remote)
            microphoneSegments = Self.speechSegments(
                from: recognizedSegments,
                source: .microphone
            )
            systemSegments = Self.speechSegments(
                from: recognizedSegments,
                source: .system
            )
        } else {
            // Keep local Final ASR conservative and deterministic: one source
            // at a time, with capture-yield checkpoints inside each source.
            let microphone = await recognize(
                source: .microphone,
                url: unit.microphoneURL,
                sampleCount: unit.microphoneSampleCount,
                request: request
            )
            let system = await recognize(
                source: .system,
                url: unit.systemURL,
                sampleCount: unit.systemSampleCount,
                request: request
            )
            if case .cancelled = microphone { throw CancellationError() }
            if case .cancelled = system { throw CancellationError() }
            microphoneSegments = acceptedSegments(
                from: microphone,
                source: .microphone,
                degradations: &degradations
            )
            systemSegments = acceptedSegments(
                from: system,
                source: .system,
                degradations: &degradations
            )
            recognizedSegments = Self.sourceSegments(
                microphone: microphoneSegments,
                system: systemSegments
            )
        }

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: microphoneSegments,
            systemSegments: systemSegments,
            diarizationSegments: nil
        )
        let turns = TranscriptFormatter.attributedTurns(
            micSegments: reconciled.micSegments,
            systemSegments: reconciled.systemSegments,
            diarizationSegments: reconciled.diarizationSegments,
            recordingSessionID: unit.sessionID,
            isProvisional: false
        )
        guard !turns.isEmpty else {
            let hasAvailableSource = unit.microphoneURL != nil || unit.systemURL != nil
            throw hasAvailableSource
                ? MeetingTranscriptionPipelineError.emptyTranscript
                : MeetingTranscriptionPipelineError.noUsableAudio
        }
        return MeetingUnitTranscriptionResult(
            unitID: unit.unitID,
            sessionID: unit.sessionID,
            startedAt: unit.startedAt,
            attributedTurns: turns,
            formattedTranscript: TranscriptFormatter.format(
                attributedTurns: turns,
                meetingStart: unit.startedAt
            ),
            degradations: Self.uniqued(degradations),
            recognizedSegments: recognizedSegments,
            microphoneSegments: reconciled.micSegments,
            systemSegments: reconciled.systemSegments,
            diarizationSegments: nil,
            aecDiagnostics: unit.aecDiagnostics
        )
    }

    private func recognizeHomanWhisperBatch(
        sources: [(MeetingAudioSourceRole, URL?, Int)],
        checkpointAudio: MeetingStagedAudio? = nil
    ) async throws -> [RemoteMeetingSpeechResult] {
        guard let batchProvider = provider as? any MeetingBatchTranscriptionProviding else {
            throw HomanWhisperError.invalidResponse("batch provider unavailable")
        }
        let prepared = try await prepareHomanWhisperBatch(
            sources: sources,
            checkpointAudio: checkpointAudio
        )
        defer { prepared.removeTemporaryFiles() }
        return try await batchProvider.transcribeMeetingBatch(
            items: prepared.items,
            requestID: prepared.requestID,
            responseCacheURL: prepared.responseCacheURL
        )
    }

    private func prepareHomanWhisperBatch(
        sources: [(MeetingAudioSourceRole, URL?, Int)],
        checkpointAudio: MeetingStagedAudio?
    ) async throws -> PreparedRemoteBatch {
        if let checkpointAudio {
            do {
                let checkpoint = try HomanWhisperBatchCheckpoint.load(for: checkpointAudio)
                return PreparedRemoteBatch(
                    items: checkpoint.items,
                    requestID: checkpoint.requestID,
                    responseCacheURL: checkpoint.responseURL,
                    removesItemsAfterUse: false
                )
            } catch {
                // A partial or stale checkpoint is an internal cache miss. The
                // application repairs it automatically from preserved audio.
                HomanWhisperBatchCheckpoint.discard(for: checkpointAudio)
            }
        }

        var items: [RemoteMeetingSpeechItem] = []
        let checkpointBuilder = try checkpointAudio.map {
            try HomanWhisperBatchCheckpoint.begin(for: $0)
        }
        do {
            for (source, optionalURL, sampleCount) in sources {
                guard sampleCount > 0, let url = optionalURL else { continue }
                guard let speechSegments = try await provider.meetingSpeechSegments(at: url) else {
                    throw HomanWhisperError.vadUnavailable
                }
                let samples = try AudioConverter().resampleAudioFile(url)
                for (index, segment) in speechSegments
                    .sorted(by: { $0.startTime < $1.startTime })
                    .enumerated() {
                    try Task.checkCancellation()
                    let startSample = max(
                        0,
                        min(samples.count, segment.startSample(sampleRate: VadManager.sampleRate))
                    )
                    let endSample = max(
                        startSample,
                        min(samples.count, segment.endSample(sampleRate: VadManager.sampleRate))
                    )
                    guard endSample > startSample else { continue }
                    let id = String(format: "%@-%04d", source.rawValue, index)
                    let m4aURL = try await encodeRemoteSpeechItem(
                        samples: Array(samples[startSample..<endSample]),
                        directoryName: "homan-whisper-stt-items",
                        destinationURL: checkpointBuilder?.itemURL(at: items.count)
                    )
                    items.append(RemoteMeetingSpeechItem(
                        id: id,
                        source: source,
                        start: Double(startSample) / Double(VadManager.sampleRate),
                        end: Double(endSample) / Double(VadManager.sampleRate),
                        audioURL: m4aURL
                    ))
                }
            }
            guard !items.isEmpty else { throw HomanWhisperError.noSpeechItems }
            guard items.count <= 2048 else { throw HomanWhisperError.tooManyItems(items.count) }
            if let checkpointBuilder {
                let checkpoint = try checkpointBuilder.commit(items: items)
                return PreparedRemoteBatch(
                    items: checkpoint.items,
                    requestID: checkpoint.requestID,
                    responseCacheURL: checkpoint.responseURL,
                    removesItemsAfterUse: false
                )
            }
            return PreparedRemoteBatch(
                items: items,
                requestID: UUID(),
                responseCacheURL: nil,
                removesItemsAfterUse: true
            )
        } catch {
            for item in items {
                try? FileManager.default.removeItem(at: item.audioURL)
            }
            throw error
        }
    }

    private func encodeRemoteSpeechItem(
        samples: [Float],
        directoryName: String = "homan-whisper-stt-items",
        destinationURL: URL? = nil
    ) async throws -> URL {
        let wavURL = try WavWriter.writeTemporaryWAV(
            samples: samples,
            directoryName: directoryName
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: wavURL.path
        )
        let m4aURL = destinationURL
            ?? wavURL.deletingPathExtension().appendingPathExtension("m4a")
        do {
            try await HomanWhisperM4AEncoder.encode(
                wavURL: wavURL,
                destinationURL: m4aURL
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: m4aURL.path
            )
            try? FileManager.default.removeItem(at: wavURL)
            return m4aURL
        } catch {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: m4aURL)
            throw error
        }
    }

    func transcribeHomanWhisperLegacyFile(at url: URL) async throws -> SpeechTranscriptionResult {
        let samples = try AudioConverter().resampleAudioFile(url)
        let results = try await recognizeHomanWhisperBatch(
            sources: [(.legacyMixed, url, samples.count)]
        )
        let segments = Self.sourceSegments(from: results).map {
            SpeechSegment(start: $0.startSeconds, end: $0.endSeconds, text: $0.text)
        }
        return SpeechTranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments
        )
    }

    private func recognize(
        source: MeetingAudioSourceRole,
        url: URL?,
        sampleCount: Int,
        request: MeetingTranscriptionRequest
    ) async -> RecognitionOutcome {
        guard sampleCount > 0, let url else { return .unavailable }
        do {
            try await inferenceScheduler.waitUntilCaptureAllowsInference()
            if let speechSegments = try await provider.meetingSpeechSegments(at: url) {
                guard !speechSegments.isEmpty else { return .success([]) }
                return .success(try await recognizeSpeechSegments(
                    speechSegments,
                    source: source,
                    sourceURL: url,
                    request: request
                ))
            }
            try await inferenceScheduler.waitUntilCaptureAllowsInference()
            let result = try await provider.transcribeMeeting(
                at: url,
                backend: request.backend,
                cohereLanguage: CohereTranscribeLanguage.resolved(
                    request.languages.cohereLanguage
                ),
                indicASRLanguage: IndicASRLanguage.resolved(
                    request.languages.indicASRLanguage
                )
            )
            let duration = max(Double(sampleCount) / 16_000, 0.1)
            switch source {
            case .microphone:
                return .success(MicTurnNormalizer.normalize(
                    result: result,
                    startTime: 0,
                    endTime: duration
                ))
            case .system:
                return .success(SystemTurnNormalizer.normalize(
                    result: result,
                    startTime: 0,
                    endTime: duration
                ))
            case .legacyMixed:
                return .success([])
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure
        }
    }

    private func recognizeSpeechSegments(
        _ speechSegments: [VadSegment],
        source: MeetingAudioSourceRole,
        sourceURL: URL,
        request: MeetingTranscriptionRequest
    ) async throws -> [SpeechSegment] {
        let audio = try WavReader.readFloatMonoWAV(from: sourceURL)
        guard audio.sampleRate > 0, !audio.samples.isEmpty else { return [] }

        var recognized: [SpeechSegment] = []
        for speechSegment in speechSegments.sorted(by: { $0.startTime < $1.startTime }) {
            try await inferenceScheduler.waitUntilCaptureAllowsInference()
            try Task.checkCancellation()
            let startSample = max(
                0,
                min(audio.samples.count, speechSegment.startSample(sampleRate: audio.sampleRate))
            )
            let endSample = max(
                startSample,
                min(audio.samples.count, speechSegment.endSample(sampleRate: audio.sampleRate))
            )
            guard endSample > startSample else { continue }

            let chunkURL = try WavWriter.writeTemporaryWAV(
                samples: Array(audio.samples[startSample..<endSample]),
                directoryName: "muesli-meeting-post-vad"
            )
            do {
                try await inferenceScheduler.waitUntilCaptureAllowsInference()
                let result = try await provider.transcribeMeeting(
                    at: chunkURL,
                    backend: request.backend,
                    cohereLanguage: CohereTranscribeLanguage.resolved(
                        request.languages.cohereLanguage
                    ),
                    indicASRLanguage: IndicASRLanguage.resolved(
                        request.languages.indicASRLanguage
                    )
                )
                let startTime = Double(startSample) / Double(audio.sampleRate)
                let endTime = Double(endSample) / Double(audio.sampleRate)
                switch source {
                case .microphone:
                    recognized.append(contentsOf: MicTurnNormalizer.normalize(
                        result: result,
                        startTime: startTime,
                        endTime: endTime
                    ))
                case .system:
                    recognized.append(contentsOf: SystemTurnNormalizer.normalize(
                        result: result,
                        startTime: startTime,
                        endTime: endTime
                    ))
                case .legacyMixed:
                    break
                }
                try? FileManager.default.removeItem(at: chunkURL)
            } catch {
                try? FileManager.default.removeItem(at: chunkURL)
                throw error
            }
        }
        return recognized
    }

    private func acceptedSegments(
        from outcome: RecognitionOutcome,
        source: MeetingAudioSourceRole,
        degradations: inout [MeetingProcessingDegradation]
    ) -> [SpeechSegment] {
        switch outcome {
        case .success(let segments):
            return segments
        case .failure:
            degradations.append(.sourceRecognitionFailed(source))
            return []
        case .unavailable:
            return []
        case .cancelled:
            return []
        }
    }

    private func processLegacy(
        _ input: MeetingLegacyRecordingInput,
        request: MeetingTranscriptionRequest
    ) async throws -> MeetingUnitTranscriptionResult {
        guard MeetingRecordingUnitInput
            .legacyMixed(input)
            .hasUsableAudio(onDisk: .default) else {
            throw MeetingTranscriptionPipelineError.noUsableAudio
        }
        guard let lease = leaseRegistry.acquireRead(
            for: .recordingID(input.recording.id)
        ) else {
            throw MeetingTranscriptionPipelineError.noUsableAudio
        }
        defer { lease.release() }

        let transcription: SpeechTranscriptionResult
        if request.backend.backend == BackendOption.homanWhisper.backend {
            transcription = try await transcribeHomanWhisperLegacyFile(at: input.playbackURL)
        } else {
            try await inferenceScheduler.waitUntilCaptureAllowsInference()
            transcription = try await provider.transcribeMeeting(
                at: input.playbackURL,
                backend: request.backend,
                cohereLanguage: CohereTranscribeLanguage.resolved(
                    request.languages.cohereLanguage
                ),
                indicASRLanguage: IndicASRLanguage.resolved(
                    request.languages.indicASRLanguage
                )
            )
        }
        let segments = SystemTurnNormalizer.normalize(
            result: transcription,
            startTime: 0,
            endTime: max(Self.wavDuration(at: input.playbackURL) ?? 0.1, 0.1)
        )
        let degradations = [.legacySourceIdentityUnavailable] + input.degradations
        let turns = TranscriptFormatter.legacyAttributedTurns(
            segments: segments,
            recordingSessionID: nil,
            isProvisional: false
        )
        guard !turns.isEmpty else {
            throw MeetingTranscriptionPipelineError.emptyTranscript
        }
        return MeetingUnitTranscriptionResult(
            unitID: "recording-\(input.recording.id)",
            sessionID: nil,
            startedAt: input.recording.createdAt,
            attributedTurns: turns,
            formattedTranscript: TranscriptFormatter.format(
                attributedTurns: turns,
                meetingStart: input.recording.createdAt
            ),
            degradations: Self.uniqued(degradations),
            recognizedSegments: segments.enumerated().map { index, segment in
                SourceRecognizedSegment(
                    id: String(format: "legacy-%04d", index),
                    source: .legacyMixed,
                    startSeconds: segment.start,
                    endSeconds: segment.end,
                    text: segment.text,
                    confidence: nil,
                    timestampPrecision: .modelSegment
                )
            },
            microphoneSegments: [],
            systemSegments: segments,
            diarizationSegments: nil
        )
    }

    private static func sourceSegments(
        from remote: [RemoteMeetingSpeechResult]
    ) -> [SourceRecognizedSegment] {
        remote.flatMap { item -> [SourceRecognizedSegment] in
            if let inner = item.segments, !inner.isEmpty {
                return inner.map { segment in
                    SourceRecognizedSegment(
                        // Segment identifiers are scoped to a response item by
                        // the Homan Whisper contract. Namespace them before
                        // publishing meeting-wide evidence so two items may
                        // both safely contain (for example) `segment-0`.
                        id: "\(item.id)/\(segment.id)",
                        source: item.source,
                        startSeconds: segment.start,
                        endSeconds: segment.end,
                        text: segment.text,
                        confidence: nil,
                        timestampPrecision: .modelSegment
                    )
                }
            }
            guard !item.text.isEmpty else { return [] }
            return [SourceRecognizedSegment(
                id: item.id,
                source: item.source,
                startSeconds: item.start,
                endSeconds: item.end,
                text: item.text,
                confidence: nil,
                timestampPrecision: .vadItem
            )]
        }
    }

    private static func rebasedRemoteResult(
        _ item: RemoteMeetingSpeechResult,
        subtracting offset: TimeInterval
    ) -> RemoteMeetingSpeechResult {
        let localStart = max(0, item.start - offset)
        let localEnd = max(localStart, item.end - offset)
        return RemoteMeetingSpeechResult(
            id: item.id,
            source: item.source,
            start: localStart,
            end: localEnd,
            text: item.text,
            segments: item.segments?.map { segment in
                RemoteMeetingSpeechSubsegment(
                    id: segment.id,
                    start: max(0, segment.start - offset),
                    end: max(0, segment.end - offset),
                    text: segment.text
                )
            }
        )
    }

    private static func speechSegments(
        from segments: [SourceRecognizedSegment],
        source: MeetingAudioSourceRole
    ) -> [SpeechSegment] {
        segments.filter { $0.source == source }.map {
            SpeechSegment(start: $0.startSeconds, end: $0.endSeconds, text: $0.text)
        }
    }

    private static func sourceSegments(
        microphone: [SpeechSegment],
        system: [SpeechSegment]
    ) -> [SourceRecognizedSegment] {
        let mic = microphone.enumerated().map { index, segment in
            SourceRecognizedSegment(
                id: String(format: "microphone-%04d", index),
                source: .microphone,
                startSeconds: segment.start,
                endSeconds: segment.end,
                text: segment.text,
                confidence: nil,
                timestampPrecision: .modelSegment
            )
        }
        let remote = system.enumerated().map { index, segment in
            SourceRecognizedSegment(
                id: String(format: "system-%04d", index),
                source: .system,
                startSeconds: segment.start,
                endSeconds: segment.end,
                text: segment.text,
                confidence: nil,
                timestampPrecision: .modelSegment
            )
        }
        return mic + remote
    }

    private func applyMeetingWideDiarizationIfNeeded(
        to unitResults: [MeetingUnitTranscriptionResult],
        request: MeetingTranscriptionRequest,
        renderTimeline: () throws -> MeetingRenderedSystemTimeline
    ) async throws -> MeetingTranscriptionResult {
        let hasDiarizableEvidence = unitResults.contains { unit in
            unit.recognizedSegments.contains {
                $0.source == .system || $0.source == .legacyMixed
            }
        }
        guard hasDiarizableEvidence else {
            return try Self.combine(unitResults)
        }

        var renderedTimelineMap: MeetingSystemTimelineMap?
        do {
            let timeline = try renderTimeline()
            defer { timeline.removeTemporaryFile() }
            renderedTimelineMap = timeline.map
            if let reusable = request.reusableDiarization,
               Self.isReusable(
                   reusable,
                   for: timeline.map,
                   requestedProfileID: request.diarizationProfileID
               ) {
                request.progress(.applyingSpeakerLabels)
                let globalSegments = reusable.activitySegments.map {
                    TimedSpeakerSegment(
                        speakerId: $0.speakerKey,
                        embedding: [],
                        startTimeSeconds: Float($0.startSeconds),
                        endTimeSeconds: Float($0.endSeconds),
                        qualityScore: $0.confidence ?? 0
                    )
                }
                return try Self.combine(
                    Self.applyingGlobalDiarization(
                        globalSegments,
                        timelineMap: timeline.map,
                        to: unitResults
                    ),
                    systemTimelineMap: timeline.map,
                    diarizationProfile: reusable.profile,
                    diarizationTimings: reusable.timings,
                    reusedDiarizationRevisionID: reusable.id
                )
            }
            if request.systemDiarization == .reuseCompatible {
                throw MeetingTranscriptionPipelineError.compatibleDiarizationUnavailable
            }
            guard shouldDiarize(request) else {
                return try Self.combine(
                    unitResults,
                    systemTimelineMap: timeline.map
                )
            }
            request.progress(.preparingDiarizer)
            try Task.checkCancellation()
            request.progress(.diarizing)
            guard let analysis = try await provider.meetingDiarizationTimeline(
                MeetingSystemTimelineInput(url: timeline.url, map: timeline.map),
                profileID: request.diarizationProfileID,
                progress: { _ in }
            ), !analysis.activitySegments.isEmpty else {
                return try Self.combine(
                    Self.addingDegradation(.optionalDiarizationFailed, to: unitResults),
                    systemTimelineMap: timeline.map
                )
            }
            try Task.checkCancellation()
            request.progress(.applyingSpeakerLabels)
            let globalSegments = analysis.activitySegments.map {
                TimedSpeakerSegment(
                    speakerId: $0.speakerKey,
                    embedding: [],
                    startTimeSeconds: Float($0.startSeconds),
                    endTimeSeconds: Float($0.endSeconds),
                    qualityScore: $0.confidence ?? 0
                )
            }
            let attributedUnits = Self.applyingGlobalDiarization(
                globalSegments,
                timelineMap: timeline.map,
                to: unitResults
            )
            return try Self.combine(
                attributedUnits,
                systemTimelineMap: timeline.map,
                diarizationProfile: analysis.profile,
                diarizationTimings: analysis.timings
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if request.systemDiarization == .reuseCompatible {
                throw MeetingTranscriptionPipelineError.compatibleDiarizationUnavailable
            }
            return try Self.combine(
                Self.addingDegradation(.optionalDiarizationFailed, to: unitResults),
                systemTimelineMap: renderedTimelineMap
            )
        }
    }

    private static func applyingGlobalDiarization(
        _ globalSegments: [TimedSpeakerSegment],
        timelineMap: MeetingSystemTimelineMap,
        to units: [MeetingUnitTranscriptionResult]
    ) -> [MeetingUnitTranscriptionResult] {
        let entryByUnit = Dictionary(
            uniqueKeysWithValues: timelineMap.entries.map { ($0.unitID, $0) }
        )
        return units.map { unit in
            guard let entry = entryByUnit[unit.unitID] else { return unit }
            let localDiarization = globalSegments.compactMap { segment -> TimedSpeakerSegment? in
                let start = max(
                    entry.globalStartSeconds,
                    TimeInterval(segment.startTimeSeconds)
                )
                let end = min(
                    entry.globalEndSeconds,
                    TimeInterval(segment.endTimeSeconds)
                )
                guard end > start else { return nil }
                return TimedSpeakerSegment(
                    speakerId: segment.speakerId,
                    embedding: [],
                    startTimeSeconds: Float(start - entry.globalStartSeconds),
                    endTimeSeconds: Float(end - entry.globalStartSeconds),
                    qualityScore: segment.qualityScore
                )
            }
            let isLegacy = unit.recognizedSegments.contains { $0.source == .legacyMixed }
            let reconciled = TranscriptReconciler.reconcile(
                micTurns: unit.microphoneSegments,
                systemSegments: unit.systemSegments,
                diarizationSegments: localDiarization
            )
            let turns: [AttributedTurn]
            if isLegacy {
                turns = TranscriptFormatter.legacyAttributedTurns(
                    segments: reconciled.systemSegments,
                    diarizationSegments: reconciled.diarizationSegments,
                    recordingSessionID: unit.sessionID,
                    isProvisional: false
                )
            } else {
                turns = TranscriptFormatter.attributedTurns(
                    micSegments: reconciled.micSegments,
                    systemSegments: reconciled.systemSegments,
                    diarizationSegments: reconciled.diarizationSegments,
                    recordingSessionID: unit.sessionID,
                    isProvisional: false
                )
            }
            return MeetingUnitTranscriptionResult(
                unitID: unit.unitID,
                sessionID: unit.sessionID,
                startedAt: unit.startedAt,
                attributedTurns: turns,
                formattedTranscript: TranscriptFormatter.format(
                    attributedTurns: turns,
                    meetingStart: unit.startedAt
                ),
                degradations: unit.degradations,
                recognizedSegments: unit.recognizedSegments,
                microphoneSegments: reconciled.micSegments,
                systemSegments: reconciled.systemSegments,
                diarizationSegments: localDiarization,
                aecDiagnostics: unit.aecDiagnostics
            )
        }
    }

    private static func addingDegradation(
        _ degradation: MeetingProcessingDegradation,
        to units: [MeetingUnitTranscriptionResult]
    ) -> [MeetingUnitTranscriptionResult] {
        units.map { unit in
            MeetingUnitTranscriptionResult(
                unitID: unit.unitID,
                sessionID: unit.sessionID,
                startedAt: unit.startedAt,
                attributedTurns: unit.attributedTurns,
                formattedTranscript: unit.formattedTranscript,
                degradations: uniqued(unit.degradations + [degradation]),
                recognizedSegments: unit.recognizedSegments,
                microphoneSegments: unit.microphoneSegments,
                systemSegments: unit.systemSegments,
                diarizationSegments: unit.diarizationSegments,
                aecDiagnostics: unit.aecDiagnostics
            )
        }
    }

    private func shouldDiarize(_ request: MeetingTranscriptionRequest) -> Bool {
        guard request.systemDiarization == .optionalPost else { return false }
        switch request.purpose {
        case .final, .recovery, .retranscribe:
            return true
        case .liveStreaming, .liveChunked:
            return false
        }
    }

    private static func isReusable(
        _ revision: MeetingDiarizationRevision,
        for map: MeetingSystemTimelineMap,
        requestedProfileID: MeetingDiarizationProfileID
    ) -> Bool {
        guard revision.status == .complete,
              revision.schemaVersion == MeetingDiarizationRevision.currentSchemaVersion,
              revision.timelineDigest == map.digest,
              revision.sourceFingerprints == map.sourceFingerprints,
              revision.timelineMap?.renderVersion == map.renderVersion else {
            return false
        }
        return MeetingDiarizationProfiles.matchesActiveProvider(
            revision.profile,
            requestedID: requestedProfileID
        )
    }

    private static func combine(
        _ units: [MeetingUnitTranscriptionResult],
        systemTimelineMap: MeetingSystemTimelineMap? = nil,
        diarizationProfile: MeetingDiarizationProfileSnapshot? = nil,
        diarizationTimings: MeetingDiarizationTimings? = nil,
        reusedDiarizationRevisionID: UUID? = nil
    ) throws -> MeetingTranscriptionResult {
        guard !units.isEmpty else {
            throw MeetingTranscriptionPipelineError.noRecordingUnits
        }
        let turns = units.flatMap(\.attributedTurns)
        guard !turns.isEmpty else {
            throw MeetingTranscriptionPipelineError.emptyTranscript
        }
        return MeetingTranscriptionResult(
            units: units,
            attributedTurns: turns,
            formattedTranscript: units
                .map(\.formattedTranscript)
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            degradations: uniqued(units.flatMap(\.degradations)),
            systemTimelineMap: systemTimelineMap,
            diarizationProfile: diarizationProfile,
            diarizationTimings: diarizationTimings,
            reusedDiarizationRevisionID: reusedDiarizationRevisionID
        )
    }

    private static func unitComesBefore(
        _ lhs: MeetingRecordingUnitInput,
        _ rhs: MeetingRecordingUnitInput
    ) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.stableOrder < rhs.stableOrder
        }
        return lhs.createdAt < rhs.createdAt
    }

    private static func uniqued(
        _ degradations: [MeetingProcessingDegradation]
    ) -> [MeetingProcessingDegradation] {
        var seen: Set<MeetingProcessingDegradation> = []
        return degradations.filter { seen.insert($0).inserted }
    }

    private static func wavDuration(at url: URL) -> TimeInterval? {
        guard url.pathExtension.lowercased() == "wav",
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            return nil
        }
        let sampleRate = Int(
            UInt32(data[24])
                | (UInt32(data[25]) << 8)
                | (UInt32(data[26]) << 16)
                | (UInt32(data[27]) << 24)
        )
        let channels = Int(UInt16(data[22]) | (UInt16(data[23]) << 8))
        let bitsPerSample = Int(UInt16(data[34]) | (UInt16(data[35]) << 8))
        let dataSize = Int(
            UInt32(data[40])
                | (UInt32(data[41]) << 8)
                | (UInt32(data[42]) << 16)
                | (UInt32(data[43]) << 24)
        )
        let bytesPerFrame = channels * bitsPerSample / 8
        guard sampleRate > 0, bytesPerFrame > 0 else { return nil }
        return Double(dataSize / bytesPerFrame) / Double(sampleRate)
    }
}
