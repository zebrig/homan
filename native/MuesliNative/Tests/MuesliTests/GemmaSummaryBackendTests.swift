import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("GemmaSummaryOutputCleaner")
struct GemmaSummaryOutputCleanerTests {
    @Test("strips think blocks and marker boilerplate")
    func stripsMarkers() {
        let input = """
        <think>Let me organize this meeting.</think>
        ## Decisions
        - Ship v1.0
        <|turn|>next turn
        <|im_end|>tail
        [end of text]
        """
        let cleaned = GemmaSummaryOutputCleaner.clean(input)
        #expect(!cleaned.contains("<think>"))
        #expect(!cleaned.contains("Let me organize"))
        #expect(!cleaned.contains("<|turn|>"))
        #expect(!cleaned.contains("<|im_end|>"))
        #expect(!cleaned.contains("[end of text]"))
        #expect(cleaned.contains("Ship v1.0"))
    }

    @Test("strips code fences")
    func stripsCodeFences() {
        let cleaned = GemmaSummaryOutputCleaner.clean("```markdown\n## Notes\n```")
        #expect(!cleaned.contains("```"))
        #expect(cleaned.contains("## Notes"))
    }

    @Test("accepts real markdown output")
    func acceptsRealOutput() {
        #expect(GemmaSummaryOutputCleaner.isUsable("## Decisions\n- Ship it"))
        #expect(GemmaSummaryOutputCleaner.isUsable("Q3 Sprint Planning"))
        #expect(GemmaSummaryOutputCleaner.isUsable("Отчёт по встрече"))
    }

    @Test("rejects empty, placeholder, and punctuation-only output")
    func rejectsDegenerateOutput() {
        #expect(!GemmaSummaryOutputCleaner.isUsable(""))
        #expect(!GemmaSummaryOutputCleaner.isUsable("   "))
        #expect(!GemmaSummaryOutputCleaner.isUsable("..."))
        #expect(!GemmaSummaryOutputCleaner.isUsable(". . ."))
        #expect(!GemmaSummaryOutputCleaner.isUsable("…"))
        #expect(!GemmaSummaryOutputCleaner.isUsable(".,!?"))
    }
}

@Suite("GemmaSummaryBackendOption")
struct GemmaSummaryBackendOptionTests {
    @Test("gemmaLocal is registered with the expected id and label")
    func gemmaLocalOption() {
        #expect(MeetingSummaryBackendOption.gemmaLocal.backend == "gemma_local")
        #expect(MeetingSummaryBackendOption.gemmaLocal.label == "Gemma 4 (on-device)")
        #expect(MeetingSummaryBackendOption.all.contains(.gemmaLocal))
    }

    @Test("resolved picks gemmaLocal from its backend id")
    func resolvedBackend() {
        #expect(MeetingSummaryBackendOption.resolved("gemma_local") == .gemmaLocal)
        #expect(MeetingSummaryBackendOption.resolved("unknown") == .transcriptOnly)
    }

    @Test("fresh config defaults gemma summary model to the E4B catalog entry")
    func configDefaultModel() {
        let config = AppConfig()
        #expect(config.gemmaSummaryModel == GemmaSummaryModel.defaultModel.id)
        #expect(GemmaSummaryModel.resolve(id: config.gemmaSummaryModel) == .e4b)
    }

    @Test("resolvedMeetingSummaryModel falls back to the catalog default")
    func resolvedModelUsesConfigThenDefault() {
        var config = AppConfig()
        #expect(config.resolvedMeetingSummaryModel(for: .gemmaLocal) == GemmaSummaryModel.defaultModel.id)

        config.gemmaSummaryModel = GemmaSummaryModel.e2bQAT.id
        #expect(config.resolvedMeetingSummaryModel(for: .gemmaLocal) == GemmaSummaryModel.e2bQAT.id)
    }

    @Test("gemmaLocal generation settings resolve through the override store")
    func generationSettingsOverrides() {
        var config = AppConfig()
        let settings = SummaryGenerationSettings(
            maxOutputTokens: 1024,
            contextTokens: 16384,
            temperature: 1.0,
            topP: 0.95
        )
        config.setMeetingSummaryGenerationSettings(
            settings,
            backend: .gemmaLocal,
            model: GemmaSummaryModel.e4b.id
        )
        let resolved = config.meetingSummaryGenerationSettings(backend: .gemmaLocal, model: GemmaSummaryModel.e4b.id)
        #expect(resolved.maxOutputTokens == 1024)
        #expect(resolved.contextTokens == 16384)
        #expect(resolved.temperature == 1.0)
        #expect(resolved.topP == 0.95)
    }

    @Test("isMeetingSummaryBackendConfigured requires a downloaded model")
    @MainActor
    func configuredOnlyWhenDownloaded() {
        let config = AppConfig()
        let configured = MuesliController.isMeetingSummaryBackendConfigured(
            .gemmaLocal,
            config: config,
            isChatGPTAuthenticated: false
        )
        // A fresh config points at a model that is not on disk yet.
        #expect(configured == GemmaSummaryModel.resolve(id: config.gemmaSummaryModel).isDownloaded)
    }
}

@Suite("Gemma summary fallback")
struct GemmaSummaryFallbackTests {
    @Test("unconfigured gemmaLocal falls back to the raw transcript")
    func unconfiguredFallsBackToRawTranscript() async throws {
        // Fresh config now defaults to gemma_local; until the model is downloaded
        // the summary keeps the raw transcript (like unconfigured cloud backends).
        let config = AppConfig()
        let model = GemmaSummaryModel.resolve(id: config.gemmaSummaryModel)
        guard !model.isDownloaded else { return } // hermetic: only when model absent

        let result = try await MeetingSummaryClient.summarize(
            transcript: "raw meeting transcript",
            meetingTitle: "Standup",
            config: config
        )
        #expect(result.contains("## Raw Transcript"))
        #expect(result.contains("raw meeting transcript"))
    }
}

@Suite("Gemma degenerate output retry policy")
struct GemmaDegenerateOutputRetryTests {
    @Test("degenerate output is a plain non-retried failure")
    func degenerateOutputIsNotRetried() {
        let error = MeetingSummaryError.degenerateOutput(backend: "Gemma 4 (on-device)")
        #expect(!MeetingSummaryRetryPolicy.shouldRetry(error))
        #expect(MeetingSummaryRetryPolicy.effectiveRetryCount(configuredCount: 3, after: error) == 0)
        #expect(error.localizedDescription.contains("did not produce usable meeting notes"))
    }

    @Test("summaryFailureNotes surfaces the degenerate output failure")
    func failureNotesSurfaceDegenerateOutput() {
        let error = MeetingSummaryError.degenerateOutput(backend: "Gemma 4 (on-device)")
        let notes = MeetingSummaryClient.summaryFailureNotes(
            transcript: "raw",
            meetingTitle: "Standup",
            error: error
        )
        #expect(notes.contains("## Summary failed"))
        #expect(notes.contains("did not produce usable meeting notes"))
    }
}
