import Testing
import Accelerate
import AppKit
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("BackendOption")
struct BackendOptionTests {

    @Test("runtime failure blocks Active while paused work remains retryable")
    func modelDownloadSnapshotActivationPolicy() {
        let preparing = ModelDownloadProgress.preparing(modelID: "model", message: "Preparing")
        let failed = preparing.replacing(phase: .failed, message: "Runtime rejected model")
        let paused = preparing.replacing(phase: .paused, message: "Paused")

        #expect(ModelDownloadDisplayFormatting.isActiveJob(preparing))
        #expect(!ModelDownloadDisplayFormatting.isActiveJob(failed))
        #expect(ModelDownloadDisplayFormatting.blocksActivation(failed))
        #expect(!ModelDownloadDisplayFormatting.blocksActivation(paused))
    }

    @Test("all options have unique models")
    func uniqueModels() {
        let models = BackendOption.all.map(\.model)
        #expect(Set(models).count == models.count, "Duplicate model in BackendOption.all")
    }

    @Test("all options have non-empty labels and descriptions")
    func labelsAndDescriptions() {
        for option in BackendOption.all {
            #expect(!option.label.isEmpty, "Empty label for \(option.model)")
            #expect(!option.description.isEmpty, "Empty description for \(option.model)")
            #expect(!option.sizeLabel.isEmpty, "Empty sizeLabel for \(option.model)")
        }
    }

    @Test("backend field is one of the known backends")
    func knownBackends() {
        let known: Set<String> = ["fluidaudio", "whisper", "qwen", "nemotron35", "cohere", "indicasr", "sensevoice", "gemma4-litert"]
        for option in BackendOption.all {
            #expect(known.contains(option.backend), "Unknown backend: \(option.backend)")
        }
    }

    @Test("Parakeet models use fluidaudio backend")
    func parakeetBackend() {
        #expect(BackendOption.parakeetMultilingual.backend == "fluidaudio")
        #expect(BackendOption.parakeetEnglish.backend == "fluidaudio")
    }

    @Test("partial Parakeet directories are never reported as downloaded")
    func partialParakeetIsNotDownloaded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-parakeet-readiness-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ManagedASRModelPlans.parakeetV3(modelsRoot: legacy)
        let sentinel = plan.cacheDirectory
            .appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
            .appendingPathComponent("coremldata.bin")
        try FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(to: sentinel)

        #expect(!HomanModelDownloadCenter.isAvailableLocally(
            .parakeetMultilingual,
            supportDirectory: support,
            legacyModelsRoot: legacy
        ))
    }

    @Test("structurally complete legacy Parakeet stays not-ready until runtime adoption")
    func completeLegacyParakeetRequiresRuntimeAdoption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-parakeet-legacy-readiness-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ManagedASRModelPlans.parakeetV3(modelsRoot: legacy)
        for model in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            let directory = plan.cacheDirectory.appendingPathComponent("\(model).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("weights", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data([0x01]).write(to: directory.appendingPathComponent("coremldata.bin"))
            try Data([0x02]).write(to: directory.appendingPathComponent("weights/weight.bin"))
        }
        try Data(#"{"0":"<blank>"}"#.utf8).write(
            to: plan.cacheDirectory.appendingPathComponent("parakeet_vocab.json")
        )

        #expect(plan.isAvailableLocally())
        #expect(!HomanModelDownloadCenter.isAvailableLocally(
            .parakeetMultilingual,
            supportDirectory: support,
            legacyModelsRoot: legacy
        ))
    }

    @Test("Parakeet downloads are pinned to reviewed immutable revisions")
    func parakeetDownloadsUsePinnedRevisions() {
        let v2 = ManagedASRModelPlans.parakeetV2(modelsRoot: URL(fileURLWithPath: "/tmp/v2"))
        let v3 = ManagedASRModelPlans.parakeetV3(modelsRoot: URL(fileURLWithPath: "/tmp/v3"))
        #expect(v2.revision == "ee09c569f73759e6d44c9bd16766f477b2b36d39")
        #expect(v3.revision == "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe")
        #expect(v2.revision != "main")
        #expect(v3.revision != "main")
    }

    @Test("deleting a managed Parakeet suppresses but never deletes the shared legacy source")
    func parakeetLegacySuppressionIsNonDestructive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-parakeet-suppression-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let legacyFile = root.appendingPathComponent("legacy/model.bin")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: legacyFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: legacyFile)

        try HomanModelDownloadCenter.suppressLegacyAdoption(
            .parakeetMultilingual,
            supportDirectory: support
        )

        #expect(HomanModelDownloadCenter.isLegacySuppressed(
            .parakeetMultilingual,
            supportDirectory: support
        ))
        #expect(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    @Test("Whisper models use whisper backend")
    func whisperBackend() {
        #expect(BackendOption.whisperSmall.backend == "whisper")
        #expect(BackendOption.whisperMedium.backend == "whisper")
        #expect(BackendOption.whisperLargeTurbo.backend == "whisper")
    }

    @Test("Nemotron 3.5 uses nemotron35 backend")
    func nemotron35Backend() {
        #expect(BackendOption.nemotron35Multilingual.backend == "nemotron35")
        #expect(BackendOption.nemotron35Multilingual.model.contains("Nemotron-3.5"))
        #expect(!BackendOption.nemotron35Multilingual.label.contains("Experimental"))
        #expect(!BackendOption.nemotron35Multilingual.recommended)
        #expect(!BackendOption.experimental.contains(.nemotron35Multilingual))
        #expect(BackendOption.streaming == [.nemotron35Multilingual])
        #expect(BackendOption.all.contains(.nemotron35Multilingual))
    }

    @Test("whisper alias points to parakeetMultilingual")
    func whisperAlias() {
        #expect(BackendOption.whisper == BackendOption.parakeetMultilingual)
    }

    @Test("all contains all defined options")
    func allContainsAll() {
        #expect(BackendOption.all.contains(.parakeetMultilingual))
        #expect(BackendOption.all.contains(.parakeetEnglish))
        #expect(BackendOption.all.contains(.whisperSmall))
        #expect(BackendOption.all.contains(.whisperMedium))
        #expect(BackendOption.all.contains(.whisperLargeTurbo))
        #expect(BackendOption.all.contains(.qwen3Asr))
        #expect(BackendOption.all.contains(.cohereTranscribe))
        #expect(BackendOption.all.contains(.indicASR))
        #expect(BackendOption.all.contains(.senseVoiceSmall))
        #expect(BackendOption.all.contains(.nemotron35Multilingual))
        #expect(BackendOption.all.contains(.gemma4E2BLiteRT))
    }

    @Test("Cohere uses cohere backend")
    func cohereBackend() {
        #expect(BackendOption.cohereTranscribe.backend == "cohere")
        #expect(BackendOption.cohereTranscribe.model.contains("cohere"))
    }

    @Test("Indic ASR uses indicasr backend")
    func indicASRBackend() {
        #expect(BackendOption.indicASR.backend == "indicasr")
        #expect(BackendOption.indicASR.model.contains("indic-conformer"))
    }

    @Test("Indic ASR chunk merge deduplicates Indic overlap")
    func indicASRChunkMergeDeduplicatesIndicOverlap() {
        let result = IndicASRTranscriptMerger.mergeOverlappingTranscripts([
            "मैं हिंदी में बोल सकता हूँ",
            "बोल सकता हूँ और तमिल भी",
            "தமிழ் கூட பேச முடியும்",
            "பேச முடியும் இப்போ",
        ])

        #expect(result == "मैं हिंदी में बोल सकता हूँ और तमिल भी தமிழ் கூட பேச முடியும் இப்போ")
    }

    @Test("Indic ASR chunk merge preserves non-overlapping text")
    func indicASRChunkMergePreservesNonOverlappingText() {
        let result = IndicASRTranscriptMerger.mergeOverlappingTranscripts([
            "நான் தமிழ் பேசுகிறேன்",
            "यह नया वाक्य है",
        ])

        #expect(result == "நான் தமிழ் பேசுகிறேன் यह नया वाक्य है")
    }

    @Test("Indic ASR mel transpose uses row-major vDSP parameter order")
    func indicASRMelTransposeParameterOrder() {
        let rows = 2
        let columns = 3
        let frameMajor: [Float] = [
            1, 2, 3,
            4, 5, 6,
        ]
        let expectedColumnMajorTranspose: [Float] = [
            1, 4,
            2, 5,
            3, 6,
        ]

        var actual = [Float](repeating: 0, count: frameMajor.count)
        vDSP_mtrans(
            frameMajor, 1,
            &actual, 1,
            vDSP_Length(columns),
            vDSP_Length(rows)
        )
        #expect(actual == expectedColumnMajorTranspose)

        var swapped = [Float](repeating: 0, count: frameMajor.count)
        vDSP_mtrans(
            frameMajor, 1,
            &swapped, 1,
            vDSP_Length(rows),
            vDSP_Length(columns)
        )
        #expect(swapped != expectedColumnMajorTranspose)
    }

    @Test("SenseVoice uses native FluidAudio CoreML model")
    func senseVoiceBackend() {
        #expect(BackendOption.senseVoiceSmall.backend == "sensevoice")
        #expect(BackendOption.senseVoiceSmall.model == "FluidInference/sensevoice-small-coreml")
        #expect(BackendOption.senseVoiceSmall.description.contains("FluidAudio"))
    }

    @Test("Gemma 4 E2B uses LiteRT-LM as an experimental managed model")
    func gemma4LiteRTBackend() {
        #expect(BackendOption.gemma4E2BLiteRT.backend == "gemma4-litert")
        #expect(BackendOption.gemma4E2BLiteRT.model == Gemma4LiteRTModelStore.repoID)
        #expect(BackendOption.gemma4E2BLiteRT.label == "Gemma 4 E2B")
        #expect(BackendOption.gemma4E2BLiteRT.sizeLabel == "~2.6 GB")
        #expect(BackendOption.gemma4E2BLiteRT.description.contains("LiteRT-LM"))
        #expect(BackendOption.gemma4E2BLiteRT.description.contains("Downloads managed local weights"))
        #expect(BackendOption.gemma4E2BLiteRT.description.contains("ASR-tuned Gemma artifact"))
        #expect(BackendOption.gemma4E2BLiteRT.description.contains("chat-style outputs fail closed"))
        #expect(BackendOption.experimental.contains(.gemma4E2BLiteRT))
        #expect(!BackendOption.onboarding.contains(.gemma4E2BLiteRT))
    }

    @Test("Cohere is not in experimental list")
    func cohereNotExperimental() {
        #expect(!BackendOption.experimental.contains(.cohereTranscribe))
    }

    @Test("onboarding offers the conservative models plus Nemotron 3.5")
    func onboardingModelChoices() {
        #expect(BackendOption.onboarding == [.parakeetMultilingual, .whisperTinyEnglish, .whisperSmall, .cohereTranscribe, .nemotron35Multilingual])
        for option in BackendOption.experimental {
            #expect(!BackendOption.onboarding.contains(option))
        }
        #expect(BackendOption.onboarding.contains(.nemotron35Multilingual))
    }

    @Test("only Nemotron backends use streaming dictation")
    func streamingDictationBackends() {
        let streaming = BackendOption.all.filter(\.isStreamingDictationBackend)
        #expect(streaming == [.nemotron35Multilingual])
    }

    @Test("meeting support is derived from explicit model capabilities")
    func meetingSupportUsesExplicitCapabilities() {
        #expect(BackendOption.nemotron35Multilingual.supportsMeetingTranscription)
        #expect(BackendOption.parakeetMultilingual.supportsMeetingTranscription)
        #expect(BackendOption.whisperLargeTurbo.supportsMeetingTranscription)
        #expect(!BackendOption.gemma4E2BLiteRT.supportsMeetingTranscription)
        #expect(!MeetingASRModelCatalog.parakeetRealtimeEOU.capabilities.supportsFullRecording)
    }

    @Test("meeting ASR catalog explicitly covers every backend")
    func meetingASRCatalogIsComplete() {
        let registeredBackendIDs = Set(
            MeetingASRModelCatalog.all
                .filter { $0.id != .parakeetRealtimeEOU }
                .map(\.id)
        )
        #expect(registeredBackendIDs == Set(BackendOption.allKnown.map(\.asrModelID)))
        #expect(MeetingASRModelCatalog.streamingLive.map(\.id) == [
            .parakeetRealtimeEOU,
            BackendOption.nemotron35Multilingual.asrModelID,
        ])
        #expect(MeetingASRModelCatalog.chunkedLive.contains {
            $0.id == BackendOption.whisperLargeTurbo.asrModelID
        })
        #expect(!MeetingASRModelCatalog.live.contains {
            $0.id == BackendOption.gemma4E2BLiteRT.asrModelID
        })
    }

    @Test("per-meeting Live selection does not mutate global configuration")
    func perMeetingLiveSelectionIsSessionLocal() {
        var config = AppConfig()
        config.meetingLiveEnabledByDefault = false
        config.meetingLiveModelBackend = ASRModelID.parakeetRealtimeEOU.backend
        config.meetingLiveModel = ASRModelID.parakeetRealtimeEOU.model
        let originalBackend = config.meetingLiveModelBackend
        let originalModel = config.meetingLiveModel
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = MeetingSession(
            meetingID: 1,
            title: "Test",
            calendarEventID: nil,
            backend: .whisperLargeTurbo,
            runtime: RuntimePaths(
                repoRoot: root,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            config: config,
            templateSnapshot: MeetingTemplates.auto.snapshot,
            transcriptionCoordinator: TranscriptionCoordinator(),
            processingSupportDirectory: root
        )

        #expect(session.selectLiveModel(BackendOption.whisperSmall.asrModelID))
        #expect(session.liveStateSnapshot().selection == BackendOption.whisperSmall.asrModelID)
        #expect(config.meetingLiveModelBackend == originalBackend)
        #expect(config.meetingLiveModel == originalModel)
        #expect(!config.meetingLiveEnabledByDefault)
    }

    @Test("stopping Live detaches immediately and preserves the per-meeting model")
    func liveStopDetachesImmediately() throws {
        let selected = BackendOption.whisperLargeTurbo.asrModelID
        let running = MeetingLiveRuntimeState(
            selection: selected,
            phase: .running,
            kind: .chunked,
            generation: 41,
            message: nil,
            droppedPreviewChunks: 2
        )

        let stopped = try #require(running.detachedAfterStopRequest())

        #expect(stopped.phase == .off)
        #expect(stopped.selection == selected)
        #expect(stopped.generation == 42)
        #expect(stopped.kind == nil)
        #expect(stopped.message == nil)
        #expect(stopped.droppedPreviewChunks == 0)
        #expect(stopped.detachedAfterStopRequest() == nil)
    }

    @Test("Whisper models use WhisperKit CoreML identifiers")
    func whisperKitModels() {
        // WhisperKit models use short variant names, not ggml- prefixed binaries
        #expect(BackendOption.whisperTinyEnglish.model == "tiny.en")
        #expect(BackendOption.whisperSmall.model == "small.en")
        #expect(BackendOption.whisperMedium.model == "medium.en")
        #expect(BackendOption.whisperLargeTurbo.model.contains("large"))
    }

    @Test("resolveDownloaded keeps selected downloaded meeting model")
    func resolveDownloadedKeepsSelectedDownloadedModel() {
        let resolved = BackendOption.resolveDownloaded(
            backend: BackendOption.whisperLargeTurbo.backend,
            model: BackendOption.whisperLargeTurbo.model,
            fallback: .parakeetMultilingual,
            downloadedOptions: [.parakeetMultilingual, .whisperLargeTurbo]
        )

        #expect(resolved == .whisperLargeTurbo)
    }

    @Test("resolveDownloaded falls back when selected meeting model is unavailable")
    func resolveDownloadedFallsBackWhenSelectedUnavailable() {
        let resolved = BackendOption.resolveDownloaded(
            backend: BackendOption.whisperLargeTurbo.backend,
            model: BackendOption.whisperLargeTurbo.model,
            fallback: .parakeetMultilingual,
            downloadedOptions: [.parakeetMultilingual, .whisperSmall]
        )

        #expect(resolved == .parakeetMultilingual)
    }

    @Test("resolveDownloaded uses first downloaded model when fallback is unavailable")
    func resolveDownloadedUsesFirstDownloadedWhenFallbackUnavailable() {
        let resolved = BackendOption.resolveDownloaded(
            backend: BackendOption.whisperLargeTurbo.backend,
            model: BackendOption.whisperLargeTurbo.model,
            fallback: .parakeetMultilingual,
            downloadedOptions: [.whisperSmall]
        )

        #expect(resolved == .whisperSmall)
    }
}

@Suite("Meeting processing metadata")
struct MeetingProcessingMetadataTests {
    @Test("thinking provenance round-trips and old JSON remains compatible")
    func thinkingProvenanceCodableCompatibility() throws {
        let aecDiagnostics = MeetingAecRunDiagnostics(
            processor: "localvqe_v1_2",
            ready: true,
            processedFrames: 1_000,
            fullReferenceFrames: 990,
            partialReferenceFrames: 10,
            missingReferenceFrames: 0,
            processingError: nil
        )
        let run = MeetingProcessingRunMetadata(
            completedAt: Date(timeIntervalSince1970: 123),
            durationSeconds: 34,
            backend: "ollama",
            model: "gemma4:26b-a4b-it-qat",
            displayName: "Ollama · gemma4:26b-a4b-it-qat",
            thinkingStatus: .used,
            audioSource: "raw_source_bundle",
            aecModel: "localvqe_v1_2",
            aecDiagnostics: aecDiagnostics
        )
        let decoded = try JSONDecoder().decode(
            MeetingProcessingRunMetadata.self,
            from: JSONEncoder().encode(run)
        )
        #expect(decoded == run)

        let legacyJSON = Data("""
        {
          "completedAt": 123,
          "durationSeconds": 34,
          "backend": "ollama",
          "model": "gemma4:26b-a4b-it-qat",
          "displayName": "Ollama"
        }
        """.utf8)
        let legacy = try JSONDecoder().decode(MeetingProcessingRunMetadata.self, from: legacyJSON)
        #expect(legacy.thinkingStatus == nil)
        #expect(legacy.audioSource == nil)
        #expect(legacy.aecModel == nil)
        #expect(legacy.aecDiagnostics == nil)

        let preUnitAggregationJSON = Data("""
        {
          "processor": "localvqe_v1_2",
          "ready": true,
          "processedFrames": 10,
          "fullReferenceFrames": 10,
          "partialReferenceFrames": 0,
          "missingReferenceFrames": 0
        }
        """.utf8)
        let preUnitAggregation = try JSONDecoder().decode(
            MeetingAecRunDiagnostics.self,
            from: preUnitAggregationJSON
        )
        #expect(preUnitAggregation.sourceUnitCount == 1)
        #expect(preUnitAggregation.appliedSourceUnitCount == 1)
    }

    @Test("transcription metadata records actual AEC outcomes across source units")
    func transcriptionMetadataAggregatesActualAEC() {
        let completedAt = Date(timeIntervalSince1970: 120)
        let run = MeetingProcessingMetadataFactory.transcription(
            backend: .parakeetMultilingual,
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: completedAt,
            audioSource: "raw_source_bundle",
            aecModel: "localvqe_v1_2",
            aecDiagnostics: [
                MeetingAecDiagnosticsSnapshot(
                    ready: true,
                    processor: "localvqe-v1.2",
                    processedFrames: 100,
                    fullReferenceFrames: 90,
                    partialReferenceFrames: 10,
                    missingReferenceFrames: 0,
                    systemSamplesReceived: 200,
                    micSamplesReceived: 200,
                    bufferedSystemSamples: 0,
                    bufferedMicSamples: 0,
                    currentDelayMs: 0,
                    delayHistory: [],
                    delaySkipHistory: [],
                    lastProcessingError: nil
                ),
                MeetingAecDiagnosticsSnapshot(
                    ready: false,
                    processor: "pass-through",
                    processedFrames: 25,
                    fullReferenceFrames: 0,
                    partialReferenceFrames: 0,
                    missingReferenceFrames: 25,
                    systemSamplesReceived: 0,
                    micSamplesReceived: 50,
                    bufferedSystemSamples: 0,
                    bufferedMicSamples: 0,
                    currentDelayMs: 0,
                    delayHistory: [],
                    delaySkipHistory: [],
                    lastProcessingError: "model unavailable"
                ),
            ]
        )

        #expect(run.completedAt == completedAt)
        #expect(run.durationSeconds == 20)
        #expect(run.audioSource == "raw_source_bundle")
        #expect(run.aecModel == "localvqe_v1_2")
        #expect(run.aecDiagnostics == MeetingAecRunDiagnostics(
            processor: "localvqe-v1.2+pass-through",
            ready: false,
            processedFrames: 125,
            fullReferenceFrames: 90,
            partialReferenceFrames: 10,
            missingReferenceFrames: 25,
            sourceUnitCount: 2,
            appliedSourceUnitCount: 1,
            processingError: "processing_failed"
        ))
    }

    @Test("a zero-frame source unit cannot hide behind another successful AEC unit")
    func transcriptionMetadataPreservesPartialApplication() {
        let snapshots = [
            MeetingAecDiagnosticsSnapshot(
                ready: true,
                processor: "localvqe_v1_2",
                processedFrames: 100,
                fullReferenceFrames: 100,
                partialReferenceFrames: 0,
                missingReferenceFrames: 0,
                systemSamplesReceived: 200,
                micSamplesReceived: 200,
                bufferedSystemSamples: 0,
                bufferedMicSamples: 0,
                currentDelayMs: 0,
                delayHistory: [],
                delaySkipHistory: [],
                lastProcessingError: nil
            ),
            MeetingAecDiagnosticsSnapshot(
                ready: true,
                processor: "localvqe_v1_2",
                processedFrames: 0,
                fullReferenceFrames: 0,
                partialReferenceFrames: 0,
                missingReferenceFrames: 0,
                systemSamplesReceived: 0,
                micSamplesReceived: 0,
                bufferedSystemSamples: 0,
                bufferedMicSamples: 0,
                currentDelayMs: 0,
                delayHistory: [],
                delaySkipHistory: [],
                lastProcessingError: nil
            ),
        ]

        let diagnostics = MeetingProcessingMetadataFactory.transcription(
            backend: .parakeetMultilingual,
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1),
            aecDiagnostics: snapshots
        ).aecDiagnostics

        #expect(diagnostics?.ready == true)
        #expect(diagnostics?.processedFrames == 100)
        #expect(diagnostics?.sourceUnitCount == 2)
        #expect(diagnostics?.appliedSourceUnitCount == 1)
        #expect(diagnostics?.processingError == nil)
    }
}

@Suite("PostProcessorOption")
struct PostProcessorOptionTests {

    @Test("all options have unique ids")
    func uniqueIDs() {
        let ids = PostProcessorOption.all.map(\.id)
        #expect(Set(ids).count == ids.count, "Duplicate id in PostProcessorOption.all")
    }

    @Test("all options have unique filenames")
    func uniqueFilenames() {
        let filenames = PostProcessorOption.all.map(\.filename)
        #expect(Set(filenames).count == filenames.count, "Duplicate filename in PostProcessorOption.all")
    }

    @Test("all options use HTTPS GGUF downloads")
    func validDownloadMetadata() {
        for option in PostProcessorOption.all {
            #expect(option.downloadURL.scheme == "https", "Non-HTTPS download URL for \(option.id)")
            #expect(option.filename.lowercased().hasSuffix(".gguf"), "Non-GGUF filename for \(option.id)")
            #expect(!option.label.isEmpty, "Empty label for \(option.id)")
            #expect(!option.description.isEmpty, "Empty description for \(option.id)")
            #expect(!option.sizeLabel.isEmpty, "Empty size label for \(option.id)")
        }
    }

    @Test("default option is first and matches config default")
    func defaultOption() {
        #expect(PostProcessorOption.all.first == PostProcessorOption.defaultOption)
        #expect(AppConfig().activePostProcessorId == PostProcessorOption.defaultOption.id)
    }

    @Test("unknown ids resolve to default")
    func unknownIDResolvesToDefault() {
        #expect(PostProcessorOption.resolve(id: "missing") == PostProcessorOption.defaultOption)
    }

    @Test("resolveDownloaded prefers selected downloaded option")
    func resolveDownloadedPrefersSelected() {
        let downloadedIDs: Set<String> = [
            PostProcessorOption.finetunedV2.id,
            PostProcessorOption.qwen35_0_8b.id,
        ]
        #expect(PostProcessorOption.resolveDownloaded(
            id: PostProcessorOption.qwen35_0_8b.id,
            downloadedIDs: downloadedIDs
        ) == PostProcessorOption.qwen35_0_8b)
    }

    @Test("resolveDownloaded falls back to first downloaded option")
    func resolveDownloadedFallsBack() {
        let downloadedIDs: Set<String> = [PostProcessorOption.finetunedV2.id]
        #expect(PostProcessorOption.resolveDownloaded(
            id: PostProcessorOption.finetunedV3.id,
            downloadedIDs: downloadedIDs
        ) == PostProcessorOption.finetunedV2)
    }

    @Test("runtimeOption prefers selected downloaded option")
    func runtimeOptionPrefersSelectedDownloadedOption() {
        let downloadedIDs: Set<String> = [
            PostProcessorOption.finetunedV2.id,
            PostProcessorOption.qwen35_0_8b.id,
        ]
        #expect(PostProcessorOption.runtimeOption(
            id: PostProcessorOption.qwen35_0_8b.id,
            downloadedIDs: downloadedIDs,
            hasDevOverride: false
        ) == PostProcessorOption.qwen35_0_8b)
    }

    @Test("runtimeOption falls back to first downloaded option")
    func runtimeOptionFallsBackToFirstDownloadedOption() {
        let downloadedIDs: Set<String> = [PostProcessorOption.finetunedV2.id]
        #expect(PostProcessorOption.runtimeOption(
            id: PostProcessorOption.finetunedV3.id,
            downloadedIDs: downloadedIDs,
            hasDevOverride: false
        ) == PostProcessorOption.finetunedV2)
    }

    @Test("runtimeOption accepts configured option with dev override")
    func runtimeOptionAcceptsConfiguredOptionWithDevOverride() {
        #expect(PostProcessorOption.runtimeOption(
            id: PostProcessorOption.finetunedV3.id,
            downloadedIDs: [],
            hasDevOverride: true
        ) == PostProcessorOption.finetunedV3)
    }

    @Test("runtimeOption returns nil without a download or dev override")
    func runtimeOptionReturnsNilWithoutDownloadOrDevOverride() {
        #expect(PostProcessorOption.runtimeOption(
            id: PostProcessorOption.finetunedV3.id,
            downloadedIDs: [],
            hasDevOverride: false
        ) == nil)
    }

    @Test("firstDownloaded respects deletion exclusion")
    func firstDownloadedExcludingDeleted() {
        let downloadedIDs: Set<String> = [
            PostProcessorOption.finetunedV3.id,
            PostProcessorOption.finetunedV2.id,
        ]
        #expect(PostProcessorOption.firstDownloaded(
            excluding: PostProcessorOption.finetunedV3.id,
            downloadedIDs: downloadedIDs
        ) == PostProcessorOption.finetunedV2)
    }
}

@Suite("TranscriptCleanupBackendOption")
struct TranscriptCleanupBackendOptionTests {

    @Test("Gemma 4 is no longer a cleanup backend")
    func gemma4IsNotACleanupBackend() {
        #expect(
            !TranscriptCleanupBackendOption.all.contains {
                $0.backend == BackendOption.gemma4E2BLiteRT.backend
            }
        )
        #expect(
            TranscriptCleanupBackendOption.resolved(BackendOption.gemma4E2BLiteRT.backend)
                == .local
        )
    }

    @Test("cleanup backends are all compatible with Gemma dictation")
    func cleanupBackendsCompatibleWithGemmaDictation() {
        for backend in TranscriptCleanupBackendOption.all {
            #expect(backend.isCompatible(with: .gemma4E2BLiteRT))
        }
    }
}

@Suite("SummaryModelPreset")
struct SummaryModelPresetTests {

    @Test("OpenAI presets have valid model IDs")
    func openAIModels() {
        #expect(!SummaryModelPreset.openAIModels.isEmpty)
        #expect(SummaryModelPreset.openAIModels.first?.id == "gpt-5.6-sol")
        #expect(SummaryModelPreset.openAIModels.contains { $0.id == "gpt-5.6-sol" })
        #expect(SummaryModelPreset.openAIModels.contains { $0.id == "gpt-5.6-terra" })
        #expect(SummaryModelPreset.openAIModels.contains { $0.id == "gpt-5.6-luna" })
        #expect(!SummaryModelPreset.openAIModels.contains { $0.id == "gpt-5.5" })
        #expect(SummaryModelPreset.openAIModels.contains { $0.id == "chat-latest" })
        for preset in SummaryModelPreset.openAIModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("ChatGPT presets include supported fast options")
    func chatGPTModels() {
        #expect(!SummaryModelPreset.chatGPTModels.isEmpty)
        #expect(SummaryModelPreset.chatGPTModels.first?.id == "gpt-5.6-sol")
        #expect(SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.6-sol" })
        #expect(SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.6-terra" })
        #expect(SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.6-luna" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.5" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.4-nano" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "chat-latest" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.4" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.2" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-4o" })
        for preset in SummaryModelPreset.chatGPTModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("ChatGPT transcript cleanup uses GPT-5.6 Terra by default")
    func chatGPTTranscriptCleanupModels() {
        let presets = SummaryModelPreset.chatGPTTranscriptCleanupModels
        #expect(presets.first?.id == "gpt-5.6-terra")
        #expect(presets.first?.label.contains("default") == true)
        #expect(Set(presets.map(\.id)) == Set([
            "gpt-5.4-mini",
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
        ]))

        let backend = TranscriptCleanupBackendOption.hosted(.chatGPT)
        #expect(TranscriptCleanupClient.defaultModel(for: backend) == "gpt-5.6-terra")
        #expect(TranscriptCleanupClient.configuredModel(for: backend, config: AppConfig()) == "gpt-5.6-terra")
    }

    @Test("OpenRouter presets have valid model IDs")
    func openRouterModels() {
        #expect(!SummaryModelPreset.openRouterModels.isEmpty)
        for preset in SummaryModelPreset.openRouterModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("Computer use planner presets use GPT-5.6 Sol by default")
    func computerUsePlannerModels() {
        #expect(SummaryModelPreset.computerUsePlannerModels.first?.id == "gpt-5.6-sol")
        #expect(SummaryModelPreset.computerUsePlannerModels.contains { $0.id == "gpt-5.6-terra" })
        #expect(SummaryModelPreset.computerUsePlannerModels.contains { $0.id == "gpt-5.6-luna" })
        #expect(SummaryModelPreset.computerUsePlannerModels.contains { $0.id == "gpt-5.4-mini" })
        #expect(!SummaryModelPreset.computerUsePlannerModels.contains { $0.id == "gpt-5.5" })
        for preset in SummaryModelPreset.computerUsePlannerModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("GPT-5.6 family uses fixed High reasoning")
    func gpt56ReasoningEffort() {
        #expect(SummaryModelPreset.reasoningEffort(for: "gpt-5.6-sol") == "high")
        #expect(SummaryModelPreset.reasoningEffort(for: "gpt-5.6-terra") == "high")
        #expect(SummaryModelPreset.reasoningEffort(for: "gpt-5.6-luna") == "high")
        #expect(SummaryModelPreset.reasoningEffort(for: "gpt-5.4-mini") == nil)
        #expect(SummaryModelPreset.reasoningEffort(for: "gpt-5.5") == nil)
    }

    @Test("model menu includes custom configured model")
    func modelMenuIncludesCustomConfiguredModel() {
        let customModel = "anthropic/claude-sonnet-4.5"
        let menuPresets = SummaryModelPreset.menuPresets(
            SummaryModelPreset.openRouterModels,
            currentModel: customModel
        )

        #expect(menuPresets.last?.id == customModel)
        #expect(menuPresets.last?.label == "Custom: \(customModel)")
    }

    @Test("model menu does not duplicate known models")
    func modelMenuDoesNotDuplicateKnownModels() {
        let knownModel = SummaryModelPreset.openRouterModels[0].id
        let menuPresets = SummaryModelPreset.menuPresets(
            SummaryModelPreset.openRouterModels,
            currentModel: knownModel
        )

        #expect(menuPresets.count == SummaryModelPreset.openRouterModels.count)
    }

    @Test("OpenRouter catalog filters free text generation models")
    func openRouterCatalogFiltersFreeTextModels() throws {
        let payload = """
        {
          "data": [
            {
              "id": "openrouter/free",
              "name": "Free Models Router",
              "context_length": 200000,
              "pricing": { "prompt": "0", "completion": "0", "request": "0" },
              "architecture": { "output_modalities": ["text"] }
            },
            {
              "id": "google/lyria-3-pro-preview",
              "name": "Google: Lyria 3 Pro Preview",
              "context_length": 1048576,
              "pricing": { "prompt": "0", "completion": "0" },
              "architecture": { "output_modalities": ["text", "audio"] }
            },
            {
              "id": "missing/architecture",
              "name": "Missing Architecture",
              "context_length": 200000,
              "pricing": { "prompt": "0", "completion": "0", "request": "0" }
            },
            {
              "id": "free/small-context",
              "name": "Free Small Context",
              "context_length": 99999,
              "pricing": { "prompt": "0", "completion": "0", "request": "0" },
              "architecture": { "output_modalities": ["text"] }
            },
            {
              "id": "paid/model",
              "name": "Paid Model",
              "context_length": 128000,
              "pricing": { "prompt": "0.000001", "completion": "0", "request": "0" },
              "architecture": { "output_modalities": ["text"] }
            },
            {
              "id": "unknown/pricing",
              "name": "Unknown Pricing",
              "context_length": 4096,
              "pricing": { "request": "0" },
              "architecture": { "output_modalities": ["text"] }
            },
            {
              "id": "free/image",
              "name": "Free Image",
              "context_length": 4096,
              "pricing": { "prompt": "0", "completion": "0", "request": "0" },
              "architecture": { "output_modalities": ["image"] }
            }
          ]
        }
        """.data(using: .utf8)!

        let catalog = try JSONDecoder().decode(OpenRouterModelCatalog.self, from: payload)
        let presets = OpenRouterModelCatalogFilter.freeTextSummaryPresets(from: catalog.data)

        #expect(presets.map(\.id) == ["openrouter/free"])
        #expect(presets[0].label == "Free Models Router (200k ctx)")
    }
}

@Suite("MeetingSummaryBackendOption")
struct MeetingSummaryBackendTests {

    @Test("all options listed")
    func allOptions() {
        #expect(MeetingSummaryBackendOption.all.count == 8)
        #expect(MeetingSummaryBackendOption.all.contains(.transcriptOnly))
        #expect(MeetingSummaryBackendOption.all.contains(.gemmaLocal))
        #expect(MeetingSummaryBackendOption.all.contains(.openAI))
        #expect(MeetingSummaryBackendOption.all.contains(.openRouter))
        #expect(MeetingSummaryBackendOption.all.contains(.chatGPT))
        #expect(MeetingSummaryBackendOption.all.contains(.ollama))
        #expect(MeetingSummaryBackendOption.all.contains(.lmStudio))
        #expect(MeetingSummaryBackendOption.all.contains(.customLLM))
    }

    @Test("backend strings are lowercase")
    func backendStrings() {
        #expect(MeetingSummaryBackendOption.openAI.backend == "openai")
        #expect(MeetingSummaryBackendOption.openRouter.backend == "openrouter")
        #expect(MeetingSummaryBackendOption.ollama.backend == "ollama")
        #expect(MeetingSummaryBackendOption.lmStudio.backend == "lmstudio")
        #expect(MeetingSummaryBackendOption.customLLM.backend == "custom_llm")
    }

    @Test("configured values resolve with transcript-only fallback")
    func resolvedValues() {
        #expect(MeetingSummaryBackendOption.resolved("chatgpt") == .chatGPT)
        #expect(MeetingSummaryBackendOption.resolved("openrouter") == .openRouter)
        #expect(MeetingSummaryBackendOption.resolved("ollama") == .ollama)
        #expect(MeetingSummaryBackendOption.resolved("lmstudio") == .lmStudio)
        #expect(MeetingSummaryBackendOption.resolved("custom_llm") == .customLLM)
        #expect(MeetingSummaryBackendOption.resolved("unknown") == .transcriptOnly)
        #expect(MeetingSummaryBackendOption.resolved(nil) == .transcriptOnly)
    }

    @Test("Custom LLM format labels")
    func customLLMFormatLabels() {
        #expect(CustomLLMFormat.openAI.label == "OpenAI-compatible")
        #expect(CustomLLMFormat.anthropic.label == "Anthropic Messages")
    }
}

@Suite("AppConfig")
struct AppConfigTests {

    @Test("default values")
    func defaults() {
        let config = AppConfig()
        #expect(config.sttBackend == BackendOption.whisper.backend)
        #expect(config.sttModel == BackendOption.whisper.model)
        #expect(config.meetingInputDeviceUID == nil)
        #expect(config.cohereLanguage == CohereTranscribeLanguage.defaultLanguage.rawValue)
        #expect(config.indicASRLanguage == IndicASRLanguage.defaultLanguage.rawValue)
        #expect(config.meetingTranscriptionBackend == BackendOption.whisper.backend)
        #expect(config.meetingTranscriptionModel == BackendOption.whisper.model)
        #expect(config.meetingSummaryBackend == MeetingSummaryBackendOption.gemmaLocal.backend)
        #expect(config.gemmaSummaryModel == GemmaSummaryModel.defaultModel.id)
        #expect(config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(config.meetingRecordingSavePolicy == .prompt)
        #expect(config.showScheduledMeetingNotifications == true)
        #expect(config.scheduledMeetingNotificationLeadTime == .atStart)
        #expect(config.showMeetingDetectionNotification == true)
        #expect(config.mutedMeetingDetectionAppBundleIDs.isEmpty)
        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.meetingRecordingFileFormat == MeetingRecordingFileFormat.m4a.rawValue)
        #expect(config.resolvedMeetingRecordingFileFormat == .m4a)
        #expect(config.meetingRecordingRetentionDays == 7)
        #expect(config.meetingAecModel == MeetingAecModel.localVQEV12.rawValue)
        #expect(config.resolvedMeetingAecModel == .localVQEV12)
        #expect(config.dictationRetentionHours == nil)
        #expect(config.openRouterAPIKey.isEmpty)
        #expect(config.meetingSummaryRetryCount == MeetingSummaryRetryPolicy.defaultRetryCount)
        #expect(config.ollamaURL == "http://localhost:11434")
        #expect(config.ollamaAPIKey.isEmpty)
        #expect(config.ollamaModel == "qwen3.5")
        #expect(config.lmStudioURL == "http://localhost:1234")
        #expect(config.lmStudioModel.isEmpty)
        #expect(config.customLLMURL.isEmpty)
        #expect(config.customLLMAPIKey.isEmpty)
        #expect(config.customLLMModel.isEmpty)
        #expect(config.customLLMFormat == "openai")
        #expect(config.postProcessorBackend == TranscriptCleanupBackendOption.local.backend)
        #expect(config.postProcessorChatGPTModel.isEmpty)
        #expect(config.postProcessorOpenAIModel.isEmpty)
        #expect(config.postProcessorOpenRouterModel.isEmpty)
        #expect(config.postProcessorOllamaModel.isEmpty)
        #expect(config.postProcessorLMStudioModel.isEmpty)
        #expect(config.postProcessorCustomLLMModel.isEmpty)
        #expect(config.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.defaultID)
        #expect(config.customTranscriptCleanupPrompts.isEmpty)
        #expect(config.enableScreenContext == false)
        #expect(config.enableDictationOCRContext == false)
        #expect(config.enableLiveStreamingPartials == false)
        #expect(config.resolvedMeetingLiveCaptionBackend == .parakeetRealtimeEOU)
        #expect(config.meetingLiveEnabledByDefault == false)
        #expect(config.resolvedMeetingLiveASRModelID == .parakeetRealtimeEOU)
        #expect(config.showMeetingTranscriptOnIndicatorHover == true)
        #expect(config.dictationHotkey == .default)
        #expect(config.computerUseHotkey == .computerUseDefault)
        #expect(config.enableComputerUseHotkey == false)
        #expect(config.computerUseHotkeyDefaultDisabledMigrationApplied == true)
        #expect(config.enableComputerUsePlanner == false)
        #expect(config.computerUsePlannerModel.isEmpty)
        #expect(config.computerUseTimeoutSeconds == 120)
        #expect(config.hotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds)
        #expect(config.computerUseHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds)
        #expect(config.meetingRecordingHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultMeetingThresholdMilliseconds)
        #expect(config.showFloatingIndicator == true)
        #expect(config.indicatorAnchor == .midTrailing)
        #expect(config.hasCompletedOnboarding == false)
        #expect(config.resolvedOnboardingUseCase == .dictationAndMeetings)
        #expect(config.userName.isEmpty)
        #expect(config.meetingSummarySystemPromptOverride == nil)
        #expect(config.meetingSummaryUserPromptOverride == nil)
        #expect(config.resolvedMeetingSummarySystemPrompt == MeetingSummaryPromptTemplates.defaultSystem)
        #expect(config.resolvedMeetingSummaryUserPrompt == MeetingSummaryPromptTemplates.defaultUser)
        #expect(config.builtInMeetingTemplateOverrides.isEmpty)
        #expect(config.customMeetingTemplates.isEmpty)
        #expect(config.meetingHookEnabled == false)
        #expect(config.meetingHookPath.isEmpty)
        #expect(config.meetingHookTimeoutSeconds == 30)
        #expect(config.autoExportMarkdownEnabled == false)
        #expect(config.autoExportMarkdownFolderPath.isEmpty)
        #expect(config.autoExportMarkdownContent == MeetingExportContent.notes.rawValue)
        #expect(config.resolvedAutoExportMarkdownContent == .notes)
        #expect(config.autoExportFileFormat == MeetingAutoExportFileFormat.markdown.rawValue)
        #expect(config.resolvedAutoExportFileFormat == .markdown)
        #expect(config.contributionPromptNextWordCount == nil)
        #expect(config.contributionPromptNextMeetingCount == nil)
        #expect(config.contributionGitHubStarClicked == false)
        #expect(config.contributionBuyMeCoffeeClicked == false)
        #expect(config.contributionTweetClicked == false)
        #expect(config.contributionLinkedInClicked == false)
        #expect(config.upcomingMeetingsDayCount == UpcomingMeetingsWindow.defaultDayCount)
        #expect(config.hiddenCalendarEventSourceHints.isEmpty)
    }

    @Test("Ollama authorization normalizes optional Bearer tokens")
    func ollamaAuthorization() {
        #expect(OllamaAuthorization.headerValue(for: "") == nil)
        #expect(OllamaAuthorization.headerValue(for: "   \n") == nil)
        #expect(OllamaAuthorization.headerValue(for: "secret-token") == "Bearer secret-token")
        #expect(OllamaAuthorization.headerValue(for: " bearer secret-token ") == "Bearer secret-token")
        #expect(OllamaAuthorization.headerValue(for: "Bearer   ") == nil)

        var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
        OllamaAuthorization.apply(configuredToken: "secret-token", to: &request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test("LM Studio cleanup readiness requires model and valid URL")
    func lmStudioCleanupReadinessRequiresModelAndValidURL() {
        let backend = TranscriptCleanupBackendOption.hosted(.lmStudio)
        var config = AppConfig()
        config.postProcessorLMStudioModel = "local-cleanup-model"
        config.lmStudioURL = "not a url"

        #expect(!TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.lmStudioURL = "http://localhost:1234"

        #expect(TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))
    }

    @Test("Ollama cleanup readiness requires valid URL")
    func ollamaCleanupReadinessRequiresValidURL() {
        let backend = TranscriptCleanupBackendOption.hosted(.ollama)
        var config = AppConfig()

        #expect(TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.ollamaURL = "not a url"

        #expect(!TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.ollamaURL = "http://localhost:11434"

        #expect(TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))
    }

    @Test("Custom LLM cleanup readiness requires model and explicit valid URL")
    func customLLMCleanupReadinessRequiresModelAndExplicitValidURL() {
        let backend = TranscriptCleanupBackendOption.hosted(.customLLM)
        var config = AppConfig()
        config.postProcessorCustomLLMModel = "cleanup-model"

        #expect(!TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.customLLMURL = "not a url"

        #expect(!TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.customLLMURL = "http://localhost:8080"

        #expect(TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.customLLMFormat = CustomLLMFormat.anthropic.rawValue
        config.customLLMAPIKey = ""

        #expect(!TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.customLLMAPIKey = "sk-ant-test"

        #expect(TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))
    }

    @Test("OpenRouter cleanup key falls back to environment")
    func openRouterCleanupKeyFallsBackToEnvironment() {
        var config = AppConfig()
        config.openRouterAPIKey = ""

        #expect(TranscriptCleanupClient.resolvedOpenRouterAPIKey(
            config: config,
            environment: ["OPENROUTER_API_KEY": "sk-or-env"]
        ) == "sk-or-env")

        config.openRouterAPIKey = " sk-or-config "

        #expect(TranscriptCleanupClient.resolvedOpenRouterAPIKey(
            config: config,
            environment: ["OPENROUTER_API_KEY": "sk-or-env"]
        ) == "sk-or-config")
    }

    @Test("JSON encode/decode round-trip")
    func jsonRoundTrip() throws {
        var config = AppConfig()
        config.openAIAPIKey = "sk-test-key-123"
        config.userName = "Test User"
        config.hasCompletedOnboarding = true
        config.onboardingUseCase = OnboardingUseCase.dictationAndMeetings.rawValue
        config.cohereLanguage = CohereTranscribeLanguage.german.rawValue
        config.indicASRLanguage = IndicASRLanguage.tamil.rawValue
        config.defaultMeetingTemplateID = "weekly-team-meeting"
        config.meetingRecordingSavePolicy = .always
        config.meetingRecordingFileFormat = MeetingRecordingFileFormat.wav.rawValue
        config.meetingRecordingRetentionDays = 30
        config.meetingAecModel = MeetingAecModel.localVQEV12.rawValue
        config.dictationRetentionHours = 12
        config.builtInMeetingTemplateOverrides = [
            BuiltInMeetingTemplateOverride(
                id: "one-to-one",
                prompt: "## My 1:1 Notes"
            )
        ]
        config.customMeetingTemplates = [
            CustomMeetingTemplate(
                id: "tmpl_123",
                name: "Customer Follow-Up",
                prompt: "## Summary",
                icon: "dollarsign.circle"
            )
        ]
        config.meetingHookEnabled = true
        config.meetingHookPath = "/tmp/meeting-hook.sh"
        config.meetingHookTimeoutSeconds = 45
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = "/tmp/muesli-auto-export"
        config.autoExportMarkdownContent = MeetingExportContent.fullMeeting.rawValue
        config.autoExportFileFormat = MeetingAutoExportFileFormat.markdownAndPDF.rawValue
        config.showScheduledMeetingNotifications = false
        config.scheduledMeetingNotificationLeadTime = .threeMinutes
        config.showMeetingDetectionNotification = false
        config.mutedMeetingDetectionAppBundleIDs = ["com.google.Chrome", "com.tinyspeck.slackmacgap"]
        config.computerUseHotkey = HotkeyConfig(keyCode: 62, label: "Right Ctrl")
        config.enableComputerUseHotkey = false
        config.enableComputerUsePlanner = false
        config.computerUsePlannerModel = "gpt-5.4"
        config.computerUseTimeoutSeconds = 180
        config.hotkeyTriggerThresholdMS = 125
        config.computerUseHotkeyTriggerThresholdMS = 350
        config.meetingRecordingHotkeyTriggerThresholdMS = 900
        config.lmStudioURL = "http://localhost:1234"
        config.lmStudioModel = "local-model"
        config.customLLMURL = "https://example.com"
        config.customLLMAPIKey = "custom-key"
        config.customLLMModel = "custom-model"
        config.customLLMFormat = "anthropic"
        config.meetingSummaryRetryCount = 5
        config.ollamaAPIKey = "ollama-secret"
        config.meetingSummarySystemPromptOverride = "Custom system {{template}}"
        config.meetingSummaryUserPromptOverride = "{{meeting_title}}\n{{transcript}}"
        config.setMeetingSummaryGenerationSettings(
            SummaryGenerationSettings(
                maxOutputTokens: 4_000,
                contextTokens: 32_768,
                timeoutSeconds: 600,
                temperature: 0.2,
                topP: 0.9
            ),
            backend: .ollama,
            model: "gemma4:26b"
        )
        config.postProcessorBackend = TranscriptCleanupBackendOption.hosted(.openRouter).backend
        config.postProcessorChatGPTModel = "gpt-5.4-mini"
        config.postProcessorOpenAIModel = "gpt-5.4-mini"
        config.postProcessorOpenRouterModel = "openrouter/test-model"
        config.postProcessorOllamaModel = "qwen3.5"
        config.postProcessorLMStudioModel = "lmstudio-loaded"
        config.postProcessorCustomLLMModel = "custom-cleanup"
        config.activeTranscriptCleanupPromptId = "cleanup_custom_1"
        config.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(
                id: "cleanup_custom_1",
                name: "Strict Dictation",
                prompt: "Preserve labels and quotes."
            )
        ]
        config.postProcessorSystemPrompt = "Preserve labels and quotes."
        config.enableScreenContext = true
        config.enableDictationOCRContext = true
        config.meetingLiveEnabledByDefault = true
        config.meetingInputDeviceUID = "meeting-mic"
        config.enableAutomaticDiagnosticIssuePrompts = true
        config.meetingLiveModelBackend = BackendOption.nemotron35Multilingual.backend
        config.meetingLiveModel = BackendOption.nemotron35Multilingual.model
        config.synchronizeLegacyMeetingLiveSettings()
        config.showMeetingTranscriptOnIndicatorHover = false
        config.contributionPromptNextWordCount = 31_000
        config.contributionPromptNextMeetingCount = 75
        config.contributionGitHubStarClicked = true
        config.contributionBuyMeCoffeeClicked = false
        config.contributionTweetClicked = true
        config.contributionLinkedInClicked = false
        config.upcomingMeetingsDayCount = UpcomingMeetingsWindow.today.dayCount
        config.hiddenCalendarEventSourceHints = [
            "ek-event-1": UnifiedCalendarEvent.CalendarSource.eventKit.rawValue,
            "google-event-1": UnifiedCalendarEvent.CalendarSource.googleCalendar.rawValue,
        ]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.openAIAPIKey == "sk-test-key-123")
        #expect(decoded.userName == "Test User")
        #expect(decoded.hasCompletedOnboarding == true)
        #expect(decoded.resolvedOnboardingUseCase == .dictationAndMeetings)
        #expect(decoded.cohereLanguage == CohereTranscribeLanguage.german.rawValue)
        #expect(decoded.indicASRLanguage == IndicASRLanguage.tamil.rawValue)
        #expect(decoded.defaultMeetingTemplateID == "weekly-team-meeting")
        #expect(decoded.meetingRecordingSavePolicy == .always)
        #expect(decoded.meetingRecordingFileFormat == MeetingRecordingFileFormat.wav.rawValue)
        #expect(decoded.resolvedMeetingRecordingFileFormat == .wav)
        #expect(decoded.meetingRecordingRetentionDays == 30)
        #expect(decoded.resolvedMeetingAecModel == .localVQEV12)
        #expect(decoded.dictationRetentionHours == 12)
        #expect(decoded.builtInMeetingTemplateOverrides.count == 1)
        #expect(decoded.builtInMeetingTemplateOverrides.first?.id == "one-to-one")
        #expect(decoded.builtInMeetingTemplateOverrides.first?.prompt == "## My 1:1 Notes")
        #expect(decoded.customMeetingTemplates.count == 1)
        #expect(decoded.customMeetingTemplates.first?.name == "Customer Follow-Up")
        #expect(decoded.customMeetingTemplates.first?.icon == "dollarsign.circle")
        #expect(decoded.meetingHookEnabled == true)
        #expect(decoded.meetingHookPath == "/tmp/meeting-hook.sh")
        #expect(decoded.meetingHookTimeoutSeconds == 45)
        #expect(decoded.autoExportMarkdownEnabled == true)
        #expect(decoded.autoExportMarkdownFolderPath == "/tmp/muesli-auto-export")
        #expect(decoded.autoExportMarkdownContent == MeetingExportContent.fullMeeting.rawValue)
        #expect(decoded.resolvedAutoExportMarkdownContent == .fullMeeting)
        #expect(decoded.autoExportFileFormat == MeetingAutoExportFileFormat.markdownAndPDF.rawValue)
        #expect(decoded.resolvedAutoExportFileFormat == .markdownAndPDF)
        #expect(decoded.showScheduledMeetingNotifications == false)
        #expect(decoded.scheduledMeetingNotificationLeadTime == .threeMinutes)
        #expect(decoded.showMeetingDetectionNotification == false)
        #expect(decoded.mutedMeetingDetectionAppBundleIDs == ["com.google.Chrome", "com.tinyspeck.slackmacgap"])
        #expect(decoded.meetingTranscriptionBackend == config.meetingTranscriptionBackend)
        #expect(decoded.indicatorAnchor == config.indicatorAnchor)
        #expect(decoded.computerUseHotkey == HotkeyConfig(keyCode: 62, label: "Right Ctrl"))
        #expect(decoded.enableComputerUseHotkey == false)
        #expect(decoded.enableComputerUsePlanner == false)
        #expect(decoded.computerUsePlannerModel == "gpt-5.4")
        #expect(decoded.computerUseTimeoutSeconds == 180)
        #expect(decoded.hotkeyTriggerThresholdMS == 125)
        #expect(decoded.computerUseHotkeyTriggerThresholdMS == 350)
        #expect(decoded.meetingRecordingHotkeyTriggerThresholdMS == 900)
        #expect(decoded.lmStudioURL == "http://localhost:1234")
        #expect(decoded.lmStudioModel == "local-model")
        #expect(decoded.customLLMURL == "https://example.com")
        #expect(decoded.customLLMAPIKey == "custom-key")
        #expect(decoded.customLLMModel == "custom-model")
        #expect(decoded.customLLMFormat == "anthropic")
        #expect(decoded.meetingSummaryRetryCount == 5)
        #expect(decoded.ollamaAPIKey == "ollama-secret")
        #expect(decoded.meetingSummarySystemPromptOverride == "Custom system {{template}}")
        #expect(decoded.meetingSummaryUserPromptOverride == "{{meeting_title}}\n{{transcript}}")
        #expect(decoded.meetingSummaryGenerationOverrides.count == 1)
        #expect(
            decoded.meetingSummaryGenerationSettings(backend: .ollama, model: "gemma4:26b")
                == SummaryGenerationSettings(
                    maxOutputTokens: 4_000,
                    contextTokens: 32_768,
                    timeoutSeconds: 600,
                    temperature: 0.2,
                    topP: 0.9
                )
        )
        #expect(decoded.postProcessorBackend == "openrouter")
        #expect(decoded.postProcessorChatGPTModel == "gpt-5.4-mini")
        #expect(decoded.postProcessorOpenAIModel == "gpt-5.4-mini")
        #expect(decoded.postProcessorOpenRouterModel == "openrouter/test-model")
        #expect(decoded.postProcessorOllamaModel == "qwen3.5")
        #expect(decoded.postProcessorLMStudioModel == "lmstudio-loaded")
        #expect(decoded.postProcessorCustomLLMModel == "custom-cleanup")
        #expect(decoded.activeTranscriptCleanupPromptId == "cleanup_custom_1")
        #expect(decoded.customTranscriptCleanupPrompts.count == 1)
        #expect(decoded.customTranscriptCleanupPrompts.first?.name == "Strict Dictation")
        #expect(decoded.postProcessorSystemPrompt == "Preserve labels and quotes.")
        #expect(decoded.enableScreenContext == true)
        #expect(decoded.enableDictationOCRContext == true)
        #expect(decoded.enableLiveStreamingPartials == true)
        #expect(decoded.meetingLiveEnabledByDefault == true)
        #expect(decoded.resolvedMeetingLiveASRModelID == BackendOption.nemotron35Multilingual.asrModelID)
        #expect(decoded.meetingInputDeviceUID == "meeting-mic")
        #expect(decoded.enableAutomaticDiagnosticIssuePrompts == true)
        #expect(decoded.resolvedMeetingLiveCaptionBackend == .nemotron35)
        #expect(decoded.showMeetingTranscriptOnIndicatorHover == false)
        #expect(decoded.contributionPromptNextWordCount == 31_000)
        #expect(decoded.contributionPromptNextMeetingCount == 75)
        #expect(decoded.contributionGitHubStarClicked == true)
        #expect(decoded.contributionBuyMeCoffeeClicked == false)
        #expect(decoded.contributionTweetClicked == true)
        #expect(decoded.contributionLinkedInClicked == false)
        #expect(decoded.upcomingMeetingsDayCount == UpcomingMeetingsWindow.today.dayCount)
        #expect(decoded.hiddenCalendarEventSourceHints == config.hiddenCalendarEventSourceHints)
    }

    @Test("summary generation settings are isolated per backend and model")
    func summaryGenerationSettingsArePerModel() {
        var config = AppConfig()
        config.setMeetingSummaryGenerationSettings(
            SummaryGenerationSettings(maxOutputTokens: 5_000),
            backend: .openAI,
            model: "gpt-5.6-sol"
        )
        config.setMeetingSummaryGenerationSettings(
            SummaryGenerationSettings(contextTokens: 32_768, timeoutSeconds: 600),
            backend: .ollama,
            model: "gemma4:26b"
        )

        #expect(
            config.meetingSummaryGenerationSettings(backend: .openAI, model: "gpt-5.6-sol")
                .maxOutputTokens == 5_000
        )
        #expect(
            config.meetingSummaryGenerationSettings(backend: .ollama, model: "gemma4:26b")
                .contextTokens == 32_768
        )
        #expect(
            config.meetingSummaryGenerationSettings(backend: .openAI, model: "gpt-5.4-mini")
                .isEmpty
        )

        config.setMeetingSummaryGenerationSettings(
            SummaryGenerationSettings(),
            backend: .openAI,
            model: "gpt-5.6-sol"
        )

        #expect(config.meetingSummaryGenerationOverrides.count == 1)
        #expect(
            config.meetingSummaryGenerationSettings(backend: .openAI, model: "gpt-5.6-sol")
                .isEmpty
        )
    }

    @Test("Automatic diagnostic issue prompts default off when absent")
    func automaticDiagnosticIssuePromptsDefaultOffWhenAbsent() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))

        #expect(decoded.enableAutomaticDiagnosticIssuePrompts == false)
    }

    @Test("JSON coding keys use snake_case")
    func snakeCaseKeys() throws {
        var config = AppConfig()
        config.contributionPromptNextWordCount = 1_000
        config.contributionPromptNextMeetingCount = 25
        config.meetingSummarySystemPromptOverride = "System {{template}}"
        config.meetingSummaryUserPromptOverride = "{{meeting_title}} {{transcript}}"
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["stt_backend"] != nil)
        #expect(json["stt_model"] != nil)
        #expect(json["computer_use_hotkey"] != nil)
        #expect(json["enable_computer_use_hotkey"] != nil)
        #expect(json["computer_use_hotkey_default_disabled_migration_applied"] != nil)
        #expect(json["enable_computer_use_planner"] != nil)
        #expect(json["computer_use_planner_model"] != nil)
        #expect(json["computer_use_timeout_seconds"] != nil)
        #expect(json["hotkey_trigger_threshold_ms"] != nil)
        #expect(json["computer_use_hotkey_trigger_threshold_ms"] != nil)
        #expect(json["meeting_recording_hotkey_trigger_threshold_ms"] != nil)
        #expect(json["cohere_language"] != nil)
        #expect(json["indic_asr_language"] != nil)
        #expect(json["meeting_transcription_backend"] != nil)
        #expect(json["meeting_transcription_model"] != nil)
        #expect(json["indicator_anchor"] != nil)
        #expect(json["has_completed_onboarding"] != nil)
        #expect(json["onboarding_use_case"] != nil)
        #expect(json["user_name"] != nil)
        #expect(json["meeting_summary_system_prompt_override"] != nil)
        #expect(json["meeting_summary_user_prompt_override"] != nil)
        #expect(json["default_meeting_template_id"] != nil)
        #expect(json["meeting_recording_save_policy"] != nil)
        #expect(json["meeting_recording_file_format"] != nil)
        #expect(json["meeting_aec_model"] != nil)
        #expect(json["show_scheduled_meeting_notifications"] != nil)
        #expect(json["show_meeting_detection_notification"] != nil)
        #expect(json["muted_meeting_detection_app_bundle_ids"] != nil)
        #expect(json["custom_meeting_templates"] != nil)
        #expect(json["meeting_hook_enabled"] != nil)
        #expect(json["meeting_hook_path"] != nil)
        #expect(json["meeting_hook_timeout_seconds"] != nil)
        #expect(json["auto_export_markdown_enabled"] != nil)
        #expect(json["auto_export_markdown_folder_path"] != nil)
        #expect(json["auto_export_markdown_content"] != nil)
        #expect(json["auto_export_file_format"] != nil)
        #expect(json["contribution_prompt_next_word_count"] != nil)
        #expect(json["contribution_prompt_next_meeting_count"] != nil)
        #expect(json["contribution_github_star_clicked"] != nil)
        #expect(json["contribution_buy_me_coffee_clicked"] != nil)
        #expect(json["contribution_tweet_clicked"] != nil)
        #expect(json["contribution_linkedin_clicked"] != nil)
        #expect(json["lmstudio_url"] != nil)
        #expect(json["lmstudio_model"] != nil)
        #expect(json["custom_llm_url"] != nil)
        #expect(json["custom_llm_api_key"] != nil)
        #expect(json["custom_llm_model"] != nil)
        #expect(json["custom_llm_format"] != nil)
        #expect(json["meeting_summary_retry_count"] != nil)
        #expect(json["meeting_summary_generation_overrides"] != nil)
        #expect(json["ollama_api_key"] != nil)
        #expect(json["post_processor_backend"] != nil)
        #expect(json["post_processor_chatgpt_model"] != nil)
        #expect(json["post_processor_openai_model"] != nil)
        #expect(json["post_processor_openrouter_model"] != nil)
        #expect(json["post_processor_ollama_model"] != nil)
        #expect(json["post_processor_lmstudio_model"] != nil)
        #expect(json["post_processor_custom_llm_model"] != nil)
        #expect(json["active_transcript_cleanup_prompt_id"] != nil)
        #expect(json["custom_transcript_cleanup_prompts"] != nil)
        #expect(json["enable_screen_context"] != nil)
        #expect(json["enable_dictation_ocr_context"] != nil)
        #expect(json["enable_live_streaming_partials"] != nil)
        #expect(json["meeting_live_enabled_by_default"] != nil)
        #expect(json["meeting_live_model_backend"] != nil)
        #expect(json["meeting_live_model"] != nil)
        #expect(json["show_meeting_transcript_on_indicator_hover"] != nil)
    }

    @Test("decodes screen context flags from snake_case")
    func decodesScreenContextFlagsFromSnakeCase() throws {
        let json = """
        {
            "enable_screen_context": true,
            "enable_dictation_ocr_context": true
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.enableScreenContext == true)
        #expect(config.enableDictationOCRContext == true)
    }

    @Test("decodes with missing fields using defaults")
    func missingFieldsUseDefaults() throws {
        let json = "{\"stt_backend\": \"whisper\"}"
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.showFloatingIndicator == true)
        #expect(config.resolvedCohereLanguage == .english)
        #expect(config.resolvedIndicASRLanguage == .defaultLanguage)
        #expect(config.hasCompletedOnboarding == false)
        #expect(config.resolvedOnboardingUseCase == .dictationAndMeetings)
        #expect(config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(config.upcomingMeetingsDayCount == UpcomingMeetingsWindow.threeDays.dayCount)
        #expect(config.hiddenCalendarEventSourceHints.isEmpty)
        #expect(config.meetingRecordingSavePolicy == .prompt)
        #expect(config.meetingRecordingFileFormat == MeetingRecordingFileFormat.m4a.rawValue)
        #expect(config.resolvedMeetingRecordingFileFormat == .m4a)
        #expect(config.meetingRecordingRetentionDays == 7)
        #expect(config.resolvedMeetingAecModel == .localVQEV12)
        #expect(config.dictationRetentionHours == nil)
        #expect(config.showScheduledMeetingNotifications == true)
        #expect(config.showMeetingDetectionNotification == true)
        #expect(config.mutedMeetingDetectionAppBundleIDs.isEmpty)
        #expect(config.customMeetingTemplates.isEmpty)
        #expect(config.computerUseHotkey == .computerUseDefault)
        #expect(config.enableComputerUseHotkey == false)
        #expect(config.computerUseHotkeyDefaultDisabledMigrationApplied == true)
        #expect(config.enableComputerUsePlanner == false)
        #expect(config.computerUsePlannerModel.isEmpty)
        #expect(config.computerUseTimeoutSeconds == 120)
        #expect(config.hotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds)
        #expect(config.computerUseHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds)
        #expect(config.meetingRecordingHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultMeetingThresholdMilliseconds)
        #expect(config.meetingHookEnabled == false)
        #expect(config.meetingHookPath.isEmpty)
        #expect(config.meetingHookTimeoutSeconds == 30)
        #expect(config.autoExportMarkdownEnabled == false)
        #expect(config.autoExportMarkdownFolderPath.isEmpty)
        #expect(config.autoExportMarkdownContent == MeetingExportContent.notes.rawValue)
        #expect(config.resolvedAutoExportMarkdownContent == .notes)
        #expect(config.autoExportFileFormat == MeetingAutoExportFileFormat.markdown.rawValue)
        #expect(config.resolvedAutoExportFileFormat == .markdown)
        #expect(config.lmStudioURL == "http://localhost:1234")
        #expect(config.lmStudioModel.isEmpty)
        #expect(config.customLLMURL.isEmpty)
        #expect(config.customLLMAPIKey.isEmpty)
        #expect(config.customLLMModel.isEmpty)
        #expect(config.customLLMFormat == "openai")
        #expect(config.meetingSummaryRetryCount == MeetingSummaryRetryPolicy.defaultRetryCount)
        #expect(config.postProcessorBackend == TranscriptCleanupBackendOption.local.backend)
        #expect(config.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.defaultID)
        #expect(config.customTranscriptCleanupPrompts.isEmpty)
        #expect(config.enableScreenContext == false)
        #expect(config.enableDictationOCRContext == false)
        #expect(config.enableLiveStreamingPartials == false)
        #expect(config.resolvedMeetingLiveCaptionBackend == .parakeetRealtimeEOU)
        #expect(config.showMeetingTranscriptOnIndicatorHover == true)
    }

    @Test("legacy meeting config preserves its transcription model and leaves streaming off")
    func legacyMeetingConfigPreservesTranscriptionModel() throws {
        let json = """
        {
          "stt_backend": "fluidaudio",
          "stt_model": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
          "has_completed_onboarding": true,
          "onboarding_use_case": "meetings"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.sttBackend == BackendOption.parakeetMultilingual.backend)
        #expect(config.sttModel == BackendOption.parakeetMultilingual.model)
        #expect(config.meetingTranscriptionBackend == BackendOption.parakeetMultilingual.backend)
        #expect(config.meetingTranscriptionModel == BackendOption.parakeetMultilingual.model)
        #expect(config.enableLiveStreamingPartials == false)
        #expect(config.meetingLiveEnabledByDefault == false)
        #expect(config.resolvedMeetingLiveASRModelID == .parakeetRealtimeEOU)
    }

    @Test("legacy live settings migrate to independent live defaults")
    func legacyLiveSettingsMigrateToIndependentDefaults() throws {
        let json = """
        {
          "enable_live_streaming_partials": true,
          "meeting_live_caption_backend": "nemotron35"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.meetingLiveEnabledByDefault == true)
        #expect(config.resolvedMeetingLiveASRModelID == BackendOption.nemotron35Multilingual.asrModelID)
        #expect(config.enableLiveStreamingPartials == true)
        #expect(config.resolvedMeetingLiveCaptionBackend == .nemotron35)
    }

    @Test("independent chunked live selection disables the unrepresentable legacy mode")
    func chunkedLiveSelectionIsDowngradeSafe() {
        var config = AppConfig()
        config.meetingLiveEnabledByDefault = true
        config.meetingLiveModelBackend = BackendOption.whisperLargeTurbo.backend
        config.meetingLiveModel = BackendOption.whisperLargeTurbo.model

        config.synchronizeLegacyMeetingLiveSettings()

        #expect(config.meetingLiveEnabledByDefault == true)
        #expect(config.resolvedMeetingLiveASRModelID == BackendOption.whisperLargeTurbo.asrModelID)
        #expect(config.enableLiveStreamingPartials == false)
    }

    @Test("independent live keys take precedence over legacy keys")
    func independentLiveKeysTakePrecedence() throws {
        let json = """
        {
          "enable_live_streaming_partials": true,
          "meeting_live_caption_backend": "nemotron35",
          "meeting_live_enabled_by_default": true,
          "meeting_live_model_backend": "whisper",
          "meeting_live_model": "large-v3-v20240930_626MB"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.meetingLiveEnabledByDefault == true)
        #expect(config.resolvedMeetingLiveASRModelID == BackendOption.whisperLargeTurbo.asrModelID)
        #expect(config.enableLiveStreamingPartials == false)
    }

    @Test("meeting summary retry count is clamped on decode")
    func meetingSummaryRetryCountIsClampedOnDecode() throws {
        let negativeConfig = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"meeting_summary_retry_count": -3}"#.utf8)
        )
        let excessiveConfig = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"meeting_summary_retry_count": 99}"#.utf8)
        )

        #expect(negativeConfig.meetingSummaryRetryCount == 0)
        #expect(excessiveConfig.meetingSummaryRetryCount == MeetingSummaryRetryPolicy.maximumRetryCount)
    }

    @Test("unknown cleanup backend resolves to local")
    func unknownCleanupBackendResolvesToLocal() throws {
        let json = """
        {
          "post_processor_backend": "future_provider"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.postProcessorBackend == TranscriptCleanupBackendOption.local.backend)
        #expect(TranscriptCleanupBackendOption.resolved(config.postProcessorBackend) == .local)
    }

    @Test("missing cleanup prompt preset falls back to built-in default")
    func missingCleanupPromptPresetFallsBackToDefault() throws {
        let json = """
        {
          "active_transcript_cleanup_prompt_id": "deleted-preset",
          "post_processor_system_prompt": "Legacy user-edited cleanup prompt"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.defaultID)
        #expect(config.postProcessorSystemPrompt == PostProcessorOption.defaultSystemPrompt)
        #expect(
            TranscriptCleanupPrompts
                .resolve(id: config.activeTranscriptCleanupPromptId, custom: config.customTranscriptCleanupPrompts)
                .prompt == PostProcessorOption.defaultSystemPrompt
        )
    }

    @Test("default cleanup prompt explains app context")
    func defaultCleanupPromptExplainsAppContext() {
        #expect(PostProcessorOption.defaultSystemPrompt.contains("<APP-CONTEXT>"))
        #expect(PostProcessorOption.defaultSystemPrompt.contains("OCR screen text"))
        #expect(PostProcessorOption.defaultSystemPrompt.contains("Never copy app context into the output"))
    }

    @Test("dictation app context prompt includes OCR text")
    func dictationAppContextPromptIncludesOCRText() {
        let ocrText = String(repeating: "a", count: 3_200) + "tail"
        let context = DictationContext(
            appName: "Notes",
            bundleID: "com.apple.Notes",
            documentContext: "Project Apollo",
            selectedText: "Mercury",
            url: "https://example.com",
            ocrText: ocrText
        )
        let prompt = DictationContextCapture.formatForPrompt(context)

        #expect(prompt.contains("App: Notes (https://example.com)"))
        #expect(prompt.contains("Document context: Project Apollo"))
        #expect(prompt.contains("Selected text: Mercury"))
        #expect(prompt.contains("OCR screen text: "))
        #expect(prompt.contains("tail"))
    }

    @Test("post processor input caps app context")
    func postProcessorInputCapsAppContext() {
        let prompt = Qwen3PostProcessorConfig.formatInput(
            "hello",
            appContext: String(repeating: "a", count: 20),
            maxAppContextCharacters: 5
        )

        #expect(prompt.contains("<APP-CONTEXT>\naaaaa\n</APP-CONTEXT>"))
        #expect(prompt.contains("<USER-INPUT>\nhello\n</USER-INPUT>"))
    }

    @Test("hosted cleanup augments custom prompts when app context is present")
    func hostedCleanupAugmentsCustomPromptsWhenAppContextIsPresent() {
        let prompt = TranscriptCleanupClient.systemPromptWithAppContextGuidance(
            "Preserve the user's words.",
            appContext: "App: Notes"
        )

        #expect(prompt.contains("Preserve the user's words."))
        #expect(prompt.contains("<APP-CONTEXT>"))
        #expect(prompt.contains("OCR screen text"))
    }

    @Test("hosted cleanup does not duplicate app context guidance")
    func hostedCleanupDoesNotDuplicateAppContextGuidance() {
        let prompt = TranscriptCleanupClient.systemPromptWithAppContextGuidance(
            PostProcessorOption.defaultSystemPrompt,
            appContext: "App: Notes"
        )

        #expect(prompt == PostProcessorOption.defaultSystemPrompt)
    }

    @Test("unsupported ChatGPT model selections fall back to default")
    func unsupportedChatGPTModelSelectionsFallBackToDefault() throws {
        let json = """
        {
          "chatgpt_model": "chat-latest",
          "post_processor_chatgpt_model": "gpt-5.4-nano"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.chatGPTModel.isEmpty)
        #expect(config.postProcessorChatGPTModel.isEmpty)
    }

    @Test("stored GPT-5.5 selections migrate to GPT-5.6 Sol")
    func storedGPT55SelectionsMigrateToSol() throws {
        let json = """
        {
          "computer_use_planner_model": "gpt-5.5",
          "openai_model": "gpt-5.5",
          "chatgpt_model": "gpt-5.5",
          "post_processor_openai_model": "gpt-5.5",
          "post_processor_chatgpt_model": "gpt-5.5"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.computerUsePlannerModel == "gpt-5.6-sol")
        #expect(config.openAIModel == "gpt-5.6-sol")
        #expect(config.chatGPTModel == "gpt-5.6-sol")
        #expect(config.postProcessorOpenAIModel == "gpt-5.6-sol")
        #expect(config.postProcessorChatGPTModel == "gpt-5.6-sol")
    }

    @Test("legacy completed onboarding enables meetings when use case is missing")
    func legacyCompletedOnboardingEnablesMeetingsWhenUseCaseMissing() throws {
        let json = """
        {
          "has_completed_onboarding": true,
          "stt_backend": "fluidaudio",
          "stt_model": "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.hasCompletedOnboarding)
        #expect(config.resolvedOnboardingUseCase == .dictationAndMeetings)
        #expect(config.resolvedOnboardingUseCase.includesMeetings)
    }

    @Test("legacy completed onboarding enables meetings when use case is malformed")
    func legacyCompletedOnboardingEnablesMeetingsWhenUseCaseMalformed() throws {
        let jsonCases = [
            """
            {
              "has_completed_onboarding": true,
              "onboarding_use_case": null
            }
            """,
            """
            {
              "has_completed_onboarding": true,
              "onboarding_use_case": 7
            }
            """,
            """
            {
              "has_completed_onboarding": true,
              "onboarding_use_case": "future-meeting-mode"
            }
            """
        ]

        for json in jsonCases {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

            #expect(config.hasCompletedOnboarding)
            #expect(config.resolvedOnboardingUseCase == .dictationAndMeetings)
            #expect(config.resolvedOnboardingUseCase.includesMeetings)
        }
    }

    @Test("incomplete onboarding defaults malformed use case to dictation and meetings")
    func incompleteOnboardingDefaultsMalformedUseCaseToDictationAndMeetings() throws {
        let jsonCases = [
            """
            {
              "has_completed_onboarding": false
            }
            """,
            """
            {
              "has_completed_onboarding": false,
              "onboarding_use_case": null
            }
            """,
            """
            {
              "has_completed_onboarding": false,
              "onboarding_use_case": "future-meeting-mode"
            }
            """
        ]

        for json in jsonCases {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

            #expect(!config.hasCompletedOnboarding)
            #expect(config.resolvedOnboardingUseCase == .dictationAndMeetings)
            #expect(config.resolvedOnboardingUseCase.includesMeetings)
        }
    }

    @Test("explicit completed dictation-only onboarding remains dictation-only")
    func explicitCompletedDictationOnlyOnboardingRemainsDictationOnly() throws {
        let json = """
        {
          "has_completed_onboarding": true,
          "onboarding_use_case": "dictation"
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.hasCompletedOnboarding)
        #expect(config.resolvedOnboardingUseCase == .dictation)
        #expect(!config.resolvedOnboardingUseCase.includesMeetings)
    }

    @Test("computer use default avoids existing right command dictation hotkey")
    func computerUseDefaultAvoidsExistingRightCommandDictationHotkey() throws {
        let json = """
        {
          "dictation_hotkey": {
            "keyCode": 54,
            "label": "Right Cmd"
          }
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.dictationHotkey == HotkeyConfig(keyCode: 54, label: "Right Cmd"))
        #expect(config.computerUseHotkey == .default)
        #expect(config.enableComputerUseHotkey == false)
    }

    @Test("legacy computer use hotkey enabled config is disabled once")
    func legacyComputerUseHotkeyEnabledConfigIsDisabledOnce() throws {
        let json = """
        {
          "enable_computer_use_hotkey": true,
          "enable_computer_use_planner": true
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.enableComputerUseHotkey == false)
        #expect(config.computerUseHotkeyDefaultDisabledMigrationApplied == true)
        // Planner has no legacy-off migration: an explicit true in the config is respected.
        #expect(config.enableComputerUsePlanner == true)
    }

    @Test("computer use hotkey remains enabled after migration is applied")
    func computerUseHotkeyRemainsEnabledAfterMigrationIsApplied() throws {
        let json = """
        {
          "enable_computer_use_hotkey": true,
          "computer_use_hotkey_default_disabled_migration_applied": true
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.enableComputerUseHotkey == true)
        #expect(config.computerUseHotkeyDefaultDisabledMigrationApplied == true)
    }

    @Test("unsupported onboarding use case falls back to dictation and meetings")
    func unsupportedOnboardingUseCaseFallsBackToDictationAndMeetings() throws {
        let json = """
        {
          "onboarding_use_case": "unknown"
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.resolvedOnboardingUseCase == .dictationAndMeetings)
    }

    @Test("voice notes use push-to-talk without paste dictation")
    func voiceNotesUsePushToTalkWithoutPasteDictation() {
        #expect(OnboardingUseCase.voiceNotes.includesVoiceNotes)
        #expect(OnboardingUseCase.voiceNotes.includesPushToTalk)
        #expect(!OnboardingUseCase.voiceNotes.includesDictation)
        #expect(!OnboardingUseCase.voiceNotes.includesMeetings)
    }

    @Test("voice notes escape hatch is dictation-only")
    func voiceNotesEscapeHatchIsDictationOnly() {
        #expect(OnboardingUseCase.dictation.canSwitchToVoiceNotesOnly)
        #expect(!OnboardingUseCase.dictationAndMeetings.canSwitchToVoiceNotesOnly)
        #expect(!OnboardingUseCase.meetings.canSwitchToVoiceNotesOnly)
        #expect(!OnboardingUseCase.voiceNotes.canSwitchToVoiceNotesOnly)
    }

    @Test("scheduled meeting notifications inherit legacy detection opt-out")
    func scheduledMeetingNotificationsInheritLegacyDetectionOptOut() throws {
        let json = """
        {
          "show_meeting_detection_notification": false
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.showScheduledMeetingNotifications == false)
        #expect(config.showMeetingDetectionNotification == false)
    }

    @Test("explicit scheduled meeting notification setting overrides legacy detection setting")
    func explicitScheduledMeetingNotificationSettingOverridesLegacyDetectionSetting() throws {
        let json = """
        {
          "show_scheduled_meeting_notifications": true,
          "show_meeting_detection_notification": false
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.showScheduledMeetingNotifications == true)
        #expect(config.showMeetingDetectionNotification == false)
    }

    @Test("unsupported cohere language falls back to english")
    func unsupportedCohereLanguageFallsBackToEnglish() throws {
        let json = """
        {
          "cohere_language": "xx"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.cohereLanguage == CohereTranscribeLanguage.english.rawValue)
        #expect(config.resolvedCohereLanguage == .english)
    }

    @Test("cohere language codes are normalized case-insensitively")
    func cohereLanguageCodesNormalizeCaseInsensitively() throws {
        let json = """
        {
          "cohere_language": " Fr "
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.cohereLanguage == CohereTranscribeLanguage.french.rawValue)
        #expect(config.resolvedCohereLanguage == .french)
    }

    @Test("meeting transcription falls back to dictation model when missing")
    func meetingTranscriptionFallsBackToDictationModel() throws {
        let json = """
        {
          "stt_backend": "whisper",
          "stt_model": "ggml-medium.en"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.meetingTranscriptionBackend == "whisper")
        #expect(config.meetingTranscriptionModel == "ggml-medium.en")
    }

    @Test("indicator anchor falls back to custom when legacy origin exists")
    func indicatorAnchorFallsBackToCustomForLegacyOrigin() throws {
        let json = """
        {
          "indicator_origin": [640, 320]
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.indicatorAnchor == .custom)
        #expect(config.indicatorOrigin?.x == 640)
        #expect(config.indicatorOrigin?.y == 320)
    }

    @Test("custom words decode missing threshold with default")
    func customWordsDecodeMissingThresholdWithDefault() throws {
        let json = """
        {
          "custom_words": [
            {
              "id": "67A2A4E9-E707-4A65-B690-124AFA4F0C18",
              "word": "muesli",
              "replacement": "Muesli"
            }
          ]
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.customWords.count == 1)
        #expect(config.customWords[0].matchingThreshold == 0.85)
    }

    @Test("custom words clamp thresholds into the supported UI range")
    func customWordsClampThresholdsIntoSupportedRange() throws {
        let json = """
        {
          "custom_words": [
            {
              "word": "aggressive",
              "matching_threshold": 0.1
            },
            {
              "word": "strict",
              "matching_threshold": 1.4
            }
          ]
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.customWords.count == 2)
        #expect(config.customWords[0].matchingThreshold == 0.70)
        #expect(config.customWords[1].matchingThreshold == 0.95)
    }

    @Test("custom templates decode missing icon with fallback")
    func customTemplateMissingIconUsesFallback() throws {
        let json = """
        {
          "custom_meeting_templates": [
            {
              "id": "tmpl_123",
              "name": "Customer Follow-Up",
              "prompt": "## Summary"
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.customMeetingTemplates.count == 1)
        #expect(config.customMeetingTemplates.first?.icon == MeetingTemplates.customIconFallback)
    }

    @Test("custom templates normalize invalid icons")
    func customTemplateInvalidIconUsesFallback() {
        let template = CustomMeetingTemplate(
            id: "tmpl_invalid",
            name: "Test",
            prompt: "Prompt",
            icon: "invalid.icon"
        )

        #expect(template.icon == MeetingTemplates.customIconFallback)
        #expect(MeetingTemplates.customDefinition(from: template).icon == MeetingTemplates.customIconFallback)
    }
}

@Suite("HotkeyMonitor")
struct HotkeyMonitorTests {
    final class ManualHotkeyScheduler {
        private struct ScheduledItem {
            let deadline: TimeInterval
            let order: Int
            let item: DispatchWorkItem
        }

        private static let referenceDate = Date(timeIntervalSinceReferenceDate: 0)

        private var now: TimeInterval = 0
        private var nextOrder = 0
        private var scheduled: [ScheduledItem] = []

        func schedule(after delay: TimeInterval, item: DispatchWorkItem) {
            scheduled.append(ScheduledItem(deadline: now + delay, order: nextOrder, item: item))
            nextOrder += 1
        }

        func currentDate() -> Date {
            Date(timeInterval: now, since: Self.referenceDate)
        }

        func advance(by interval: TimeInterval) {
            now += interval
            while let next = scheduled
                .filter({ $0.deadline <= now })
                .min(by: { lhs, rhs in
                    lhs.deadline == rhs.deadline ? lhs.order < rhs.order : lhs.deadline < rhs.deadline
                }) {
                scheduled.removeAll { $0.order == next.order }
                if !next.item.isCancelled {
                    next.item.perform()
                }
            }
        }

        func makeMonitor(
            prepareDelay: TimeInterval = 0.15,
            startDelay: TimeInterval = 0.25,
            doubleTapWindow: TimeInterval = 0.35
        ) -> HotkeyMonitor {
            HotkeyMonitor(
                prepareDelay: prepareDelay,
                startDelay: startDelay,
                doubleTapWindow: doubleTapWindow,
                scheduleAfter: { self.schedule(after: $0, item: $1) },
                now: currentDate
            )
        }
    }

    @Test("escape still cancels active hold dictation immediately")
    func escapeCancelsActiveHoldDictation() async throws {
        let monitor = HotkeyMonitor(
            prepareDelay: 0.01,
            startDelay: 0.02,
            doubleTapWindow: 0.03
        )
        var cancelCount = 0
        monitor.onCancel = {
            cancelCount += 1
        }

        monitor.setHoldRecordingActiveForTests()
        monitor.handleKeyDown(keyCode: 53)

        #expect(cancelCount == 1)
    }

    @Test("local monitor skips fresh hotkey starts while editing text")
    @MainActor
    func localMonitorSkipsFreshHotkeyStartsWhileEditingText() async throws {
        let monitor = HotkeyMonitor()
        let textView = NSTextView()

        #expect(
            monitor.shouldHandleLocalEventForTests(
                type: .flagsChanged,
                keyCode: 55,
                firstResponder: textView
            ) == false
        )
    }

    @Test("local monitor preserves key-up cleanup after hotkey session is armed")
    @MainActor
    func localMonitorPreservesKeyUpCleanupAfterHotkeySessionIsArmed() async throws {
        let monitor = HotkeyMonitor()
        let textView = NSTextView()
        var stopCount = 0
        monitor.onStop = {
            stopCount += 1
        }

        monitor.setHoldRecordingActiveForTests()

        #expect(
            monitor.shouldHandleLocalEventForTests(
                type: .flagsChanged,
                keyCode: 55,
                firstResponder: textView
            ) == true
        )

        monitor.handleFlagsChanged(keyCode: 55, flags: [])

        #expect(stopCount == 1)
    }

    @Test("local monitor still lets escape cancel active hold dictation while editing text")
    @MainActor
    func localMonitorLetsEscapeCancelActiveHoldDictationWhileEditingText() async throws {
        let monitor = HotkeyMonitor()
        let textView = NSTextView()

        monitor.setHoldRecordingActiveForTests()

        #expect(
            monitor.shouldHandleLocalEventForTests(
                type: .keyDown,
                keyCode: 53,
                firstResponder: textView
            ) == true
        )
    }

    @Test("trigger threshold derives prepare and start delays")
    func triggerThresholdTiming() {
        #expect(HotkeyTriggerTiming.clampedMilliseconds(10) == HotkeyTriggerTiming.minThresholdMilliseconds)
        #expect(HotkeyTriggerTiming.clampedMilliseconds(2_000) == HotkeyTriggerTiming.maxThresholdMilliseconds)
        #expect(HotkeyTriggerTiming.clampedMilliseconds(2_500) == HotkeyTriggerTiming.maxThresholdMilliseconds)
        #expect(HotkeyTriggerTiming.startDelay(forThresholdMilliseconds: 250) == 0.25)
        #expect(HotkeyTriggerTiming.prepareDelay(forThresholdMilliseconds: 250) == 0.15)
        #expect(HotkeyTriggerTiming.prepareDelay(forThresholdMilliseconds: 100) == 0)
    }

    @Test("low trigger threshold still allows double-tap toggle")
    @MainActor
    func lowTriggerThresholdStillAllowsDoubleTapToggle() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.35)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var prepareCount = 0
        var toggleStartCount = 0
        monitor.onPrepare = {
            prepareCount += 1
        }
        monitor.onToggleStart = {
            toggleStartCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        scheduler.advance(by: 0.10)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        scheduler.advance(by: 0.10)
        monitor.handleFlagsChanged(keyCode: 55, flags: .command)

        #expect(prepareCount == 0)
        #expect(toggleStartCount == 1)
    }

    @Test("double-tap outside window arms instead of toggling")
    @MainActor
    func doubleTapOutsideWindowArmsInsteadOfToggling() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.35)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var toggleStartCount = 0
        var armCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }
        monitor.onArm = {
            armCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        scheduler.advance(by: 0.40)
        monitor.handleFlagsChanged(keyCode: 55, flags: .command)

        #expect(toggleStartCount == 0)
        #expect(armCount == 2)
    }

    @Test("low trigger threshold arms immediately but defers audio while double-tap is possible")
    @MainActor
    func lowTriggerThresholdArmsImmediatelyButDefersAudio() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.35)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var armCount = 0
        var prepareCount = 0
        var startCount = 0
        monitor.onArm = {
            armCount += 1
        }
        monitor.onPrepare = {
            prepareCount += 1
        }
        monitor.onStart = {
            startCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        #expect(armCount == 1)
        scheduler.advance(by: 0.10)
        #expect(prepareCount == 0)
        #expect(startCount == 0)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
    }

    @Test("quick armed tap cancels after double-tap window")
    @MainActor
    func quickArmedTapCancelsAfterDoubleTapWindow() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.05)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var cancelCount = 0
        monitor.onArm = {}
        monitor.onCancel = {
            cancelCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        #expect(cancelCount == 0)

        scheduler.advance(by: 0.08)
        #expect(cancelCount == 1)
    }

    @Test("low trigger threshold starts quickly when double-tap is disabled")
    @MainActor
    func lowTriggerThresholdStartsQuicklyWhenDoubleTapDisabled() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.35)
        monitor.configureTriggerThreshold(milliseconds: 75)
        monitor.doubleTapEnabled = false
        var startCount = 0
        monitor.onStart = {
            startCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        scheduler.advance(by: 0.10)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])

        #expect(startCount == 1)
    }

    @Test("reconfiguring hotkey during active recording stops cleanly")
    func configureKeyCodeDuringActiveRecordingStopsCleanly() {
        let monitor = HotkeyMonitor()
        var stopCount = 0
        var cancelCount = 0
        monitor.onStop = {
            stopCount += 1
        }
        monitor.onCancel = {
            cancelCount += 1
        }

        monitor.setHoldRecordingActiveForTests()
        monitor.configure(keyCode: 56)

        #expect(stopCount == 1)
        #expect(cancelCount == 0)
        #expect(monitor.targetKeyCode == 56)
    }

    @Test("reconfiguring hotkey during pending double tap cancel cancels cleanly")
    @MainActor
    func configureKeyCodeDuringPendingDoubleTapCancelCancelsCleanly() async throws {
        let monitor = HotkeyMonitor(doubleTapWindow: 0.35)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var cancelCount = 0
        monitor.onArm = {}
        monitor.onCancel = {
            cancelCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        monitor.configure(keyCode: 56)
        try await Task.sleep(for: .milliseconds(380))

        #expect(cancelCount == 1)
        #expect(monitor.targetKeyCode == 56)
    }

    @Test("changing trigger threshold during pending double tap cancel preserves cleanup")
    @MainActor
    func configureTriggerThresholdDuringPendingDoubleTapCancelPreservesCleanup() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.05)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var cancelCount = 0
        monitor.onArm = {}
        monitor.onCancel = {
            cancelCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        monitor.configureTriggerThreshold(milliseconds: 125)
        scheduler.advance(by: 0.08)

        #expect(cancelCount == 1)
    }

    @Test("combination shortcut requires hold threshold before toggling")
    @MainActor
    func combinationShortcutRequiresHoldThresholdBeforeToggling() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(startDelay: 0.05)
        monitor.configure(HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 15))
        var toggleStartCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }

        monitor.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [.command, .shift])
        scheduler.advance(by: 0.02)
        monitor.handleCombinationForTests(type: .keyUp, keyCode: 15, flags: [.command, .shift])
        scheduler.advance(by: 0.05)

        #expect(toggleStartCount == 0)
    }

    @Test("combination shortcut toggles after hold threshold")
    @MainActor
    func combinationShortcutTogglesAfterHoldThreshold() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(startDelay: 0.03)
        monitor.configure(HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 15))
        var toggleStartCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }

        monitor.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [.command, .shift])
        scheduler.advance(by: 0.05)

        #expect(toggleStartCount == 1)
    }

    @Test("combination toggle cancellation resets without firing stop")
    @MainActor
    func combinationToggleCancellationResetsWithoutFiringStop() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(startDelay: 0.03)
        monitor.configure(HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 15))
        var toggleStartCount = 0
        var toggleStopCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }
        monitor.onToggleStop = {
            toggleStopCount += 1
        }

        monitor.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [.command, .shift])
        scheduler.advance(by: 0.05)
        #expect(monitor.isToggleRecording)

        monitor.cancelToggleMode()

        #expect(!monitor.isToggleRecording)
        #expect(toggleStartCount == 1)
        #expect(toggleStopCount == 0)
    }

    @Test("combination shortcut cancels when modifiers release before threshold")
    @MainActor
    func combinationShortcutCancelsWhenModifiersReleaseBeforeThreshold() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(startDelay: 0.05)
        monitor.configure(HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 15))
        var toggleStartCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }

        monitor.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [.command, .shift])
        scheduler.advance(by: 0.02)
        monitor.handleCombinationForTests(type: .flagsChanged, keyCode: 56, flags: .command)
        scheduler.advance(by: 0.05)

        #expect(toggleStartCount == 0)
    }
}

@Suite("MeetingResummarizationPolicy")
struct MeetingResummarizationPolicyTests {

    @Test("resummarize preserves the existing meeting title")
    func preservesExistingMeetingTitle() {
        let meeting = MeetingRecord(
            id: 42,
            title: "Customer pilot follow-up",
            startTime: "2026-03-24T10:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            wordCount: 123,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )

        #expect(
            MeetingResummarizationPolicy.plan(for: meeting) ==
            MeetingResummarizationPlan(
                promptTitle: "Customer pilot follow-up",
                persistedTitle: "Customer pilot follow-up"
            )
        )
    }

    @Test("blank titles fall back to Meeting in prompts without overwriting storage")
    func blankMeetingTitlesFallback() {
        let meeting = MeetingRecord(
            id: 43,
            title: "   ",
            startTime: "2026-03-24T10:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            wordCount: 123,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )

        #expect(
            MeetingResummarizationPolicy.plan(for: meeting) ==
            MeetingResummarizationPlan(
                promptTitle: "Meeting",
                persistedTitle: "   "
            )
        )
    }
}

@Suite("Meeting template resolution")
struct MeetingTemplateResolutionTests {

    @Test("exact resolution returns nil for deleted custom templates")
    func exactResolutionReturnsNilForDeletedCustomTemplates() {
        let customTemplates = [
            CustomMeetingTemplate(
                id: "tmpl_existing",
                name: "Existing Template",
                prompt: "## Summary",
                icon: "person.2"
            )
        ]

        #expect(
            MeetingTemplates.resolveExactDefinition(
                id: "tmpl_deleted",
                customTemplates: customTemplates
            ) == nil
        )
    }

    @Test("exact resolution still supports auto and built-in templates")
    func exactResolutionSupportsDefaultTemplates() {
        let builtIn = MeetingTemplates.builtIns.first!

        #expect(
            MeetingTemplates.resolveExactDefinition(
                id: MeetingTemplates.autoID,
                customTemplates: []
            )?.id == MeetingTemplates.autoID
        )
        #expect(
            MeetingTemplates.resolveExactDefinition(
                id: builtIn.id,
                customTemplates: []
            )?.id == builtIn.id
        )
    }

    @Test("built-in overrides replace only customized fields")
    func builtInOverridesReplaceCustomizedFields() {
        let defaults = MeetingTemplates.builtIns.first!
        let resolved = MeetingTemplates.resolveExactDefinition(
            id: defaults.id,
            customTemplates: [],
            builtInOverrides: [
                BuiltInMeetingTemplateOverride(
                    id: defaults.id,
                    prompt: "## Private Notes"
                )
            ]
        )

        #expect(resolved?.title == defaults.title)
        #expect(resolved?.icon == defaults.icon)
        #expect(resolved?.promptBody == "## Private Notes")
        #expect(resolved?.kind == .builtin)
    }

    @Test("Auto template accepts built-in overrides")
    func autoTemplateAcceptsBuiltInOverrides() {
        let resolved = MeetingTemplates.resolveExactDefinition(
            id: MeetingTemplates.autoID,
            customTemplates: [],
            builtInOverrides: [
                BuiltInMeetingTemplateOverride(
                    id: MeetingTemplates.autoID,
                    prompt: "## Compact Summary"
                )
            ]
        )

        #expect(resolved?.id == MeetingTemplates.autoID)
        #expect(resolved?.promptBody == "## Compact Summary")
        #expect(
            MeetingTemplates.editableBuiltInDefinitions(
                overrides: [
                    BuiltInMeetingTemplateOverride(
                        id: MeetingTemplates.autoID,
                        prompt: "## Compact Summary"
                    )
                ]
            ).first?.promptBody == "## Compact Summary"
        )
    }

    @Test("Auto override stores only differences from defaults")
    func autoOverrideStoresOnlyDifferences() {
        let override = MeetingTemplates.makeBuiltInOverride(
            id: MeetingTemplates.autoID,
            name: MeetingTemplates.auto.title,
            prompt: "## My Default Notes",
            icon: MeetingTemplates.auto.icon
        )

        #expect(override?.id == MeetingTemplates.autoID)
        #expect(override?.name == nil)
        #expect(override?.prompt == "## My Default Notes")
        #expect(override?.icon == nil)
    }

    @Test("built-in override creation stores only differences from defaults")
    func builtInOverrideStoresOnlyDifferences() {
        let defaults = MeetingTemplates.builtIns.first!
        let override = MeetingTemplates.makeBuiltInOverride(
            id: defaults.id,
            name: defaults.title,
            prompt: "## Customized",
            icon: defaults.icon
        )

        #expect(override?.id == defaults.id)
        #expect(override?.name == nil)
        #expect(override?.prompt == "## Customized")
        #expect(override?.icon == nil)
        #expect(
            MeetingTemplates.makeBuiltInOverride(
                id: defaults.id,
                name: defaults.title,
                prompt: defaults.promptBody,
                icon: defaults.icon
            ) == nil
        )
    }
}

@Suite("DictationState")
struct DictationStateTests {
    @Test("raw values")
    func rawValues() {
        #expect(DictationState.idle.rawValue == "idle")
        #expect(DictationState.preparing.rawValue == "preparing")
        #expect(DictationState.recording.rawValue == "recording")
        #expect(DictationState.transcribing.rawValue == "transcribing")
    }
}

@Suite("CGPointCodable")
struct CGPointCodableTests {

    @Test("keyed round-trip")
    func keyedRoundTrip() throws {
        let point = CGPointCodable(x: 100.5, y: 200.0)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(CGPointCodable.self, from: data)
        #expect(decoded.x == 100.5)
        #expect(decoded.y == 200.0)
    }

    @Test("decodes from array format")
    func arrayDecode() throws {
        let json = "[42.0, 84.0]"
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CGPointCodable.self, from: data)
        #expect(decoded.x == 42.0)
        #expect(decoded.y == 84.0)
    }
}

@Suite("WordCount")
struct WordCountTests {

    @Test("basic counting")
    func basicCount() {
        #expect(DictationStore.countWords(in: "hello world") == 2)
        #expect(DictationStore.countWords(in: "one") == 1)
        #expect(DictationStore.countWords(in: "") == 0)
    }

    @Test("handles multiple whitespace")
    func multipleWhitespace() {
        #expect(DictationStore.countWords(in: "hello   world") == 2)
        #expect(DictationStore.countWords(in: "  leading and trailing  ") == 3)
    }
}

@Suite("HotkeyConfig")
struct HotkeyConfigTests {

    @Test("default is Right Option")
    func defaultConfig() {
        let config = HotkeyConfig.default
        #expect(config.keyCode == 61)
        #expect(config.label == "Right Option")
    }

    @Test("computer use default is Right Cmd")
    func computerUseDefaultConfig() {
        let config = HotkeyConfig.computerUseDefault
        #expect(config.keyCode == 54)
        #expect(config.label == "Right Cmd")
    }

    @Test("computer use fallback avoids dictation hotkey")
    func computerUseFallbackAvoidsDictationHotkey() {
        #expect(HotkeyConfig.computerUseDefault(avoiding: .default) == .computerUseDefault)
        #expect(HotkeyConfig.computerUseDefault(avoiding: .computerUseDefault) == .default)
    }

    @Test("hotkey policy blocks active duplicate shortcuts")
    func hotkeyPolicyBlocksActiveDuplicateShortcuts() {
        #expect(ShortcutHotkeyPolicy.validateDictationHotkey(
            .computerUseDefault,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: true
        ) == .conflict(message: ShortcutHotkeyPolicy.conflictMessage))

        #expect(ShortcutHotkeyPolicy.validateDictationHotkey(
            .computerUseDefault,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: false
        ) == .updated)

        #expect(ShortcutHotkeyPolicy.validateComputerUseHotkey(
            .default,
            dictationHotkey: .default,
            isComputerUseEnabled: true
        ) == .conflict(message: ShortcutHotkeyPolicy.conflictMessage))

        #expect(ShortcutHotkeyPolicy.validateComputerUseHotkey(
            .default,
            dictationHotkey: .default,
            isComputerUseEnabled: false
        ) == .updated)
    }

    @Test("hotkey policy moves computer use key when enabling with a stale conflict")
    func hotkeyPolicyMovesComputerUseKeyWhenEnablingWithStaleConflict() {
        let resolution = ShortcutHotkeyPolicy.resolvedComputerUseHotkeyWhenEnabling(
            currentHotkey: .default,
            dictationHotkey: .default
        )

        #expect(resolution.hotkey == .computerUseDefault)
        #expect(resolution.result.didUpdate)
        #expect(resolution.result.message == "Computer Use Command moved to Right Cmd to avoid matching Push to Talk.")
    }

    @Test("hotkey policy rejects computer use enable when fallback conflicts with meeting recording")
    func hotkeyPolicyRejectsComputerUseEnableWhenFallbackConflictsWithMeetingRecording() {
        let resolution = ShortcutHotkeyPolicy.resolvedComputerUseHotkeyWhenEnabling(
            currentHotkey: .default,
            dictationHotkey: .default,
            meetingRecordingHotkey: .computerUseDefault,
            isMeetingRecordingEnabled: true
        )

        #expect(resolution.hotkey == .default)
        #expect(resolution.result == .conflict(message: ShortcutHotkeyPolicy.conflictMessage))
    }

    @Test("hotkey policy rejects computer use enable when current shortcut conflicts with meeting recording")
    func hotkeyPolicyRejectsComputerUseEnableWhenCurrentShortcutConflictsWithMeetingRecording() {
        let resolution = ShortcutHotkeyPolicy.resolvedComputerUseHotkeyWhenEnabling(
            currentHotkey: .computerUseDefault,
            dictationHotkey: .default,
            meetingRecordingHotkey: .computerUseDefault,
            isMeetingRecordingEnabled: true
        )

        #expect(resolution.hotkey == .computerUseDefault)
        #expect(resolution.result == .conflict(message: ShortcutHotkeyPolicy.conflictMessage))
    }

    @Test("combination conflicts ignore unsupported modifier flags")
    func combinationConflictsIgnoreUnsupportedModifierFlags() {
        let visible = HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 15)
        let withCapsLock = HotkeyConfig.combination(modifiers: [.command, .shift, .capsLock], keyCode: 15)

        #expect(visible.label == "⌘⇧R")
        #expect(withCapsLock.label == "⌘⇧R")
        #expect(visible.combinationModifiers == withCapsLock.combinationModifiers)
        #expect(ShortcutHotkeyPolicy.hotkeysConflict(visible, withCapsLock))
    }

    @Test("meeting recording warns for common global app shortcuts")
    func meetingRecordingWarnsForCommonGlobalAppShortcuts() {
        let result = ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(
            .meetingRecordingDefault,
            dictationHotkey: .default,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: false
        )

        #expect(result.didUpdate)
        #expect(result.message == ShortcutHotkeyPolicy.commonGlobalShortcutWarning)
    }

    @Test("meeting recording does not warn for uncommon global combinations")
    func meetingRecordingDoesNotWarnForUncommonGlobalCombinations() {
        let uncommon = HotkeyConfig.combination(modifiers: [.command, .option, .control], keyCode: 46)
        let result = ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(
            uncommon,
            dictationHotkey: .default,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: false
        )

        #expect(result == .updated)
    }

    @Test("label for known key codes")
    func knownKeyCodes() {
        #expect(HotkeyConfig.label(for: 55) == "Left Cmd")
        #expect(HotkeyConfig.label(for: 54) == "Right Cmd")
        #expect(HotkeyConfig.label(for: 63) == "Fn")
        #expect(HotkeyConfig.label(for: 59) == "Left Ctrl")
        #expect(HotkeyConfig.label(for: 62) == "Right Ctrl")
        #expect(HotkeyConfig.label(for: 58) == "Left Option")
        #expect(HotkeyConfig.label(for: 61) == "Right Option")
        #expect(HotkeyConfig.label(for: 56) == "Left Shift")
        #expect(HotkeyConfig.label(for: 60) == "Right Shift")
    }

    @Test("display label uses keyboard symbols")
    func displayLabelUsesKeyboardSymbols() {
        #expect(HotkeyConfig.default.displayLabel == "Right ⌥")
        #expect(HotkeyConfig.computerUseDefault.displayLabel == "Right ⌘")
        #expect(HotkeyConfig.meetingRecordingDefault.displayLabel == "⌘⇧R")
        #expect(HotkeyConfig(keyCode: 62, label: "Right Ctrl").displayLabel == "Right ⌃")
        #expect(HotkeyConfig(keyCode: 63, label: "Fn").displayLabel == "fn")
    }

    @Test("unknown key code returns nil")
    func unknownKeyCode() {
        #expect(HotkeyConfig.label(for: 0) == nil)
        #expect(HotkeyConfig.label(for: 100) == nil)
    }
}

@Suite("AppConfig — appearance fields")
struct AppConfigAppearanceTests {

    @Test("soundEnabled defaults to true")
    func soundEnabledDefault() {
        let config = AppConfig()
        #expect(config.soundEnabled == true)
    }

    @Test("muteSystemAudioDuringDictation defaults to false")
    func muteSystemAudioDuringDictationDefault() {
        let config = AppConfig()
        #expect(config.muteSystemAudioDuringDictation == false)
    }

    @Test("pauseMediaDuringDictation defaults to false")
    func pauseMediaDuringDictationDefault() {
        let config = AppConfig()
        #expect(config.pauseMediaDuringDictation == false)
    }

    @Test("recordingColorHex defaults to Catppuccin Mocha base")
    func recordingColorHexDefault() {
        let config = AppConfig()
        #expect(config.recordingColorHex == "1e1e2e")
    }

    @Test("soundEnabled round-trips through JSON")
    func soundEnabledRoundTrip() throws {
        var config = AppConfig()
        config.soundEnabled = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.soundEnabled == false)
    }

    @Test("muteSystemAudioDuringDictation round-trips through JSON")
    func muteSystemAudioDuringDictationRoundTrip() throws {
        var config = AppConfig()
        config.muteSystemAudioDuringDictation = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.muteSystemAudioDuringDictation == true)
    }

    @Test("pauseMediaDuringDictation round-trips through JSON")
    func pauseMediaDuringDictationRoundTrip() throws {
        var config = AppConfig()
        config.pauseMediaDuringDictation = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.pauseMediaDuringDictation == true)
    }

    @Test("recordingColorHex round-trips through JSON")
    func recordingColorHexRoundTrip() throws {
        var config = AppConfig()
        config.recordingColorHex = "303446"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.recordingColorHex == "303446")
    }

    @Test("unknown JSON keys are ignored — soundEnabled falls back to default")
    func soundEnabledFallsBackOnMissingKey() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.soundEnabled == true)
    }

    @Test("unknown JSON keys are ignored — muteSystemAudioDuringDictation falls back to default")
    func muteSystemAudioDuringDictationFallsBackOnMissingKey() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.muteSystemAudioDuringDictation == false)
    }

    @Test("unknown JSON keys are ignored — pauseMediaDuringDictation falls back to default")
    func pauseMediaDuringDictationFallsBackOnMissingKey() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.pauseMediaDuringDictation == false)
    }

    @Test("unknown JSON keys are ignored — recordingColorHex falls back to default")
    func recordingColorHexFallsBackOnMissingKey() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.recordingColorHex == "1e1e2e")
    }

    @Test("soundEnabled CodingKey is sound_enabled")
    func soundEnabledCodingKey() throws {
        var config = AppConfig()
        config.soundEnabled = false
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["sound_enabled"] as? Bool == false)
    }

    @Test("muteSystemAudioDuringDictation CodingKey is mute_system_audio_during_dictation")
    func muteSystemAudioDuringDictationCodingKey() throws {
        var config = AppConfig()
        config.muteSystemAudioDuringDictation = true
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["mute_system_audio_during_dictation"] as? Bool == true)
    }

    @Test("pauseMediaDuringDictation CodingKey is pause_media_during_dictation")
    func pauseMediaDuringDictationCodingKey() throws {
        var config = AppConfig()
        config.pauseMediaDuringDictation = true
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["pause_media_during_dictation"] as? Bool == true)
    }

    @Test("recordingColorHex CodingKey is recording_color_hex")
    func recordingColorHexCodingKey() throws {
        var config = AppConfig()
        config.recordingColorHex = "eff1f5"
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["recording_color_hex"] as? String == "eff1f5")
    }
}
