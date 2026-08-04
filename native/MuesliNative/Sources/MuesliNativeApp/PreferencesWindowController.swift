import AppKit
import Foundation
import MuesliCore

@MainActor
final class PreferencesWindowController: NSObject {
    private let controller: MuesliController

    init(controller: MuesliController) {
        self.controller = controller
    }

    func show() {
        controller.openHistoryWindow(tab: .settings)
    }

    func refresh() {
        controller.syncAppState()
    }
}
