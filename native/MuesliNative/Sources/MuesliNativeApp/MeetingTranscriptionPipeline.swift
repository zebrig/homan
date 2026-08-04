import FluidAudio
import Foundation

protocol MeetingTranscriptionProviding: Sendable {
    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult

    func meetingSpeechSegments(at url: URL) async throws -> [VadSegment]?

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]?
}

extension MeetingTranscriptionProviding {
    func meetingSpeechSegments(at url: URL) async throws -> [VadSegment]? {
        nil
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

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]? {
        try await diarizeSystemAudio(at: url)?.segments
    }
}

struct MeetingTranscriptionPipeline: Sendable {
    private struct CanonicalSourceUnit: Sendable {
        let sessionID: UUID?
        let startedAt: Date
        let microphoneURL: URL?
        let systemURL: URL?
        let microphoneSampleCount: Int
        let systemSampleCount: Int
        let degradations: [MeetingProcessingDegradation]
        let leaseKey: MeetingRecordingLeaseKey?
    }

    private enum RecognitionOutcome: Sendable {
        case success([SpeechSegment])
        case failure
        case unavailable
        case cancelled
    }

    private struct PreparedRemoteBatch: Sendable {
        let items: [RemoteMeetingSpeechItem]

        func removeTemporaryFiles() {
            for item in items {
                try? FileManager.default.removeItem(at: item.audioURL)
            }
        }
    }

    private let provider: any MeetingTranscriptionProviding
    private let leaseRegistry: MeetingRecordingLeaseRegistry
    private let aecFactory: @Sendable (MeetingAecModel) -> MeetingNeuralAec

    init(
        provider: any MeetingTranscriptionProviding,
        leaseRegistry: MeetingRecordingLeaseRegistry = .shared,
        aecFactory: @escaping @Sendable (MeetingAecModel) -> MeetingNeuralAec = {
            MeetingNeuralAec(localVQEModel: $0)
        }
    ) {
        self.provider = provider
        self.leaseRegistry = leaseRegistry
        self.aecFactory = aecFactory
    }

    init(
        coordinator: TranscriptionCoordinator,
        leaseRegistry: MeetingRecordingLeaseRegistry = .shared,
        aecFactory: @escaping @Sendable (MeetingAecModel) -> MeetingNeuralAec = {
            MeetingNeuralAec(localVQEModel: $0)
        }
    ) {
        self.init(
            provider: coordinator,
            leaseRegistry: leaseRegistry,
            aecFactory: aecFactory
        )
    }

    func process(_ request: MeetingTranscriptionRequest) async throws -> MeetingTranscriptionResult {
        guard !request.units.isEmpty else {
            throw MeetingTranscriptionPipelineError.noRecordingUnits
        }

        var unitResults: [MeetingUnitTranscriptionResult] = []
        for input in request.units.sorted(by: Self.unitComesBefore) {
            switch input {
            case .sourceBundle(let sourceInput):
                let bundle = sourceInput.bundle
                let recordingID = sourceInput.recording?.id ?? bundle.manifest.recordingID
                if let rawAudio = bundle.rawAudio {
                    unitResults.append(
                        try await processRawBundle(
                            rawAudio,
                            bundle: bundle,
                            recordingID: recordingID,
                            request: request
                        )
                    )
                    continue
                }
                let unit = CanonicalSourceUnit(
                    sessionID: bundle.manifest.sessionID,
                    startedAt: bundle.manifest.startedAt,
                    microphoneURL: bundle.microphoneURL,
                    systemURL: bundle.systemURL,
                    microphoneSampleCount: bundle.manifest.microphone.sampleCount,
                    systemSampleCount: bundle.manifest.system.sampleCount,
                    degradations: bundle.degradations,
                    leaseKey: recordingID.map(MeetingRecordingLeaseKey.recordingID)
                        ?? .sessionID(bundle.manifest.sessionID)
                )
                unitResults.append(try await processCanonical(unit, request: request))
            case .separatedChannels(let separatedInput):
                unitResults.append(try await processSeparated(
                    separatedInput,
                    request: request
                ))
            case .legacyMixed(let legacyInput):
                unitResults.append(try await processLegacy(
                    legacyInput,
                    request: request
                ))
            }
        }
        return try Self.combine(unitResults)
    }

    func process(
        stagedAudio: MeetingStagedAudio,
        backend: BackendOption,
        languages: MeetingLanguageSnapshot,
        purpose: MeetingProcessingPurpose,
        systemDiarization: SystemDiarizationPolicy
    ) async throws -> MeetingTranscriptionResult {
        let manifest = stagedAudio.manifest
        let unit = CanonicalSourceUnit(
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
            systemDiarization: systemDiarization
        )
        return try Self.combine([try await processCanonical(unit, request: request)])
    }

    private func processRawBundle(
        _ rawAudio: MeetingStagedRawAudio,
        bundle: MeetingRecordingBundle,
        recordingID: Int64?,
        request: MeetingTranscriptionRequest
    ) async throws -> MeetingUnitTranscriptionResult {
        let leaseKey = recordingID.map(MeetingRecordingLeaseKey.recordingID)
            ?? .sessionID(bundle.manifest.sessionID)
        guard let lease = leaseRegistry.acquireRead(for: leaseKey) else {
            throw MeetingTranscriptionPipelineError.noUsableAudio
        }
        defer { lease.release() }

        let prepared = try await MeetingRawAudioPostProcessor
            .renderProcessingView(
                rawAudio,
                aec: aecFactory(request.aecModel)
            )
        defer { prepared.removeTemporaryFiles() }
        let unit = CanonicalSourceUnit(
            sessionID: bundle.manifest.sessionID,
            startedAt: bundle.manifest.startedAt,
            microphoneURL: prepared.microphoneURL,
            systemURL: prepared.systemURL,
            microphoneSampleCount: prepared.microphoneSampleCount,
            systemSampleCount: prepared.systemSampleCount,
            degradations: bundle.degradations,
            leaseKey: nil
        )
        return try await processCanonical(unit, request: request)
    }

    private func processSeparated(
        _ input: MeetingSeparatedRecordingInput,
        request: MeetingTranscriptionRequest
    ) async throws -> MeetingUnitTranscriptionResult {
        guard MeetingRecordingUnitInput
            .separatedChannels(input)
            .hasUsableAudio(onDisk: .default) else {
            throw MeetingTranscriptionPipelineError.noUsableAudio
        }
        guard let lease = leaseRegistry.acquireRead(
            for: .recordingID(input.recording.id)
        ) else {
            throw MeetingTranscriptionPipelineError.noUsableAudio
        }
        defer { lease.release() }

        let extracted = try MeetingRecordingWriter.extractSeparatedChannels(
            from: input.recordingURL,
            sourceLayout: input.sourceLayout
        )
        defer { extracted.removeTemporaryFiles() }

        let unit = CanonicalSourceUnit(
            sessionID: nil,
            startedAt: input.recording.createdAt,
            microphoneURL: extracted.microphoneURL,
            systemURL: extracted.systemURL,
            microphoneSampleCount: extracted.microphoneSampleCount,
            systemSampleCount: extracted.systemSampleCount,
            degradations: [],
            leaseKey: nil
        )
        return try await processCanonical(unit, request: request)
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
        if request.backend.backend == BackendOption.homanWhisper.backend {
            let remote = try await recognizeHomanWhisperBatch(
                sources: [
                    (.microphone, unit.microphoneURL, unit.microphoneSampleCount),
                    (.system, unit.systemURL, unit.systemSampleCount),
                ]
            )
            microphoneSegments = remote.filter { $0.source == .microphone }.compactMap {
                $0.text.isEmpty ? nil : SpeechSegment(start: $0.start, end: $0.end, text: $0.text)
            }
            systemSegments = remote.filter { $0.source == .system }.compactMap {
                $0.text.isEmpty ? nil : SpeechSegment(start: $0.start, end: $0.end, text: $0.text)
            }
        } else {
            async let microphoneOutcome = recognize(
                source: .microphone,
                url: unit.microphoneURL,
                sampleCount: unit.microphoneSampleCount,
                request: request
            )
            async let systemOutcome = recognize(
                source: .system,
                url: unit.systemURL,
                sampleCount: unit.systemSampleCount,
                request: request
            )
            let (microphone, system) = await (microphoneOutcome, systemOutcome)
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
        }

        var diarizationSegments: [TimedSpeakerSegment]?
        if request.backend.backend != BackendOption.homanWhisper.backend,
           shouldDiarize(request),
           let systemURL = unit.systemURL,
           !systemSegments.isEmpty {
            do {
                diarizationSegments = try await provider.meetingDiarizationSegments(at: systemURL)
            } catch {
                degradations.append(.optionalDiarizationFailed)
            }
        }

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: microphoneSegments,
            systemSegments: systemSegments,
            diarizationSegments: diarizationSegments
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
            sessionID: unit.sessionID,
            attributedTurns: turns,
            formattedTranscript: TranscriptFormatter.format(
                attributedTurns: turns,
                meetingStart: unit.startedAt
            ),
            degradations: Self.uniqued(degradations),
            microphoneSegments: reconciled.micSegments,
            systemSegments: reconciled.systemSegments,
            diarizationSegments: reconciled.diarizationSegments
        )
    }

    private func recognizeHomanWhisperBatch(
        sources: [(MeetingAudioSourceRole, URL?, Int)]
    ) async throws -> [RemoteMeetingSpeechResult] {
        guard let batchProvider = provider as? any MeetingBatchTranscriptionProviding else {
            throw HomanWhisperError.invalidResponse("batch provider unavailable")
        }
        let prepared = try await prepareHomanWhisperBatch(sources: sources)
        defer { prepared.removeTemporaryFiles() }
        return try await batchProvider.transcribeMeetingBatch(
            items: prepared.items,
            requestID: UUID()
        )
    }

    private func prepareHomanWhisperBatch(
        sources: [(MeetingAudioSourceRole, URL?, Int)]
    ) async throws -> PreparedRemoteBatch {
        var items: [RemoteMeetingSpeechItem] = []
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
                    let wavURL = try WavWriter.writeTemporaryWAV(
                        samples: Array(samples[startSample..<endSample]),
                        directoryName: "homan-whisper-stt-items"
                    )
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: wavURL.path
                    )
                    let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
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
                    } catch {
                        try? FileManager.default.removeItem(at: wavURL)
                        try? FileManager.default.removeItem(at: m4aURL)
                        throw error
                    }
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
            return PreparedRemoteBatch(items: items)
        } catch {
            for item in items {
                try? FileManager.default.removeItem(at: item.audioURL)
            }
            throw error
        }
    }

    func transcribeHomanWhisperLegacyFile(at url: URL) async throws -> SpeechTranscriptionResult {
        let samples = try AudioConverter().resampleAudioFile(url)
        let results = try await recognizeHomanWhisperBatch(
            sources: [(.legacyMixed, url, samples.count)]
        )
        let segments = results.compactMap {
            $0.text.isEmpty ? nil : SpeechSegment(start: $0.start, end: $0.end, text: $0.text)
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
            if let speechSegments = try await provider.meetingSpeechSegments(at: url) {
                guard !speechSegments.isEmpty else { return .success([]) }
                return .success(try await recognizeSpeechSegments(
                    speechSegments,
                    source: source,
                    sourceURL: url,
                    request: request
                ))
            }
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
        let turns = TranscriptFormatter.legacyAttributedTurns(
            segments: segments,
            recordingSessionID: nil,
            isProvisional: false
        )
        guard !turns.isEmpty else {
            throw MeetingTranscriptionPipelineError.emptyTranscript
        }
        return MeetingUnitTranscriptionResult(
            sessionID: nil,
            attributedTurns: turns,
            formattedTranscript: TranscriptFormatter.format(
                attributedTurns: turns,
                meetingStart: input.recording.createdAt
            ),
            degradations: Self.uniqued(
                [.legacySourceIdentityUnavailable] + input.degradations
            ),
            microphoneSegments: [],
            systemSegments: [],
            diarizationSegments: nil
        )
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

    private static func combine(
        _ units: [MeetingUnitTranscriptionResult]
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
            degradations: uniqued(units.flatMap(\.degradations))
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
