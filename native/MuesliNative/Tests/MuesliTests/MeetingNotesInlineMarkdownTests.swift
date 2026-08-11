import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("Meeting notes inline Markdown")
struct MeetingNotesInlineMarkdownTests {
    @MainActor
    private final class EditorState {
        var text: String
        var command: MarkdownEditorCommand?

        init(text: String = "", command: MarkdownEditorCommand? = nil) {
            self.text = text
            self.command = command
        }
    }

    private func rendered(_ markdown: String) -> String {
        String(MeetingNotesView.inline(markdown).characters)
    }

    @Test("bold italic and code markers render inline")
    func inlineMarkersRender() {
        #expect(rendered("Shipped **today**") == "Shipped today")
        #expect(rendered("Marked *urgent*") == "Marked urgent")
        #expect(rendered("Run `swift test`") == "Run swift test")
    }

    @Test("inline presentation intents and links are preserved")
    func presentationIntentsArePreserved() {
        let attributed = MeetingNotesView.inline(
            "**Owner**, *urgent*, [spec](https://example.com)"
        )
        let strong = attributed.runs.filter {
            $0.inlinePresentationIntent == .stronglyEmphasized
        }
        let emphasis = attributed.runs.filter {
            $0.inlinePresentationIntent == .emphasized
        }

        #expect(strong.map { String(attributed[$0.range].characters) } == ["Owner"])
        #expect(emphasis.map { String(attributed[$0.range].characters) } == ["urgent"])
        #expect(attributed.runs.contains {
            $0.link == URL(string: "https://example.com")
        })
    }

    @Test("inline parser preserves ordinary text and whitespace")
    func ordinaryTextIsStable() {
        #expect(rendered("Ticket #123 was closed") == "Ticket #123 was closed")
        #expect(rendered("Costs 50% - 60% more") == "Costs 50% - 60% more")
        #expect(rendered("  indented note  ") == "  indented note  ")
        #expect(rendered("") == "")
    }

    @Test("unmatched delimiters stay visible")
    func unmatchedDelimitersStayVisible() {
        #expect(rendered("2 * 3 * 4 equals 24") == "2 * 3 * 4 equals 24")
        #expect(rendered("An unclosed **bold") == "An unclosed **bold")
    }

    @Test("rich editor renders and round-trips inline Markdown")
    @MainActor
    func richEditorRoundTripsInlineMarkdown() {
        let source = "Owner: **Priya**, *urgent*, `swift test`, [spec](https://example.com)"
        let state = EditorState()
        let coordinator = makeCoordinator(state: state)
        let textView = NSTextView(frame: .zero)

        coordinator.apply(markdown: source, to: textView)

        #expect(textView.string == "Owner: Priya, urgent, swift test, spec")
        #expect(coordinator.serializedMarkdown(from: textView) == source)
    }

    @Test("inline Markdown round-trips inside block lines")
    @MainActor
    func blockLinesRoundTripInlineMarkdown() {
        let source = "# **Decision**\n- Ship *today*\n1. Read `spec`"
        let state = EditorState()
        let coordinator = makeCoordinator(state: state)
        let textView = NSTextView(frame: .zero)

        coordinator.apply(markdown: source, to: textView)

        #expect(textView.string == "Decision\n• Ship today\n1. Read spec")
        #expect(coordinator.serializedMarkdown(from: textView) == source)
    }

    @Test("completed inline markers render while typing")
    @MainActor
    func completedMarkersRenderWhileTyping() {
        let state = EditorState()
        let coordinator = makeCoordinator(state: state)
        let textView = NSTextView(frame: .zero)
        coordinator.apply(markdown: "Owner: ", to: textView)
        textView.textStorage?.append(NSAttributedString(
            string: "**Priya**",
            attributes: coordinator.bodyAttributes()
        ))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        coordinator.textDidChange(Notification(
            name: NSText.didChangeNotification,
            object: textView
        ))

        #expect(textView.string == "Owner: Priya")
        #expect(coordinator.serializedMarkdown(from: textView) == "Owner: **Priya**")
    }

    @Test("bold command can remove parsed strong emphasis")
    @MainActor
    func boldCommandRemovesParsedStrongEmphasis() {
        let state = EditorState(text: "**Priya**")
        let coordinator = makeCoordinator(state: state)
        let textView = NSTextView(frame: .zero)
        coordinator.apply(markdown: state.text, to: textView)
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))

        coordinator.perform(.bold, in: textView)

        #expect(coordinator.serializedMarkdown(from: textView) == "Priya")
    }

    @Test("toolbar command is scheduled once and preserves multi-line selection")
    @MainActor
    func toolbarCommandIsScheduledOnce() async {
        let source = "Still Not showing up\nWhy\nIs this\nHappening"
        let state = EditorState(text: source)
        var changeCount = 0
        let coordinator = makeCoordinator(
            state: state,
            onTextChange: { _ in changeCount += 1 }
        )
        let textView = NSTextView(frame: .zero)
        coordinator.apply(markdown: source, to: textView)
        textView.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
        let bullet = MarkdownEditorCommand(kind: .bullet)
        state.command = bullet

        coordinator.schedule(bullet, in: textView)
        coordinator.schedule(bullet, in: textView)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(textView.string == "• Still Not showing up\n• Why\n• Is this\n• Happening")
        #expect(state.text == "- Still Not showing up\n- Why\n- Is this\n- Happening")
        #expect(changeCount == 1)
        #expect(state.command == nil)
    }

    @MainActor
    private func makeCoordinator(
        state: EditorState,
        onTextChange: ((String) -> Void)? = nil
    ) -> MarkdownRichTextEditor.Coordinator {
        MarkdownRichTextEditor.Coordinator(
            text: Binding(
                get: { state.text },
                set: { state.text = $0 }
            ),
            command: Binding(
                get: { state.command },
                set: { state.command = $0 }
            ),
            onTextChange: onTextChange
        )
    }
}
