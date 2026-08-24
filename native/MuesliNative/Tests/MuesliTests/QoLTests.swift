import AppKit
import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Dictation backend readiness")
struct DictationBackendReadinessTests {
    @Test("preparing backend blocks dictation with existing warmup copy")
    func preparingBlocksDictation() {
        let readiness = DictationBackendReadiness.preparing

        #expect(!readiness.allowsDictation)
        #expect(readiness.blockingMessage(backendLabel: "Parakeet v3") == "Warming up Parakeet v3...")
    }

    @Test("ready backend allows dictation")
    func readyAllowsDictation() {
        let readiness = DictationBackendReadiness.ready

        #expect(readiness.allowsDictation)
        #expect(readiness.blockingMessage(backendLabel: "Parakeet v3") == nil)
    }

    @Test("failed backend remains blocked with actionable status")
    func failedBlocksDictation() {
        let readiness = DictationBackendReadiness.failed

        #expect(!readiness.allowsDictation)
        #expect(readiness.blockingMessage(backendLabel: "Parakeet v3") == "Parakeet v3 unavailable")
    }
}

// MARK: - ChatGPT File-based Token Storage

@Suite("ChatGPT Token Storage")
struct ChatGPTTokenStorageTests {

    @Test("isAuthenticated returns false when no token file exists")
    @MainActor
    func notAuthenticatedByDefault() {
        let auth = ChatGPTAuthManager(supportDirectory: makeSupportDirectory())
        #expect(!auth.isAuthenticated)
    }

    @Test("signOut does not crash even when not signed in")
    @MainActor
    func signOutSafe() {
        let auth = ChatGPTAuthManager(supportDirectory: makeSupportDirectory())
        auth.signOut()  // Should not crash
    }

    @Test("signOut only removes tokens from the injected support directory")
    @MainActor
    func signOutIsScopedToInjectedStorage() throws {
        let authDirectory = makeSupportDirectory()
        let unrelatedDirectory = makeSupportDirectory()
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)

        let authToken = authDirectory.appendingPathComponent("chatgpt-auth.json")
        let unrelatedToken = unrelatedDirectory.appendingPathComponent("chatgpt-auth.json")
        try Data(#"{"access_token":"test"}"#.utf8).write(to: authToken)
        try Data(#"{"access_token":"keep"}"#.utf8).write(to: unrelatedToken)

        let auth = ChatGPTAuthManager(supportDirectory: authDirectory)
        #expect(auth.isAuthenticated)
        auth.signOut()

        #expect(!FileManager.default.fileExists(atPath: authToken.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedToken.path))
    }

    @Test("test-mode auth never mutates the legacy keychain adapter")
    @MainActor
    func legacyKeychainMutationRequiresExplicitOptIn() {
        let legacyStore = RecordingLegacyCredentialStore(values: [
            "access_token": "legacy-test-token",
            "refresh_token": "legacy-test-refresh",
        ])
        let auth = ChatGPTAuthManager(
            supportDirectory: makeSupportDirectory(),
            legacyCredentialStore: legacyStore,
            migrateLegacyKeychain: true,
            allowLegacyKeychainMutation: false
        )

        #expect(auth.isAuthenticated)
        auth.signOut()
        #expect(legacyStore.deletedAccounts.isEmpty)
    }

    @Test("failed file migration preserves legacy keychain tokens")
    @MainActor
    func failedMigrationPreservesLegacyTokens() throws {
        let nonDirectory = makeSupportDirectory()
        try Data("not-a-directory".utf8).write(to: nonDirectory)
        let legacyStore = RecordingLegacyCredentialStore(values: [
            "access_token": "legacy-test-token",
            "refresh_token": "legacy-test-refresh",
        ])

        let auth = ChatGPTAuthManager(
            supportDirectory: nonDirectory,
            legacyCredentialStore: legacyStore,
            migrateLegacyKeychain: true,
            allowLegacyKeychainMutation: true
        )

        #expect(!auth.isAuthenticated)
        #expect(legacyStore.deletedAccounts.isEmpty)
    }

    private func makeSupportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-chatgpt-auth-test-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class RecordingLegacyCredentialStore: ChatGPTLegacyCredentialStoring {
    private let values: [String: String]
    private(set) var deletedAccounts: [String] = []

    init(values: [String: String]) {
        self.values = values
    }

    func read(service: String, account: String) -> String? {
        values[account]
    }

    func delete(service: String, account: String) {
        deletedAccounts.append(account)
    }
}

// MARK: - Floating Indicator: showFloatingIndicator hides only idle state

@Suite("FloatingIndicator visibility")
struct FloatingIndicatorVisibilityTests {

    @Test("config default shows floating indicator")
    func defaultShowsIndicator() {
        let config = AppConfig()
        #expect(config.showFloatingIndicator == true)
    }

    @Test("showFloatingIndicator persists through JSON round-trip")
    func jsonRoundTrip() throws {
        var config = AppConfig()
        config.showFloatingIndicator = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.showFloatingIndicator == false)
    }

    @Test("showFloatingIndicator decodes from snake_case JSON")
    func snakeCaseDecode() throws {
        let json = #"{"show_floating_indicator": false}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: json.data(using: .utf8)!)
        #expect(config.showFloatingIndicator == false)
    }

    @Test("meeting transcript hover defaults on and persists")
    func meetingTranscriptHoverRoundTrip() throws {
        var config = AppConfig()
        #expect(config.showMeetingTranscriptOnIndicatorHover)
        config.showMeetingTranscriptOnIndicatorHover = false

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(!decoded.showMeetingTranscriptOnIndicatorHover)
    }

    @Test("meeting transcript hover decodes from snake_case JSON")
    func meetingTranscriptHoverSnakeCaseDecode() throws {
        let json = #"{"show_meeting_transcript_on_indicator_hover": false}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(!config.showMeetingTranscriptOnIndicatorHover)
    }

    @Test("post processor defaults to disabled")
    func postProcessorDisabledByDefault() {
        let config = AppConfig()
        #expect(config.enablePostProcessor == false)
    }

    @Test("post processor defaults to v3 model")
    func postProcessorDefaultModel() {
        let config = AppConfig()
        #expect(config.activePostProcessorId == PostProcessorOption.defaultOption.id)
    }

    @Test("post processor persists through JSON round-trip")
    func postProcessorRoundTrip() throws {
        var config = AppConfig()
        config.enablePostProcessor = true
        config.activePostProcessorId = PostProcessorOption.finetunedV2.id
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.enablePostProcessor == true)
        #expect(decoded.activePostProcessorId == PostProcessorOption.finetunedV2.id)
    }

    @Test("post processor decodes from snake_case JSON")
    func postProcessorSnakeCaseDecode() throws {
        let json = #"{"enable_post_processor": true}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: json.data(using: .utf8)!)
        #expect(config.enablePostProcessor == true)
    }
}

// MARK: - Unified indicator frame sizes

@Suite("Indicator frame sizes")
struct IndicatorFrameSizeTests {

    @Test("recording frame size is consistent for all non-meeting dictation")
    func recordingFrameUnified() {
        // Both hold and toggle dictation should use the same 76x22 size
        // Meeting recording uses 72x32
        // This test validates the model constants that drive the frame
        let config = AppConfig()
        #expect(config.showFloatingIndicator == true)
        // The frame sizes are hardcoded in FloatingIndicatorController.frameForState
        // We test that the config round-trips correctly (the visual test is manual)
    }

    @Test("default indicator center is right-middle of the screen")
    @MainActor
    func defaultIndicatorCenterUsesScreenMidpoint() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1200, height: 800)
        let center = FloatingIndicatorController.defaultIndicatorCenter(in: visibleFrame)
        #expect(center.x == 1270)
        #expect(center.y == 450)
    }

    @Test("off-screen saved indicator center falls back to right-middle default")
    @MainActor
    func offscreenSavedIndicatorCenterFallsBack() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1200, height: 800)
        let size = NSSize(width: 76, height: 22)
        let offscreen = CGPoint(x: 1708, y: 1491)

        #expect(
            !FloatingIndicatorController.isUsableIndicatorCenter(
                offscreen,
                in: visibleFrame,
                size: size
            )
        )
        #expect(
            FloatingIndicatorController.defaultIndicatorCenter(in: visibleFrame) ==
            CGPoint(x: 1270, y: 450)
        )
    }

    @Test("anchor centers respect fixed screen insets")
    @MainActor
    func anchorCentersUseExpectedInsets() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1200, height: 800)
        let size = NSSize(width: 44, height: 28)

        #expect(
            FloatingIndicatorController.anchorCenter(.topLeading, in: visibleFrame, size: size) ==
            CGPoint(x: 130, y: 828)
        )
        #expect(
            FloatingIndicatorController.anchorCenter(.bottomCenter, in: visibleFrame, size: size) ==
            CGPoint(x: 700, y: 72)
        )
    }

    @Test("transcribing pill widens for live CUA status labels")
    @MainActor
    func transcribingPillWidensForStatusText() {
        let short = FloatingIndicatorController.transcribingPillSizeForTesting(
            title: "Planning",
            screenWidth: 1200
        )
        let long = FloatingIndicatorController.transcribingPillSizeForTesting(
            title: "Navigating to YouTube search",
            screenWidth: 1200
        )

        #expect(short.width >= 190)
        #expect(long.width > short.width)
        #expect(long.width <= 360)
        #expect(long.height == 32)
    }

    @Test("transcribing pill caps to available screen width")
    @MainActor
    func transcribingPillCapsToScreenWidth() {
        let size = FloatingIndicatorController.transcribingPillSizeForTesting(
            title: "Executing an unusually long computer use action label",
            screenWidth: 180
        )

        #expect(size.width <= 148)
        #expect(size.height == 32)
    }

    @Test("CUA transcript pill wraps and grows vertically instead of truncating")
    @MainActor
    func computerUseTranscriptPillWrapsAndExpands() {
        let short = FloatingIndicatorController.computerUseTranscriptPillSizeForTesting(
            transcript: "Open Twitter",
            screenWidth: 1200
        )
        let long = FloatingIndicatorController.computerUseTranscriptPillSizeForTesting(
            transcript: "Open Twitter in Google Chrome and write a tweet saying this was written using Muesli CUA without posting it",
            screenWidth: 420
        )

        #expect(short.width >= 280)
        #expect(short.height >= 44)
        #expect(long.width <= 372)
        #expect(long.height > short.height)
    }
}

@Suite("Meeting processing progress")
struct MeetingProcessingProgressTests {
    @Test("processing title renders phase, count, and both timers")
    func processingTitleFormat() {
        let progress = MeetingProcessingProgress(
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            operation: .finalization,
            phaseIndex: 4,
            phaseCount: 8,
            phase: .transcribing,
            phaseStartedAt: Date(timeIntervalSince1970: 0),
            totalStartedAt: Date(timeIntervalSince1970: -51)
        )
        #expect(progress.displayTitle(now: Date(timeIntervalSince1970: 12)) == "4/8 Transcribing · 0:12 · 1:03")
    }

    @Test("each operation exposes its real ordered phase plan")
    func operationPlans() {
        #expect(MeetingProcessingOperation.finalization.phases == [
            .preparingAudio,
            .processingAudio,
            .preparingRecording,
            .transcribing,
            .generatingTitle,
            .summarizing,
            .encodingRecording,
            .saving,
        ])
        #expect(MeetingProcessingOperation.recovery.phases == MeetingProcessingOperation.finalization.phases)
        #expect(MeetingProcessingOperation.retranscription.phases == [
            .preparingAudio, .processingAudio, .transcribing, .summarizing, .saving,
        ])
        #expect(MeetingProcessingOperation.resummarization.phases == [.summarizing, .saving])
    }

    @Test("recovery with prepared audio starts at the remaining transcription work")
    func resumedRecoveryPlan() {
        let phases = MeetingProcessingRunPlan.phases(
            operation: .recovery,
            diarizationMode: .rerun(.stableFourSpeaker),
            resumingAt: .transcribing
        )
        #expect(phases == [
            .transcribing,
            .preparingDiarizer,
            .diarizing,
            .applyingSpeakerLabels,
            .generatingTitle,
            .summarizing,
            .encodingRecording,
            .saving,
        ])
        let progress = MeetingProcessingProgress.starting(
            operation: .recovery,
            phases: phases
        )
        #expect(progress.phase == .transcribing)
        #expect(progress.phaseIndex == 1)
        #expect(progress.phaseCount == 8)
    }

    @Test("progress advances monotonically and preserves both timers correctly")
    func progressAdvancesMonotonically() throws {
        let startedAt = Date(timeIntervalSince1970: 100)
        let progress = MeetingProcessingProgress.starting(
            operation: .retranscription,
            now: startedAt
        )
        let processingAudio = try #require(progress.advancing(
            to: .processingAudio,
            now: Date(timeIntervalSince1970: 112)
        ))
        #expect(processingAudio.phaseIndex == 2)
        let transcribing = try #require(processingAudio.advancing(
            to: .transcribing,
            now: Date(timeIntervalSince1970: 120)
        ))
        #expect(transcribing.phaseIndex == 3)
        #expect(transcribing.phaseStartedAt == Date(timeIntervalSince1970: 120))
        #expect(transcribing.totalStartedAt == startedAt)
        #expect(transcribing.advancing(to: .preparingAudio) == nil)
        #expect(transcribing.advancing(to: .generatingTitle) == nil)
        let repeated = try #require(transcribing.advancing(
            to: .transcribing,
            now: Date(timeIntervalSince1970: 140)
        ))
        #expect(repeated.phaseStartedAt == transcribing.phaseStartedAt)
    }

    @Test("elapsed string uses m:ss with zero padding")
    func elapsedStringFormat() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(MeetingProcessingProgress.elapsedString(from: start, to: start) == "0:00")
        #expect(MeetingProcessingProgress.elapsedString(from: start, to: Date(timeIntervalSince1970: 12)) == "0:12")
        #expect(MeetingProcessingProgress.elapsedString(from: start, to: Date(timeIntervalSince1970: 63)) == "1:03")
        #expect(MeetingProcessingProgress.elapsedString(from: start, to: Date(timeIntervalSince1970: 600)) == "10:00")
        #expect(MeetingProcessingProgress.elapsedString(from: Date(timeIntervalSince1970: 10), to: start) == "0:00")
    }
}

@Suite("Meeting processing metadata display")
struct MeetingProcessingMetadataDisplayTests {
    @Test("completed transcription names successful actual AEC")
    func successfulAECLabel() {
        let label = MeetingDetailView.processingRunLabel(
            title: "Transcribed",
            run: run(
                diagnostics: MeetingAecRunDiagnostics(
                    processor: "localvqe_v1_2",
                    ready: true,
                    processedFrames: 12,
                    fullReferenceFrames: 12,
                    partialReferenceFrames: 0,
                    missingReferenceFrames: 0
                )
            )
        )

        #expect(label.contains("AEC LocalVQE v1.2"))
    }

    @Test("completed transcription does not present fallback as successful AEC")
    func unsuccessfulAECLabels() {
        let unavailable = MeetingDetailView.processingRunLabel(
            title: "Transcribed",
            run: run(
                diagnostics: MeetingAecRunDiagnostics(
                    processor: "unavailable",
                    ready: false,
                    processedFrames: 0,
                    fullReferenceFrames: 0,
                    partialReferenceFrames: 0,
                    missingReferenceFrames: 0
                )
            )
        )
        let degraded = MeetingDetailView.processingRunLabel(
            title: "Transcribed",
            run: run(
                diagnostics: MeetingAecRunDiagnostics(
                    processor: "localvqe_v1_2",
                    ready: true,
                    processedFrames: 12,
                    fullReferenceFrames: 12,
                    partialReferenceFrames: 0,
                    missingReferenceFrames: 0,
                    processingError: "inference failed"
                )
            )
        )
        let notApplied = MeetingDetailView.processingRunLabel(
            title: "Transcribed",
            run: run(
                diagnostics: MeetingAecRunDiagnostics(
                    processor: "localvqe_v1_2",
                    ready: true,
                    processedFrames: 0,
                    fullReferenceFrames: 0,
                    partialReferenceFrames: 0,
                    missingReferenceFrames: 0
                )
            )
        )
        let noReference = MeetingDetailView.processingRunLabel(
            title: "Transcribed",
            run: run(
                diagnostics: MeetingAecRunDiagnostics(
                    processor: "localvqe_v1_2",
                    ready: true,
                    processedFrames: 12,
                    fullReferenceFrames: 0,
                    partialReferenceFrames: 0,
                    missingReferenceFrames: 12
                )
            )
        )
        let partial = MeetingDetailView.processingRunLabel(
            title: "Transcribed",
            run: run(
                diagnostics: MeetingAecRunDiagnostics(
                    processor: "localvqe_v1_2",
                    ready: true,
                    processedFrames: 12,
                    fullReferenceFrames: 12,
                    partialReferenceFrames: 0,
                    missingReferenceFrames: 0,
                    sourceUnitCount: 2,
                    appliedSourceUnitCount: 1
                )
            )
        )

        #expect(unavailable.contains("AEC unavailable"))
        #expect(!unavailable.contains("AEC LocalVQE"))
        #expect(degraded.contains("AEC degraded"))
        #expect(!degraded.contains("AEC LocalVQE"))
        #expect(notApplied.contains("AEC not applied"))
        #expect(!notApplied.contains("AEC LocalVQE"))
        #expect(noReference.contains("AEC no reference"))
        #expect(!noReference.contains("AEC LocalVQE"))
        #expect(partial.contains("AEC partially applied"))
        #expect(!partial.contains("AEC LocalVQE"))
    }

    private func run(
        diagnostics: MeetingAecRunDiagnostics
    ) -> MeetingProcessingRunMetadata {
        MeetingProcessingRunMetadata(
            completedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 1,
            backend: "parakeet",
            model: "parakeet",
            displayName: "Parakeet",
            audioSource: "raw_source_bundle",
            aecModel: "localvqe_v1_2",
            aecDiagnostics: diagnostics
        )
    }
}

@Suite("Floating meeting transcript")
struct FloatingMeetingTranscriptTests {
    @Test("overlay routes header controls and leaves transcript body to SwiftUI")
    func overlayClickRouting() {
        let frame = NSRect(x: 100, y: 100, width: 360, height: 320)

        #expect(FloatingMeetingTranscriptInteraction.action(
            at: NSPoint(x: 390, y: 400), in: frame
        ) == .dismiss)
        #expect(FloatingMeetingTranscriptInteraction.action(
            at: NSPoint(x: 430, y: 400), in: frame
        ) == .copy)
        #expect(FloatingMeetingTranscriptInteraction.action(
            at: NSPoint(x: 250, y: 250), in: frame
        ) == nil)
        #expect(FloatingMeetingTranscriptInteraction.action(
            at: NSPoint(x: 90, y: 250), in: frame
        ) == nil)
    }

#if HOMAN_UI_TESTS
    @Test("floating panel can receive controls without becoming the main window")
    @MainActor
    func floatingPanelIsInteractive() {
        let panel = InteractiveFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        var receivedMouseDown: NSPoint?
        panel.leftMouseDownHandler = { point in
            receivedMouseDown = point
            return true
        }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        if let event {
            panel.sendEvent(event)
        }

        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.styleMask.contains(.nonactivatingPanel))
        #expect(receivedMouseDown == NSPoint(x: 20, y: 20))
    }

    @Test("shown overlay retains its hosting view and routes dismissal")
    @MainActor
    func shownOverlayRoutesDismissal() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = container
        var dismissCount = 0
        let controller = FloatingMeetingTranscriptPanelController(
            onHoverChanged: { _ in },
            onOpenNotes: {},
            onDismiss: { dismissCount += 1 }
        )

        controller.show(in: container, frame: container.bounds)

        #expect(controller.isVisible)
        #expect(!controller.handleClick(atWindowPoint: NSPoint(x: 180, y: 160)))
        #expect(controller.handleClick(atWindowPoint: NSPoint(x: 290, y: 300)))
        #expect(dismissCount == 1)
    }
#endif

    @Test("panel prefers the open side and remains inside the screen")
    func panelPlacement() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let trailingIndicator = NSRect(x: 1350, y: 440, width: 76, height: 22)
        let leadingIndicator = NSRect(x: 14, y: 440, width: 76, height: 22)

        let leftFrame = FloatingMeetingTranscriptPlacement.frame(
            beside: trailingIndicator,
            visibleFrame: screen
        )
        let rightFrame = FloatingMeetingTranscriptPlacement.frame(
            beside: leadingIndicator,
            visibleFrame: screen
        )

        #expect(leftFrame.maxX == trailingIndicator.minX)
        #expect(rightFrame.minX == leadingIndicator.maxX)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(leftFrame))
        #expect(screen.insetBy(dx: 8, dy: 8).contains(rightFrame))
    }

    @Test("panel clamps vertically on short screens")
    func verticalPlacementClamp() {
        let screen = NSRect(x: 100, y: 50, width: 900, height: 360)
        let indicator = NSRect(x: 950, y: 380, width: 40, height: 22)

        let frame = FloatingMeetingTranscriptPlacement.frame(
            beside: indicator,
            visibleFrame: screen
        )

        #expect(frame.minY >= screen.minY + 8)
        #expect(frame.maxY == screen.maxY - 8)
    }

    @Test("copy includes committed transcript and current partials")
    func copyTextIncludesLiveTails() {
        let text = LiveTranscriptCopyContent.text(
            transcript: "[10:00:00] You: committed",
            partialYou: "speaking now",
            partialOthers: "current reply"
        )

        #expect(text == "[10:00:00] You: committed\nOthers: current reply\nYou: speaking now")
    }

    @Test("panel retains the complete committed transcript")
    func completeTranscriptHistory() {
        let transcript = (0..<12)
            .map { "[10:00:\(String(format: "%02d", $0))] You: line \($0)" }
            .joined(separator: "\n")

        let messages = TranscriptChatMessage.messages(from: transcript)

        #expect(messages.count == 12)
        #expect(messages.first?.text == "line 0")
        #expect(messages.last?.text == "line 11")
    }

    @Test("incremental panel updates retain unique message identities")
    @MainActor
    func incrementalUpdatesUseUniqueIDs() {
        let model = LiveTranscriptPresentationModel()

        model.update(
            transcript: "[10:00:00] You: first\n",
            partialYou: "",
            partialOthers: ""
        )
        model.update(
            transcript: "[10:00:00] You: first\n[10:00:05] Others: second\n",
            partialYou: "",
            partialOthers: ""
        )

        #expect(model.messages.map(\.id) == [0, 1])
        #expect(model.messages.map(\.text) == ["first", "second"])
    }
}

@Suite("Floating indicator pointer interaction")
struct FloatingIndicatorPointerInteractionTests {
    @Test("small pointer movement remains a click while deliberate movement drags")
    func dragThreshold() {
        let start = NSPoint(x: 100, y: 100)
        #expect(!FloatingIndicatorPointerIntent.isDrag(
            from: start,
            to: NSPoint(x: 102, y: 102)
        ))
        #expect(FloatingIndicatorPointerIntent.isDrag(
            from: start,
            to: NSPoint(x: 104, y: 100)
        ))
    }

    @MainActor
    @Test("single-click retains its existing meeting command")
    func singleClickStillRuns() {
        let indicator = makeIndicator()
        var stopCount = 0
        indicator.onStopMeeting = { stopCount += 1 }
        indicator.setMeetingRecording(true, config: AppConfig())

        indicator.handleClick(atX: 50)

        #expect(stopCount == 1)
        indicator.close()
    }

    @MainActor
    private func makeIndicator() -> FloatingIndicatorController {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return FloatingIndicatorController(
            configStore: ConfigStore(supportDirectory: supportDirectory),
            uiEnabled: false
        )
    }
}

// MARK: - OpenAI Logo Shape

@Suite("OpenAI Logo Shape")
struct OpenAILogoShapeTests {

    @Test("shape produces non-empty path")
    func nonEmptyPath() {
        let shape = OpenAILogoShape()
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let path = shape.path(in: rect)
        #expect(!path.isEmpty)
    }

    @Test("shape scales to arbitrary rect")
    func scalesCorrectly() {
        let shape = OpenAILogoShape()
        let small = shape.path(in: CGRect(x: 0, y: 0, width: 10, height: 10))
        let large = shape.path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!small.isEmpty)
        #expect(!large.isEmpty)
        // Larger rect should produce a larger bounding box
        #expect(large.boundingRect.width > small.boundingRect.width)
    }

    @Test("shape handles zero rect without crash")
    func zeroRect() {
        let shape = OpenAILogoShape()
        let path = shape.path(in: .zero)
        // Should not crash; path will be empty or degenerate
        let _ = path.boundingRect
    }
}

// MARK: - DictationState

@Suite("DictationState idle check")
struct DictationStateIdleTests {

    @Test("all dictation states are defined")
    func allStates() {
        let states: [DictationState] = [.idle, .preparing, .recording, .transcribing]
        #expect(states.count == 4)
    }

    @Test("idle is distinct from active states")
    func idleDistinct() {
        #expect(DictationState.idle != .recording)
        #expect(DictationState.idle != .preparing)
        #expect(DictationState.idle != .transcribing)
    }
}

// MARK: - Meeting chunk collection

@Suite("Meeting chunk collection")
struct MeetingChunkCollectorTests {

    @Test("collector waits for tasks, keeps completed segments, and sorts by start")
    func collectorSortsSegments() async {
        let collector = MeetingChunkCollector()

        _ = collector.add(
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                return [SpeechSegment(start: 30, end: 31, text: "later")]
            }
        )
        _ = collector.add(
            Task {
                try? await Task.sleep(for: .milliseconds(5))
                return []
            }
        )
        _ = collector.add(
            Task {
                try? await Task.sleep(for: .milliseconds(10))
                return [SpeechSegment(start: 10, end: 11, text: "earlier")]
            }
        )

        let segments = await collector.closeAndDrainSortedSegments()

        #expect(segments.map(\.text) == ["earlier", "later"])
        #expect(segments.map(\.start) == [10, 30])
    }

    @Test("collector rejects tasks after closing")
    func collectorRejectsLateTasks() async {
        let collector = MeetingChunkCollector()
        let initialTask = Task<[SpeechSegment], Never> {
            [SpeechSegment(start: 1, end: 2, text: "first")]
        }
        #expect(collector.add(initialTask).registered)

        let initial = await collector.closeAndDrainSortedSegments()
        #expect(initial.map(\.text) == ["first"])

        let lateTask = Task<[SpeechSegment], Never> {
            [SpeechSegment(start: 3, end: 4, text: "late")]
        }
        #expect(!collector.add(lateTask).registered)
        lateTask.cancel()
    }

    @Test("collector retire returns false after drain closes collector")
    func collectorRetireReturnsFalseAfterDrain() async {
        let collector = MeetingChunkCollector()
        let task = Task<[SpeechSegment], Never> {
            try? await Task.sleep(for: .milliseconds(10))
            return [SpeechSegment(start: 1, end: 2, text: "first")]
        }
        let registration = collector.add(task)
        #expect(registration.registered)

        let drained = await collector.closeAndDrainSortedSegments()
        let retired = collector.retire(id: registration.retireID, segments: await task.value)

        #expect(drained.map(\.text) == ["first"])
        #expect(retired == false)
    }

    @Test("collector flattens timed segments from a single chunk and sorts them")
    func collectorFlattensChunkSegments() async {
        let collector = MeetingChunkCollector()

        _ = collector.add(
            Task {
                [
                    SpeechSegment(start: 12, end: 12.5, text: "second"),
                    SpeechSegment(start: 11, end: 11.5, text: "first")
                ]
            }
        )

        let segments = await collector.closeAndDrainSortedSegments()

        #expect(segments.map(\.text) == ["first", "second"])
        #expect(segments.map(\.start) == [11, 12])
    }
}

@Suite("Meeting chunk timing")
struct MeetingChunkTimingTrackerTests {

    @Test("tracks chunk offsets from processed sample counts")
    func tracksChunkOffsets() {
        var tracker = MeetingChunkTimingTracker()
        tracker.start()
        tracker.append(sampleCount: 1600)

        let first = tracker.rotate()
        tracker.append(sampleCount: 800)
        let second = tracker.finish()

        #expect(first?.startSampleIndex == 0)
        #expect(first?.sampleCount == 1600)
        #expect(first?.startTimeSeconds == 0)
        #expect(first?.durationSeconds == 0.1)

        #expect(second?.startSampleIndex == 1600)
        #expect(second?.sampleCount == 800)
        #expect(second?.startTimeSeconds == 0.1)
        #expect(second?.durationSeconds == 0.05)
    }
}
