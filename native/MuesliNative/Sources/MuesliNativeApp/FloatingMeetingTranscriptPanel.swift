import AppKit
import Observation
import SwiftUI

enum FloatingMeetingTranscriptPlacement {
    static let panelSize = NSSize(width: 360, height: 320)
    static let enablePanelSize = NSSize(width: 230, height: 76)
    static let gap: CGFloat = 0
    static let screenInset: CGFloat = 8

    static func frame(
        beside indicatorFrame: NSRect,
        panelSize: NSSize = panelSize,
        visibleFrame: NSRect
    ) -> NSRect {
        let availableOnLeft = indicatorFrame.minX - visibleFrame.minX
        let availableOnRight = visibleFrame.maxX - indicatorFrame.maxX
        let prefersLeft = availableOnLeft >= panelSize.width + gap || availableOnLeft >= availableOnRight
        let proposedX = prefersLeft
            ? indicatorFrame.minX - gap - panelSize.width
            : indicatorFrame.maxX + gap
        let minX = visibleFrame.minX + screenInset
        let maxX = max(minX, visibleFrame.maxX - screenInset - panelSize.width)
        let minY = visibleFrame.minY + screenInset
        let maxY = max(minY, visibleFrame.maxY - screenInset - panelSize.height)
        return NSRect(
            x: min(max(proposedX, minX), maxX),
            y: min(max(indicatorFrame.midY - panelSize.height / 2, minY), maxY),
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

enum FloatingMeetingTranscriptInteraction: Equatable {
    case dismiss
    case copy
    case openMeeting
    case stopLive

    static func action(at point: NSPoint, in panelFrame: NSRect) -> Self? {
        guard panelFrame.contains(point) else { return nil }
        let headerMinY = panelFrame.maxY - 42
        guard point.y >= headerMinY else { return nil }

        if point.x >= panelFrame.maxX - 48 {
            return .copy
        }
        if point.x >= panelFrame.maxX - 72 {
            return .dismiss
        }
        if point.x >= panelFrame.maxX - 200 {
            return .stopLive
        }
        return .openMeeting
    }
}

@MainActor
@Observable
final class FloatingMeetingTranscriptModel {
    let presentation = LiveTranscriptPresentationModel()
    var isPaused = false
    var isPresented = false
    var didCopy = false
    /// When false the panel shows a compact "start live captions" view instead
    /// of the transcript feed.
    var isLiveActive = true

    func update(transcript: String, partialYou: String, partialOthers: String) {
        presentation.update(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    func copyToPasteboard() {
        let text = LiveTranscriptCopyContent.text(
            transcript: presentation.transcript,
            partialYou: presentation.partialYou,
            partialOthers: presentation.partialOthers
        )
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopyConfirmation()
    }

    func reset() {
        presentation.reset()
        isPaused = false
        isPresented = false
        didCopy = false
    }

    func showCopyConfirmation() {
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.didCopy = false
        }
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class FloatingMeetingTranscriptPanelController {
    private let model = FloatingMeetingTranscriptModel()
    private let onHoverChanged: (Bool) -> Void
    private let onOpenNotes: () -> Void
    private let onDismiss: () -> Void
    var onEnableLive: (() -> Void)?
    var onDisableLive: (() -> Void)?
    private var hostingView: FirstMouseHostingView<FloatingMeetingTranscriptPanelView>?

    init(
        onHoverChanged: @escaping (Bool) -> Void,
        onOpenNotes: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onHoverChanged = onHoverChanged
        self.onOpenNotes = onOpenNotes
        self.onDismiss = onDismiss
    }

    func setLiveActive(_ active: Bool) {
        model.isLiveActive = active
    }

    var isVisible: Bool {
        hostingView?.superview != nil && hostingView?.isHidden == false
    }

    func update(transcript: String, partialYou: String, partialOthers: String) {
        model.update(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    func setPaused(_ paused: Bool) {
        model.isPaused = paused
    }

    func show(in containerView: NSView, frame: NSRect) {
        let hostingView = hostingView ?? makeHostingView()
        self.hostingView = hostingView
        if hostingView.superview !== containerView {
            hostingView.removeFromSuperview()
            containerView.addSubview(hostingView)
        }
        hostingView.frame = frame
        hostingView.isHidden = false
        model.isPresented = true
    }

    func hide() {
        model.isPresented = false
        hostingView?.isHidden = true
        hostingView?.removeFromSuperview()
    }

    func reset() {
        hide()
        model.reset()
    }

    func close() {
        model.isPresented = false
        hostingView?.removeFromSuperview()
        hostingView = nil
    }

    func containsMouseLocation() -> Bool {
        screenFrame?.contains(NSEvent.mouseLocation) == true
    }

    private var screenFrame: NSRect? {
        guard isVisible, let hostingView, let window = hostingView.window else { return nil }
        let frameInWindow = hostingView.convert(hostingView.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    @discardableResult
    func handleClick(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard isVisible, let hostingView else { return false }
        // The compact "start live captions" view handles its own button; don't
        // intercept header-region clicks here.
        guard model.isLiveActive else { return false }
        let localPoint = hostingView.convert(windowPoint, from: nil)
        let interactionPoint = hostingView.isFlipped
            ? NSPoint(
                x: localPoint.x,
                y: hostingView.bounds.maxY - (localPoint.y - hostingView.bounds.minY)
            )
            : localPoint
        guard let interaction = FloatingMeetingTranscriptInteraction.action(
            at: interactionPoint,
            in: hostingView.bounds
        ) else { return false }

        switch interaction {
        case .dismiss:
            onDismiss()
        case .copy:
            copyTranscript()
        case .openMeeting:
            onOpenNotes()
        case .stopLive:
            onDisableLive?()
        }
        return true
    }

    private func copyTranscript() {
        model.copyToPasteboard()
    }

    private func makeHostingView() -> FirstMouseHostingView<FloatingMeetingTranscriptPanelView> {
        let hostingView = FirstMouseHostingView(
            rootView: FloatingMeetingTranscriptPanelView(
                model: model,
                onHoverChanged: onHoverChanged,
                onOpenNotes: onOpenNotes,
                onDismiss: onDismiss,
                onEnableLive: { [weak self] in self?.onEnableLive?() },
                onDisableLive: { [weak self] in self?.onDisableLive?() }
            )
        )
        hostingView.wantsLayer = true
        return hostingView
    }
}

private struct FloatingMeetingTranscriptPanelView: View {
    let model: FloatingMeetingTranscriptModel
    let onHoverChanged: (Bool) -> Void
    let onOpenNotes: () -> Void
    let onDismiss: () -> Void
    let onEnableLive: () -> Void
    let onDisableLive: () -> Void

    private var partialYou: String {
        model.presentation.partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var partialOthers: String {
        model.presentation.partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var messages: [TranscriptChatMessage] {
        model.presentation.messages
    }

    private var copyText: String {
        LiveTranscriptCopyContent.text(
            transcript: model.presentation.transcript,
            partialYou: model.presentation.partialYou,
            partialOthers: model.presentation.partialOthers
        )
    }

    var body: some View {
        if model.isPresented {
            Group {
                if model.isLiveActive {
                    liveTranscriptBody
                } else {
                    enableLiveBody
                }
            }
            .frame(
                width: model.isLiveActive
                    ? FloatingMeetingTranscriptPlacement.panelSize.width
                    : FloatingMeetingTranscriptPlacement.enablePanelSize.width,
                height: model.isLiveActive
                    ? FloatingMeetingTranscriptPlacement.panelSize.height
                    : FloatingMeetingTranscriptPlacement.enablePanelSize.height
            )
            .background(.ultraThinMaterial)
            .background(MuesliTheme.backgroundRaised.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            }
            .onHover(perform: onHoverChanged)
        }
    }

    private var liveTranscriptBody: some View {
        VStack(spacing: 0) {
            header
            Divider().background(MuesliTheme.surfaceBorder)
            transcript
        }
    }

    private var enableLiveBody: some View {
        VStack(spacing: 8) {
            Button(action: onEnableLive) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Start live captions")
                        .font(MuesliTheme.callout().weight(.medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(MuesliTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Show this meeting's live transcript beside the pill")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Text("Live transcript")
                .font(MuesliTheme.callout().weight(.semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Button(action: onDisableLive) {
                Label("Stop captions", systemImage: "waveform.badge.minus")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.recording)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Stop live captions")
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide live transcript")
            Button(action: copyTranscript) {
                Image(systemName: model.didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.didCopy ? MuesliTheme.success : MuesliTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(copyText.isEmpty)
            .help("Copy transcript")
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .frame(height: 42)
    }

    private var transcript: some View {
        ScrollView {
            LiveTranscriptFeedView(
                messages: messages,
                partialYou: partialYou,
                partialOthers: partialOthers,
                horizontalPadding: MuesliTheme.spacing12,
                topPadding: MuesliTheme.spacing8,
                bottomPadding: MuesliTheme.spacing8,
                onOpen: onOpenNotes
            )
        }
        .defaultScrollAnchor(.bottom)
    }

    private func copyTranscript() {
        model.copyToPasteboard()
    }

}
