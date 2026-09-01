import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Project Niko summary language policy")
struct GemmaSummaryLanguagePolicyTests {
    @Test("model decides does not alter the system prompt")
    func modelDecides() {
        let builtIn = "Write the ENTIRE meeting notes — every section, including all bullet points — in the primary language of the meeting transcript. Do not switch to English for any section just because the section headings are in English."
        let prompt = GemmaSummaryLanguagePolicy.applying(
            to: "Summarize.\n\(builtIn)\nKeep facts.",
            transcript: String(repeating: "Русский текст. ", count: 20),
            mode: .modelDecides,
            customLanguage: "Polish"
        )
        #expect(prompt == "Summarize.\n\nKeep facts.")
        #expect(!prompt.contains("primary language"))
    }

    @Test("force detection adds an explicit BCP-47 directive")
    func detection() throws {
        let transcript = String(repeating: "Это подробная русская стенограмма рабочего совещания. ", count: 20)
        let builtIn = "Write the title in the same language as the meeting transcript; do not default to English just because the examples are in English."
        let prompt = GemmaSummaryLanguagePolicy.applying(
            to: "Generate title. \(builtIn)",
            transcript: transcript,
            mode: .detectTranscript,
            customLanguage: ""
        )
        #expect(prompt.contains("\"ru\""))
        #expect(prompt.contains("entire final answer"))
        #expect(!prompt.contains("same language as the meeting transcript"))
    }

    @Test("uncertain short transcript leaves language to the model")
    func uncertainDetection() {
        #expect(GemmaSummaryLanguagePolicy.directive(
            transcript: "OK",
            mode: .detectTranscript,
            customLanguage: ""
        ) == nil)
    }

    @Test("custom language is one-line and bounded")
    func customLanguage() throws {
        let raw = "Polish\n" + String(repeating: "x", count: 200)
        let normalized = GemmaSummaryLanguagePolicy.normalizedCustomLanguage(raw)
        #expect(!normalized.contains("\n"))
        #expect(normalized.count == GemmaSummaryLanguagePolicy.maximumCustomLanguageCharacters)
        let directive = try #require(GemmaSummaryLanguagePolicy.directive(
            transcript: "",
            mode: .custom,
            customLanguage: raw
        ))
        #expect(directive.contains(normalized))
    }

    @Test("legacy config receives safe language detection with thinking off")
    func legacyConfigDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config.resolvedGemmaSummaryLanguageMode == .detectTranscript)
        #expect(config.gemmaSummaryCustomLanguage.isEmpty)
        #expect(!config.gemmaSummaryThinkingEnabled)
    }

    @Test("invalid persisted language mode fails closed to transcript detection")
    func invalidLanguageModeFallback() {
        var config = AppConfig()
        config.gemmaSummaryLanguageMode = "unknown-future-mode"
        #expect(config.resolvedGemmaSummaryLanguageMode == .detectTranscript)
    }

    @Test("language and thinking settings round-trip independently")
    func configRoundTrip() throws {
        var config = AppConfig()
        config.gemmaSummaryLanguageMode = GemmaSummaryLanguageMode.custom.rawValue
        config.gemmaSummaryCustomLanguage = "Polish"
        config.gemmaSummaryThinkingEnabled = true

        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.resolvedGemmaSummaryLanguageMode == .custom)
        #expect(decoded.gemmaSummaryCustomLanguage == "Polish")
        #expect(decoded.gemmaSummaryThinkingEnabled)
    }

    @Test("Gemma processing metadata records the independent thinking choice")
    func thinkingMetadata() {
        var config = AppConfig()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.gemmaLocal.backend
        let metadata = MeetingProcessingMetadataFactory.summary(
            config: config,
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            thinkingStatus: .used
        )
        #expect(metadata.thinkingStatus == .used)
    }
}
