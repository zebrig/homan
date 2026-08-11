import Foundation

/// Parses one line without letting block syntax change the surrounding notes
/// layout, which is already handled by MeetingNotesView and the rich editor.
enum MarkdownInlineParser {
    static func parse(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}
