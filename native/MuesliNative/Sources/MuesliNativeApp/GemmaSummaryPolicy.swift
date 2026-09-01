import Foundation
import NaturalLanguage

enum GemmaSummaryLanguageMode: String, CaseIterable, Codable, Sendable {
    case modelDecides = "model_decides"
    case detectTranscript = "detect_transcript"
    case custom = "custom"

    var label: String {
        switch self {
        case .modelDecides: return "Model decides"
        case .detectTranscript: return "Detect from transcript"
        case .custom: return "Custom"
        }
    }
}

enum GemmaSummaryLanguagePolicy {
    static let maximumDetectionCharacters = 20_000
    static let maximumCustomLanguageCharacters = 80
    static let minimumLetterCount = 40
    static let minimumConfidence = 0.45
    private static let builtInLanguageDirectives = [
        "Write the ENTIRE meeting notes — every section, including all bullet points — in the primary language of the meeting transcript. Do not switch to English for any section just because the section headings are in English.",
        "Write the title in the same language as the meeting transcript; do not default to English just because the examples are in English.",
    ]

    static func applying(
        to systemPrompt: String,
        transcript: String,
        mode: GemmaSummaryLanguageMode,
        customLanguage: String
    ) -> String {
        let neutralPrompt = strippingBuiltInLanguageDirectives(from: systemPrompt)
        guard let directive = directive(
            transcript: transcript,
            mode: mode,
            customLanguage: customLanguage
        ) else { return neutralPrompt }
        return neutralPrompt + "\n\n" + directive
    }

    static func directive(
        transcript: String,
        mode: GemmaSummaryLanguageMode,
        customLanguage: String
    ) -> String? {
        switch mode {
        case .modelDecides:
            return nil
        case .detectTranscript:
            guard let languageCode = detectLanguageCode(in: transcript) else { return nil }
            return "Write the entire final answer in the dominant transcript language identified by BCP-47 code \"\(languageCode)\". Keep proper names in their original form."
        case .custom:
            let value = normalizedCustomLanguage(customLanguage)
            guard !value.isEmpty else { return nil }
            return "Write the entire final answer in this user-selected language: \"\(value)\". Keep proper names in their original form."
        }
    }

    static func detectLanguageCode(in transcript: String) -> String? {
        let sample = String(transcript.prefix(maximumDetectionCharacters))
        let letterCount = sample.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) { count += 1 }
        }
        guard letterCount >= minimumLetterCount else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first,
              hypothesis.value >= minimumConfidence,
              hypothesis.key != .undetermined else {
            return nil
        }
        return hypothesis.key.rawValue
    }

    static func normalizedCustomLanguage(_ value: String) -> String {
        let oneLine = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(oneLine.prefix(maximumCustomLanguageCharacters))
    }

    static func strippingBuiltInLanguageDirectives(from prompt: String) -> String {
        builtInLanguageDirectives.reduce(prompt) { result, directive in
            result.replacingOccurrences(of: directive, with: "")
        }
        .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
