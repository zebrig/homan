import AppKit
import Foundation
import SwiftUI
import MuesliCore

enum DashboardWindowGeometry {
    static let preferredFrameSize = NSSize(width: 1120, height: 818)
    static let screenMargin: CGFloat = 16

    static func initialFrame(in visibleFrame: NSRect) -> NSRect {
        let availableWidth = max(1, visibleFrame.width - screenMargin * 2)
        let availableHeight = max(1, visibleFrame.height - screenMargin * 2)
        let size = NSSize(
            width: min(preferredFrameSize.width, availableWidth),
            height: min(preferredFrameSize.height, availableHeight)
        )
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class RecentHistoryWindowController: NSObject, NSWindowDelegate {
    private let store: DictationStore
    private let controller: MuesliController
    private var window: NSWindow?
    private var keyMonitor: Any?

    var presentationWindow: NSWindow? {
        window
    }

    init(store: DictationStore, controller: MuesliController) {
        self.store = store
        self.controller = controller
    }

    func show() {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        controller.syncAppState()
        if !window.isVisible {
            controller.noteWindowOpened()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func reload() {
        controller.syncAppState()
    }

    func close() {
        window?.close()
    }

    func updateBackendLabel() {
        controller.syncAppState()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        controller.noteWindowClosed()
    }

    private func buildWindow() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let targetFrame = DashboardWindowGeometry.initialFrame(
            in: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 850)
        )
        let contentRect = NSWindow.contentRect(forFrameRect: targetFrame, styleMask: styleMask)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.setFrame(targetFrame, display: false)
        window.contentMinSize = NSSize(
            width: min(900, contentRect.width),
            height: min(520, contentRect.height)
        )
        window.title = AppIdentity.displayName
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1) // #111214

        let rootView = DashboardRootView(
            appState: controller.appState,
            controller: controller
        )
        window.contentView = NSHostingView(rootView: rootView)

        self.window = window

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "f" else {
                return event
            }
            self.controller.appState.focusSearchField = true
            return nil
        }
    }
}
