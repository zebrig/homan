import Testing
import AppKit
@testable import MuesliNativeApp

@Suite("PasteController — isolated clipboard and production scheduling", .serialized)
@MainActor
struct PasteControllerTests {
    private let clipboardPollInterval: TimeInterval = 0.05
    private let clipboardRestoreTimeout: TimeInterval = 2.0

    @Test("typeText with empty string does not post an event")
    func typeTextEmpty() {
        PasteController.typeText("")
    }

    @Test("common ASCII text uses physical keyboard path")
    func commonASCIIUsesPhysicalKeyboardPath() {
        #expect(PasteController.canTypeUsingPhysicalKeys("Hello, world! 123"))
        #expect(PasteController.canTypeUsingPhysicalKeys("this has been created using computer use"))
        #expect(!PasteController.canTypeUsingPhysicalKeys("नमस्ते"))
    }

    @Test("UTF-16 encoding of SentencePiece leading-space deltas is correct")
    func sentencePieceLeadingSpaceUTF16() {
        let delta = " hello"
        let utf16 = Array(delta.utf16)
        #expect(utf16.first == UInt16((" " as Unicode.Scalar).value))
        #expect(utf16.count == delta.count)
        let roundTripped = utf16.map { Character(Unicode.Scalar($0)!) }
        #expect(String(roundTripped) == delta)
    }

    @Test("UTF-16 round-trip for multi-word streaming deltas")
    func multiWordDeltaEncoding() {
        let deltas = [" world", " how are you", " testing one two"]
        for delta in deltas {
            let utf16 = Array(delta.utf16)
            let decoded = String(utf16.map { Character(Unicode.Scalar($0)!) })
            #expect(decoded == delta, "Round-trip failed for: \(delta)")
        }
    }

    @Test("paste with empty string is a no-op")
    func pasteEmptyIsNoOp() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "", pasteboard: pasteboard, simulatePasteAction: { true })

        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test("paste temporarily writes text then restores through production scheduling")
    func pasteWritesTextToClipboard() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: { true })

        #expect(pasteboard.string(forType: .string) == "dictated text")
        let restored = await waitForClipboardString(in: pasteboard, expected: "original")
        #expect(restored == "original")
    }

    @Test("paste restores clipboard after delay")
    func pasteRestoresClipboard() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("user-copied-text", forType: .string)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: { true })
        let restored = await waitForClipboardString(in: pasteboard, expected: "user-copied-text")

        #expect(restored == "user-copied-text")
    }

    @Test("paste restores empty clipboard state")
    func pasteRestoresEmptyClipboard() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: { true })
        let restored = await waitForClipboardString(in: pasteboard, expected: nil)

        #expect(restored == nil)
    }

    @Test("paste restores multi-item clipboard")
    func pasteRestoresMultiItemClipboard() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let item1 = NSPasteboardItem()
        item1.setString("item-one", forType: .string)
        let item2 = NSPasteboardItem()
        item2.setString("item-two", forType: .string)
        pasteboard.writeObjects([item1, item2])
        #expect(pasteboard.pasteboardItems?.count == 2)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: { true })
        let (countAfter, texts) = await waitForClipboardItems(
            in: pasteboard,
            expectedCount: 2,
            expectedStrings: ["item-one", "item-two"]
        )

        #expect(countAfter == 2)
        #expect(texts == ["item-one", "item-two"])
    }

    @Test("stale paste restore does not overwrite newer clipboard contents")
    func stalePasteRestoreDoesNotOverwriteNewerClipboardContents() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: { true })
        try await Task.sleep(nanoseconds: 100_000_000)
        pasteboard.clearContents()
        pasteboard.setString("user-copied-after-paste", forType: .string)
        try await Task.sleep(nanoseconds: 700_000_000)

        #expect(pasteboard.string(forType: .string) == "user-copied-after-paste")
    }

    @Test("paste arms restoration before completion bookkeeping and settles afterward")
    func pasteRestorationOwnsCriticalPath() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let events = await withCheckedContinuation { continuation in
            var events: [String] = []
            PasteController.paste(
                text: "dictated text",
                pasteboard: pasteboard,
                targetApplicationProvider: { nil },
                simulatePasteAction: { true },
                onPasteFinished: { _ in events.append("visible_state_released") },
                onClipboardSettled: {
                    events.append("clipboard_settled")
                    continuation.resume(returning: events)
                },
                onLifecycleEvent: { events.append($0.rawValue) }
            )
        }

        #expect(events == [
            "clipboard_staged",
            "target_snapshotted",
            "paste_dispatched",
            "clipboard_restore_scheduled",
            "visible_state_released",
            "clipboard_restored",
            "clipboard_settled",
        ])
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test("required ownership skips Cmd+V when another writer takes the clipboard")
    func requiredOwnershipSkipsStalePaste() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let result = await withCheckedContinuation { continuation in
            var didDispatch = false
            var finishedCount = 0
            var settledCount = 0
            var finishedApplication: NSRunningApplication?
            PasteController.paste(
                text: "dictated text",
                pasteboard: pasteboard,
                requireStagedClipboardOwnership: true,
                targetApplicationProvider: {
                    pasteboard.clearContents()
                    pasteboard.setString("newer clipboard", forType: .string)
                    return NSRunningApplication.current
                },
                simulatePasteAction: {
                    didDispatch = true
                    return true
                },
                onPasteFinished: { application in
                    finishedCount += 1
                    finishedApplication = application
                },
                onClipboardSettled: {
                    settledCount += 1
                    continuation.resume(returning: (
                        didDispatch,
                        finishedApplication,
                        finishedCount,
                        settledCount
                    ))
                }
            )
        }

        #expect(!result.0)
        #expect(result.1 == nil)
        #expect(result.2 == 1)
        #expect(result.3 == 1)
        try await Task.sleep(for: .milliseconds(650))
        #expect(pasteboard.string(forType: .string) == "newer clipboard")
    }

    @Test("failed Cmd+V setup settles once and restores the original clipboard")
    func failedPasteDispatchSettlesOnce() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let result = await withCheckedContinuation { continuation in
            var finishedCount = 0
            var settledCount = 0
            var finishedApplication: NSRunningApplication?
            PasteController.paste(
                text: "dictated text",
                pasteboard: pasteboard,
                requireStagedClipboardOwnership: true,
                targetApplicationProvider: { NSRunningApplication.current },
                simulatePasteAction: { false },
                onPasteFinished: { application in
                    finishedCount += 1
                    finishedApplication = application
                },
                onClipboardSettled: {
                    settledCount += 1
                    continuation.resume(returning: (
                        finishedApplication,
                        finishedCount,
                        settledCount,
                        pasteboard.string(forType: .string)
                    ))
                }
            )
        }

        #expect(result.0 == nil)
        #expect(result.1 == 1)
        #expect(result.2 == 1)
        #expect(result.3 == "original")
    }

    @Test("paste lifecycle diagnostics are fixed content-free categories")
    func lifecycleDiagnosticsAreContentFree() {
        #expect(PasteController.LifecycleEvent.allCases.map(\.rawValue) == [
            "clipboard_staged",
            "clipboard_stage_failed",
            "target_snapshotted",
            "paste_dispatched",
            "paste_dispatch_failed",
            "clipboard_ownership_lost",
            "clipboard_restore_scheduled",
            "clipboard_restored",
            "clipboard_restore_skipped",
        ])
    }

    private func makePasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("com.muesli.tests.PasteController.\(UUID().uuidString)")
        return NSPasteboard(name: name)
    }

    private func waitForClipboardString(in pasteboard: NSPasteboard, expected: String?) async -> String? {
        await withCheckedContinuation { continuation in
            let deadline = Date().addingTimeInterval(clipboardRestoreTimeout)
            var poll: (() -> Void)?
            poll = {
                let current = pasteboard.string(forType: .string)
                if current == expected || Date() >= deadline {
                    continuation.resume(returning: current)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + clipboardPollInterval) {
                    poll?()
                }
            }
            DispatchQueue.main.async { poll?() }
        }
    }

    private func waitForClipboardItems(
        in pasteboard: NSPasteboard,
        expectedCount: Int,
        expectedStrings: [String]
    ) async -> (Int, [String]) {
        await withCheckedContinuation { continuation in
            let deadline = Date().addingTimeInterval(clipboardRestoreTimeout)
            var poll: (() -> Void)?
            poll = {
                let items = pasteboard.pasteboardItems ?? []
                let count = items.count
                let strings = items.compactMap { $0.string(forType: .string) }
                if (count == expectedCount && strings == expectedStrings) || Date() >= deadline {
                    continuation.resume(returning: (count, strings))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + clipboardPollInterval) {
                    poll?()
                }
            }
            DispatchQueue.main.async { poll?() }
        }
    }
}
