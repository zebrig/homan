import CryptoKit
import Foundation
import Jinja

enum GemmaChatTemplateError: LocalizedError, Equatable {
    case missing
    case sourceTooLarge(actualBytes: Int, maximumBytes: Int)
    case unterminatedTag
    case compileFailed(String)
    case renderFailed(String)
    case renderedPromptTooLarge(actualBytes: Int, maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "The Gemma model does not contain an embedded Jinja chat template."
        case let .sourceTooLarge(actualBytes, maximumBytes):
            return "The Gemma chat template is too large (\(actualBytes) bytes; limit \(maximumBytes))."
        case .unterminatedTag:
            return "The Gemma chat template contains an unterminated Jinja tag."
        case let .compileFailed(reason):
            return "The Gemma chat template is not compatible with Homan: \(reason)"
        case let .renderFailed(reason):
            return "The Gemma chat template could not render this request: \(reason)"
        case let .renderedPromptTooLarge(actualBytes, maximumBytes):
            return "The rendered Gemma prompt is too large (\(actualBytes) bytes; limit \(maximumBytes))."
        }
    }
}

/// Removes Jinja's `-` whitespace-control markers with lexical awareness before
/// swift-jinja sees the source. swift-jinja 2.4.2 preprocesses these markers with
/// global regular expressions, which can rewrite marker-looking text inside quoted
/// expressions and does not handle comment controls. This scanner only recognizes
/// delimiters in their legal template state.
enum JinjaWhitespaceNormalizer {
    private enum State: Equatable {
        case data
        case expression
        case statement
        case comment
    }

    static func normalize(_ source: String) throws -> String {
        var output = ""
        output.reserveCapacity(source.count)

        var index = source.startIndex
        var state: State = .data
        var trimLeadingWhitespace = false

        while index < source.endIndex {
            if state == .data, trimLeadingWhitespace {
                if source[index].isWhitespace {
                    index = source.index(after: index)
                    continue
                }
                trimLeadingWhitespace = false
            }

            switch state {
            case .data:
                if hasPrefix("{#-", in: source, at: index) {
                    trimTrailingWhitespace(&output)
                    state = .comment
                    index = source.index(index, offsetBy: 3)
                } else if hasPrefix("{#", in: source, at: index) {
                    state = .comment
                    index = source.index(index, offsetBy: 2)
                } else if hasPrefix("{{-", in: source, at: index) {
                    trimTrailingWhitespace(&output)
                    protectLiteralBraceBeforeTag(&output)
                    output += "{{"
                    state = .expression
                    index = source.index(index, offsetBy: 3)
                } else if hasPrefix("{%-", in: source, at: index) {
                    trimTrailingWhitespace(&output)
                    protectLiteralBraceBeforeTag(&output)
                    output += "{%"
                    state = .statement
                    index = source.index(index, offsetBy: 3)
                } else if hasPrefix("{{", in: source, at: index) {
                    output += "{{"
                    state = .expression
                    index = source.index(index, offsetBy: 2)
                } else if hasPrefix("{%", in: source, at: index) {
                    output += "{%"
                    state = .statement
                    index = source.index(index, offsetBy: 2)
                } else {
                    let character = source[index]
                    if output.last == "{", character == "{" || character == "%" || character == "#" {
                        protectLiteralBraceBeforeTag(&output)
                    }
                    output.append(character)
                    index = source.index(after: index)
                }

            case .expression, .statement:
                let character = source[index]
                if character == "'" || character == "\"" {
                    let consumed = try consumeQuotedLiteral(in: source, at: index, delimiter: character)
                    output += shieldWhitespaceMarkers(inQuotedLiteral: consumed.literal, delimiter: character)
                    index = consumed.nextIndex
                    continue
                }

                let controlledClose = state == .expression ? "-}}" : "-%}"
                let regularClose = state == .expression ? "}}" : "%}"
                if hasPrefix(controlledClose, in: source, at: index) {
                    output += regularClose
                    state = .data
                    trimLeadingWhitespace = true
                    index = source.index(index, offsetBy: controlledClose.count)
                } else if hasPrefix(regularClose, in: source, at: index) {
                    output += regularClose
                    state = .data
                    index = source.index(index, offsetBy: regularClose.count)
                } else {
                    output.append(character)
                    index = source.index(after: index)
                }

            case .comment:
                // Comments render no bytes, so remove them rather than manufacturing a
                // delimiter that could merge with an adjacent literal `{` after lstrip.
                if hasPrefix("-#}", in: source, at: index) {
                    state = .data
                    trimLeadingWhitespace = true
                    index = source.index(index, offsetBy: 3)
                } else if hasPrefix("#}", in: source, at: index) {
                    state = .data
                    index = source.index(index, offsetBy: 2)
                } else {
                    index = source.index(after: index)
                }
            }
        }

        guard state == .data else {
            throw GemmaChatTemplateError.unterminatedTag
        }
        return output
    }

    private static func hasPrefix(_ prefix: String, in source: String, at index: String.Index) -> Bool {
        source[index...].hasPrefix(prefix)
    }

    private static func trimTrailingWhitespace(_ output: inout String) {
        while let last = output.last, last.isWhitespace {
            output.removeLast()
        }
    }

    private static func protectLiteralBraceBeforeTag(_ output: inout String) {
        // Lstrip can make one or more literal `{` characters adjacent to a normalized
        // `{{`/`{%`, changing how the dependency tokenizes the source. Emit the whole
        // trailing run through an ordinary expression so the rendered bytes stay exact.
        var braceCount = 0
        while output.last == "{" {
            output.removeLast()
            braceCount += 1
        }
        guard braceCount > 0 else { return }
        output += "{{ '\(String(repeating: "{", count: braceCount))' }}"
    }

    private static func consumeQuotedLiteral(
        in source: String,
        at start: String.Index,
        delimiter: Character
    ) throws -> (literal: String, nextIndex: String.Index) {
        var index = source.index(after: start)
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == delimiter {
                let end = source.index(after: index)
                return (String(source[start..<end]), end)
            }
            index = source.index(after: index)
        }
        throw GemmaChatTemplateError.unterminatedTag
    }

    private static func shieldWhitespaceMarkers(
        inQuotedLiteral literal: String,
        delimiter: Character
    ) -> String {
        let markers = ["{%-", "{{-", "{#-", "-%}", "-}}", "-#}"]
        guard markers.contains(where: literal.contains) else { return literal }

        let inner = String(literal.dropFirst().dropLast())
        var segments = [inner]
        for marker in markers {
            var next: [String] = []
            for segment in segments {
                let pieces = segment.components(separatedBy: marker)
                for (index, piece) in pieces.enumerated() {
                    if index > 0 {
                        // Split the marker so swift-jinja's global regex cannot see it,
                        // then let Jinja concatenate it back to the exact string value.
                        next.append(String(marker.prefix(1)))
                        next.append(String(marker.dropFirst()))
                    }
                    next.append(piece)
                }
            }
            segments = next
        }

        let quoted = segments.map { "\(delimiter)\($0)\(delimiter)" }
        return "(" + quoted.joined(separator: " ~ ") + ")"
    }
}

enum GemmaPromptContentSanitizer {
    static func sanitize(_ content: String) -> String {
        content
            .replacingOccurrences(of: "<|", with: "<\u{200B}|")
            .replacingOccurrences(of: "|>", with: "|\u{200B}>")
            .replacingOccurrences(of: "<bos>", with: "<\u{200B}bos>")
            .replacingOccurrences(of: "<eos>", with: "<\u{200B}eos>")
    }
}

/// Immutable compiled representation of the exact Jinja template embedded in a
/// loaded Gemma GGUF. `Template.render` receives no shared environment, so every
/// request gets fresh mutable render state.
struct GemmaChatTemplate: Sendable {
    static let maximumSourceBytes = 256 * 1024
    static let maximumRenderedBytes = 16 * 1024 * 1024

    let sourceSHA256: String
    private let template: Template

    init(source: String) throws {
        let sourceSize = source.utf8.count
        guard sourceSize > 0 else { throw GemmaChatTemplateError.missing }
        guard sourceSize <= Self.maximumSourceBytes else {
            throw GemmaChatTemplateError.sourceTooLarge(
                actualBytes: sourceSize,
                maximumBytes: Self.maximumSourceBytes
            )
        }

        let normalized = try JinjaWhitespaceNormalizer.normalize(source)
        do {
            template = try Template(
                normalized,
                with: .init(lstripBlocks: true, trimBlocks: true)
            )
        } catch {
            throw GemmaChatTemplateError.compileFailed(String(describing: error))
        }

        sourceSHA256 = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        // Exercise both independent branches before the model becomes active.
        for thinking in [false, true] {
            _ = try render(
                systemPrompt: "Homan template compatibility check.",
                userPrompt: "Test.",
                enableThinking: thinking,
                bosToken: "<bos>",
                eosToken: "<eos>"
            )
        }
    }

    func render(
        systemPrompt: String,
        userPrompt: String,
        enableThinking: Bool,
        bosToken: String,
        eosToken: String
    ) throws -> String {
        let messages: Value = [
            [
                "role": "system",
                "content": .string(GemmaPromptContentSanitizer.sanitize(systemPrompt)),
            ],
            [
                "role": "user",
                "content": .string(GemmaPromptContentSanitizer.sanitize(userPrompt)),
            ],
        ]
        let context: [String: Value] = [
            "messages": messages,
            "add_generation_prompt": true,
            "enable_thinking": .boolean(enableThinking),
            "preserve_thinking": false,
            "tools": .null,
            "bos_token": .string(bosToken),
            "eos_token": .string(eosToken),
        ]

        let rendered: String
        do {
            rendered = try template.render(context)
        } catch {
            throw GemmaChatTemplateError.renderFailed(String(describing: error))
        }
        let renderedSize = rendered.utf8.count
        guard renderedSize <= Self.maximumRenderedBytes else {
            throw GemmaChatTemplateError.renderedPromptTooLarge(
                actualBytes: renderedSize,
                maximumBytes: Self.maximumRenderedBytes
            )
        }
        return rendered
    }
}
