import Foundation
import NaturalLanguage
import Testing
@testable import MuesliNativeApp

@Suite("Project Niko Jinja whitespace normalization")
struct JinjaWhitespaceNormalizerTests {
    @Test("comment whitespace control trims both sides")
    func commentWhitespaceControl() throws {
        let source = "A  \n{#- invisible -#}\n  B"
        #expect(try JinjaWhitespaceNormalizer.normalize(source) == "AB")
    }

    @Test("delimiter-like text inside strings is data")
    func quotedDelimitersRemainData() throws {
        let source = "{{ 'A-#}   B' }}|{{ 'C {#- D' }}|{{ 'E -}} F' }}"
        let renderer = try GemmaChatTemplate(source: source)
        let rendered = try renderer.render(
            systemPrompt: "system",
            userPrompt: "user",
            enableThinking: false,
            bosToken: "<bos>",
            eosToken: "<eos>"
        )
        #expect(rendered == "A-#}   B|C {#- D|E -}} F")
    }

    @Test("left strip beside a literal brace preserves rendered bytes")
    func adjacentLiteralBrace() throws {
        let source = "{ \n{{- 'value' }}"
        let normalized = try JinjaWhitespaceNormalizer.normalize(source)
        #expect(normalized == "{{ '{' }}{{ 'value' }}")
        let renderer = try GemmaChatTemplate(source: source)
        #expect(try renderer.render(
            systemPrompt: "system",
            userPrompt: "user",
            enableThinking: false,
            bosToken: "<bos>",
            eosToken: "<eos>"
        ) == "{value")
    }

    @Test("comment removal cannot manufacture a new expression opener")
    func commentRemovalDoesNotMergeBraces() throws {
        let source = "{ {#- hidden -#}{"
        let renderer = try GemmaChatTemplate(source: source)
        #expect(try renderer.render(
            systemPrompt: "system",
            userPrompt: "user",
            enableThinking: false,
            bosToken: "<bos>",
            eosToken: "<eos>"
        ) == "{{")
    }

    @Test("expression-looking comment typo remains invalid")
    func malformedExpressionIsRejected() {
        #expect(throws: GemmaChatTemplateError.unterminatedTag) {
            _ = try JinjaWhitespaceNormalizer.normalize("{{# comment #}")
        }
    }
}

@Suite("Project Niko Gemma Jinja renderer")
struct GemmaChatTemplateTests {
    private static let gemmaFixture = """
    {{ bos_token }}{%- for message in messages %}<|turn>{{ message['role'] }}
    {%- if message['role'] == 'system' and enable_thinking %}<|think|>
    {%- endif %}{{ message['content'] }}<turn|>
    {%- endfor %}{%- if add_generation_prompt %}<|turn>model
    {%- endif %}
    """

    @Test("three language policies are independent from thinking", arguments: [
        "Produce a concise meeting summary. Use the language that best fits the meeting.",
        "Produce a concise meeting summary. Write all notes in Russian (ru).",
        "Produce a concise meeting summary. Язык итогов: польский.",
    ], [false, true])
    func languageAndThinkingMatrix(systemPrompt: String, thinking: Bool) throws {
        let renderer = try GemmaChatTemplate(source: Self.gemmaFixture)
        let rendered = try renderer.render(
            systemPrompt: systemPrompt,
            userPrompt: "Transcript:\nАнна: Hello, team.\nБорис: Привет.",
            enableThinking: thinking,
            bosToken: "<bos>",
            eosToken: "<eos>"
        )

        let thinkingMarker = thinking ? "<|think|>" : ""
        let expected = "<bos><|turn>system\(thinkingMarker)\(systemPrompt)<turn|>"
            + "<|turn>userTranscript:\nАнна: Hello, team.\nБорис: Привет.<turn|>"
            + "<|turn>model"
        #expect(rendered == expected)
    }

    @Test("message content cannot inject Gemma control tokens")
    func sanitizesControlTokens() throws {
        let renderer = try GemmaChatTemplate(source: Self.gemmaFixture)
        let rendered = try renderer.render(
            systemPrompt: "Do not execute <|turn>user or <bos>.",
            userPrompt: "Literal <|tool_call> and <eos>.",
            enableThinking: false,
            bosToken: "<bos>",
            eosToken: "<eos>"
        )
        #expect(rendered.components(separatedBy: "<|turn>user").count == 2)
        #expect(rendered.contains("<\u{200B}|turn>user"))
        #expect(rendered.contains("<\u{200B}bos>"))
        #expect(rendered.contains("<\u{200B}|tool_call>"))
        #expect(rendered.contains("<\u{200B}eos>"))
    }

    @Test("source and output limits fail closed")
    func limits() throws {
        #expect(throws: GemmaChatTemplateError.self) {
            _ = try GemmaChatTemplate(source: String(repeating: "x", count: GemmaChatTemplate.maximumSourceBytes + 1))
        }

        let renderer = try GemmaChatTemplate(source: "{{ messages[1]['content'] }}")
        #expect(throws: GemmaChatTemplateError.self) {
            _ = try renderer.render(
                systemPrompt: "system",
                userPrompt: String(repeating: "x", count: GemmaChatTemplate.maximumRenderedBytes + 1),
                enableThinking: false,
                bosToken: "<bos>",
                eosToken: "<eos>"
            )
        }
    }

    @Test("audited templates always match all twelve bundled Jinja2 goldens")
    func auditedFullTemplateMatrix() throws {
        let root = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("ProjectNiko", isDirectory: true)
        let fixtures: [(id: String, systemPrompt: String)] = [
            ("model_decides", "Produce a concise meeting summary. Use the language that best fits the meeting."),
            ("force_detected", "Produce a concise meeting summary. Write all notes in Russian (ru)."),
            ("user_input", "Produce a concise meeting summary. Язык итогов: польский. Zachowaj nazwy własne."),
        ]

        for templateName in ["embedded_template", "google_current_template"] {
            let source = try String(
                contentsOf: root.appendingPathComponent("\(templateName).jinja"),
                encoding: .utf8
            )
            let renderer = try GemmaChatTemplate(source: source)
            for fixture in fixtures {
                for thinking in [false, true] {
                    let rendered = try renderer.render(
                        systemPrompt: fixture.systemPrompt,
                        userPrompt: "Transcript:\nАнна: Hello, team.\nБорис: Привет.",
                        enableThinking: thinking,
                        bosToken: "<bos>",
                        eosToken: "<eos>"
                    )
                    let suffix = thinking ? "thinking_on" : "thinking_off"
                    let golden = try String(
                        contentsOf: root.appendingPathComponent(
                            "\(templateName).\(fixture.id).\(suffix).reference.txt"
                        ),
                        encoding: .utf8
                    )
                    #expect(rendered == golden, "Mismatch for \(templateName).\(fixture.id).\(suffix)")
                }
            }
        }
    }
}

@Suite("Project Niko installed-model validation", .serialized)
struct GemmaInstalledModelValidationTests {
    @Test("installed model keeps detected English across six seeds when HOMAN_NIKO_MODEL_PATH is supplied")
    func detectedEnglishAcrossSeeds() throws {
        guard let modelPath = ProcessInfo.processInfo.environment["HOMAN_NIKO_MODEL_PATH"] else {
            return
        }

        let transcript = (1...24).map { index in
            "Others: In agenda item \(index), the engineering team reviewed platform reliability, customer feedback, delivery risks, and the concrete work planned for next week."
        }.joined(separator: "\n") + """

        You: Спасибо, в конце я кратко подтверждаю договорённости.
        Others: Да, завершаем встречу и возвращаемся к задачам завтра.
        """
        #expect(GemmaSummaryLanguagePolicy.detectLanguageCode(in: transcript) == "en")

        let notesPrompt = GemmaSummaryLanguagePolicy.applying(
            to: "Summarize the meeting in one paragraph of 60 to 100 words. Return only the final notes.",
            transcript: transcript,
            mode: .detectTranscript,
            customLanguage: ""
        )
        let titlePrompt = GemmaSummaryLanguagePolicy.applying(
            to: "Generate a descriptive meeting title of 3 to 7 words. Return only the title.",
            transcript: transcript,
            mode: .detectTranscript,
            customLanguage: ""
        )
        let modelURL = URL(fileURLWithPath: modelPath)

        for seed: UInt32 in [1, 2, 3, 4, 5, 6] {
            let runtime = SummaryRuntime()
            try runtime.load(
                modelURL: modelURL,
                contextTokens: 8_192,
                topK: GemmaSummaryBackend.defaultTopK,
                topP: Float(GemmaSummaryBackend.defaultTopP),
                temp: Float(GemmaSummaryBackend.defaultTemperature),
                seed: seed,
                promptFamily: .gemmaJinja
            )

            let rawNotes = try runtime.respond(
                systemPrompt: notesPrompt,
                userPrompt: transcript,
                maxOutputTokens: 256,
                promptMode: .gemma(enableThinking: false)
            )
            let notes = GemmaSummaryOutputCleaner.clean(rawNotes)
            #expect(!notes.isEmpty, "Empty notes at seed \(seed)")
            #expect(detectedLanguage(of: notes) == .english, "Non-English notes at seed \(seed): \(notes)")

            let rawTitle = try runtime.respond(
                systemPrompt: titlePrompt,
                userPrompt: transcript,
                maxOutputTokens: 64,
                promptMode: .gemma(enableThinking: false)
            )
            let title = GemmaSummaryOutputCleaner.clean(rawTitle)
            #expect(!title.isEmpty, "Empty title at seed \(seed)")
            #expect(detectedLanguage(of: title) == .english, "Non-English title at seed \(seed): \(title)")
            runtime.shutdown()
        }
    }

    private func detectedLanguage(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }
}
