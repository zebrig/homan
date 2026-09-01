import Foundation
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

    @Test("external audited templates match all twelve Jinja2 goldens when supplied")
    func auditedFullTemplateMatrix() throws {
        guard let auditDirectory = ProcessInfo.processInfo.environment["HOMAN_NIKO_AUDIT_DIR"] else {
            return
        }
        let root = URL(fileURLWithPath: auditDirectory, isDirectory: true)
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
