import SwiftUI
import MuesliCore

private enum MeetingDocumentMode: Hashable {
    case notes
    case transcript
}

private enum RecordingContentMode: Hashable {
    case notes
    case live
}

private enum MeetingRetranscriptionSpeakerChoice: Hashable {
    case meetingDefault
    case reuseCompatible
    case rerun(MeetingDiarizationProfileID)
    case disabled

    var runMode: MeetingDiarizationRunMode {
        switch self {
        case .meetingDefault: return .meetingDefault
        case .reuseCompatible: return .reuseCompatible
        case .rerun(let profile): return .rerun(profile)
        case .disabled: return .disabled
        }
    }
}

private enum ManualNotesSaveStatus {
    case saved
    case saving

    var label: String {
        switch self {
        case .saved: return "Saved"
        case .saving: return "Saving..."
        }
    }
}

// Wrapper views that isolate observation of liveMeetingTranscript.
// Without these, MeetingDetailView.body would observe the property and
// re-evaluate on every chunk (every ~5s), re-rendering the entire detail view.
// Each wrapper is the sole observer — MeetingDetailView passes appState by
// reference and never reads liveMeetingTranscript in its own body.
private struct LiveTranscriptSection: View {
    let appState: AppState
    let transcriptPrefix: String

    var body: some View {
        LiveTranscriptView(
            transcript: MeetingResumePolicy.combinedResumeTranscript(
                prior: transcriptPrefix,
                new: appState.liveMeetingTranscript
            ),
            partialYou: appState.liveMeetingPartialYou,
            partialOthers: appState.liveMeetingPartialOthers
        )
    }
}

private struct MeetingMicrophoneLevelBars: View {
    let powerDB: Float

    private var activeBarCount: Int {
        let normalized = max(0, min(1, (Double(powerDB) + 60) / 60))
        return Int(ceil(normalized * 5))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(
                        index < activeBarCount
                            ? MuesliTheme.accent
                            : MuesliTheme.textTertiary.opacity(0.25)
                    )
                    .frame(width: 3, height: CGFloat(5 + index * 2))
            }
        }
        .frame(width: 24, height: 16)
        .accessibilityLabel("Microphone activity")
        .accessibilityValue(activeBarCount == 0 ? "Silent" : "Active")
    }
}

struct MeetingDetailView: View {
    let meeting: MeetingRecord?
    let controller: MuesliController
    let appState: AppState
    let onBack: (() -> Void)?
    let backLabel: String
    @State private var isSummarizing = false
    @State private var isRetranscribing = false
    @State private var isAnalyzingSpeakers = false
    @State private var isEditingNotes = false
    @State private var isEditingTranscript = false
    @State private var editableTitle: String
    @State private var editableNotes: String
    @State private var editableTranscript: String
    @State private var editableManualNotes: String
    @State private var loadedMeetingID: Int64?
    @State private var manualNotesSaveStatus: ManualNotesSaveStatus = .saved
    @State private var manualEditorCommand: MarkdownEditorCommand?
    @State private var pendingTemplateID: String
    @State private var documentMode: MeetingDocumentMode
    @State private var recordingMode: RecordingContentMode = .notes
    @State private var titleSaveTask: DispatchWorkItem?
    @State private var notesSaveTask: DispatchWorkItem?
    @State private var transcriptSaveTask: DispatchWorkItem?
    @State private var manualNotesSaveStatusTask: DispatchWorkItem?
    @State private var summaryErrorMessage: String?
    @State private var retranscriptionErrorMessage: String?
    @State private var speakerAnalysisErrorMessage: String?
    @State private var showRetranscriptionOptions = false
    @State private var retranscriptionBackendKey = ""
    @State private var retranscriptionSpeakerChoice: MeetingRetranscriptionSpeakerChoice = .meetingDefault
    @State private var showDeleteConfirmation = false
    @State private var recordingPendingDeletion: MeetingRecordingRecord?
    @State private var showDeleteAllAudioConfirmation = false
    @State private var showDiscardRecoveryAudioConfirmation = false
    @State private var transcriptResummaryPromptMeetingID: Int64?
    @State private var transcriptEditOriginalTranscript: String?
    @State private var transcriptEditHadStructuredNotes = false
    @State private var showFolderPopover = false
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var threadContext: MeetingThreadContext?
    @State private var isMeetingAudioExpanded = false
    @State private var isManualNotesExpanded: Bool
    @State private var manualNotesChangedLocally = false
    @State private var speakerAssetStatuses: [MeetingDiarizationAssetStatus] = []

    init(
        meeting: MeetingRecord?,
        controller: MuesliController,
        appState: AppState,
        onBack: (() -> Void)? = nil,
        backLabel: String = "Back to Meetings"
    ) {
        self.meeting = meeting
        self.controller = controller
        self.appState = appState
        self.onBack = onBack
        self.backLabel = backLabel
        let initialTemplateID = meeting.map { controller.meetingTemplateSnapshot(for: $0).id } ?? controller.defaultMeetingTemplate().id
        _editableTitle = State(initialValue: meeting?.title ?? "")
        _editableNotes = State(initialValue: meeting.map { Self.notesContent(for: $0) } ?? "")
        _editableTranscript = State(initialValue: meeting?.rawTranscript ?? "")
        _editableManualNotes = State(initialValue: meeting?.manualNotes ?? "")
        _loadedMeetingID = State(initialValue: meeting?.id)
        _pendingTemplateID = State(initialValue: initialTemplateID)
        _documentMode = State(initialValue: meeting.map(Self.defaultDocumentMode(for:)) ?? .notes)
        _isManualNotesExpanded = State(
            initialValue: meeting.map(Self.defaultManualNotesExpansion(for:)) ?? false
        )
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let meeting {
                    VStack(alignment: .leading, spacing: 0) {
                        fixedHeader(for: meeting)

                        Divider()
                            .background(MuesliTheme.surfaceBorder)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if showsScrollableMeetingContext(for: meeting) {
                                    scrollableMeetingContext(for: meeting)

                                    Divider()
                                        .background(MuesliTheme.surfaceBorder)
                                }

                                content(for: meeting)
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: max(proxy.size.height - 140, 320),
                                        alignment: .top
                                    )
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .background(MuesliTheme.backgroundBase)
                    .onAppear {
                        threadContext = controller.meetingThreadContext(for: meeting.id)
                        refreshSpeakerAssetStatuses()
                    }
                    .onChange(of: meeting.id) { _, _ in
                        syncLocalState(with: meeting)
                        refreshSpeakerAssetStatuses()
                    }
                    .onChange(of: meeting.status) { _, _ in
                        isManualNotesExpanded = Self.defaultManualNotesExpansion(for: meeting)
                        syncLocalState(with: meeting)
                    }
                    .onChange(of: appState.meetingNotesFocusRequest) { _, _ in
                        recordingMode = .notes
                    }
                    .onChange(of: meeting.manualNotes) { _, _ in
                        syncManualNotesState(with: meeting)
                    }
                    .onChange(of: appState.config.customMeetingTemplates) { _, _ in
                        syncPendingTemplateSelectionIfNeeded(for: meeting)
                    }
                } else {
                    VStack(spacing: MuesliTheme.spacing12) {
                        Text("No meeting selected")
                            .font(MuesliTheme.title3())
                            .foregroundStyle(MuesliTheme.textSecondary)
                        Text("Choose a meeting from the Meetings browser to open it here.")
                            .font(MuesliTheme.callout())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MuesliTheme.backgroundBase)
                }
            }
            // NavigationSplitView asks its columns for their ideal size before it
            // proposes the actual window height. Recording playback makes the
            // meeting header taller, so an unbounded detail column can otherwise
            // enlarge the entire split view and get centered outside the window.
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .top
            )
            .clipped()
        }
        .alert("Couldn't Save Summary", isPresented: summaryErrorBinding) {
            Button("OK", role: .cancel) {
                summaryErrorMessage = nil
            }
        } message: {
            Text(summaryErrorMessage ?? "The updated meeting notes could not be saved.")
        }
        .alert("Couldn't Re-transcribe Meeting", isPresented: retranscriptionErrorBinding) {
            Button("OK", role: .cancel) {
                retranscriptionErrorMessage = nil
            }
        } message: {
            Text(retranscriptionErrorMessage ?? "The saved recording could not be re-transcribed.")
        }
        .alert("Couldn't Analyze Speakers", isPresented: speakerAnalysisErrorBinding) {
            Button("OK", role: .cancel) {
                speakerAnalysisErrorMessage = nil
            }
        } message: {
            Text(speakerAnalysisErrorMessage ?? "Remote speakers could not be analyzed.")
        }
        .sheet(isPresented: $showRetranscriptionOptions) {
            if let meeting {
                retranscriptionOptionsSheet(for: meeting)
            }
        }
        .alert("Re-summarize Notes?", isPresented: transcriptResummaryPromptBinding) {
            Button("Re-summarize") {
                resummarizeAfterTranscriptEdit()
            }
            Button("Not Now", role: .cancel) {
                transcriptResummaryPromptMeetingID = nil
            }
        } message: {
            Text("Your transcript edits may change the generated notes. Re-summarize now to update them from the edited transcript.")
        }
        .alert("Delete Meeting", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let meeting {
                    controller.deleteMeeting(id: meeting.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this meeting? Saved notes, transcript, and any retained recording will be removed.")
        }
        .alert("Delete Audio Recording", isPresented: recordingDeletionBinding) {
            Button("Delete", role: .destructive) {
                if let recordingPendingDeletion {
                    controller.deleteMeetingRecordingNow(recordingPendingDeletion)
                }
                recordingPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                recordingPendingDeletion = nil
            }
        } message: {
            Text("This removes the audio file immediately. The meeting transcript and notes will remain.")
        }
        .alert("Delete All Meeting Audio", isPresented: $showDeleteAllAudioConfirmation) {
            Button("Delete All Audio", role: .destructive) {
                if let meeting {
                    controller.deleteAllMeetingRecordingsNow(meetingID: meeting.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All audio files for this meeting will be removed immediately. The meeting transcript and notes will remain.")
        }
        .alert("Discard Recovery Audio?", isPresented: $showDiscardRecoveryAudioConfirmation) {
            Button("Discard Audio", role: .destructive) {
                if let meeting {
                    controller.discardMeetingRecoveryAudio(meetingID: meeting.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let size = meeting.map {
                controller.recoverableMeetingAudioSizeLabel(meetingID: $0.id)
            } ?? "the saved"
            Text("This permanently deletes \(size) of private recovery audio. The failed Final transcript cannot be retried afterward.")
        }
    }

    @ViewBuilder
    private func fixedHeader(for meeting: MeetingRecord) -> some View {
        let appliedTemplate = controller.meetingTemplateSnapshot(for: meeting)
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(backLabel)
                            .font(MuesliTheme.callout())
                    }
                    .foregroundStyle(MuesliTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            ExpandableMeetingTitleField(
                text: $editableTitle,
                onSubmit: {
                    controller.updateMeetingTitle(id: meeting.id, title: editableTitle)
                },
                onTextChange: {
                    debounceSaveTitle(meetingID: meeting.id)
                }
            )
            .id(meeting.id)

            meetingMetadata(for: meeting, appliedTemplate: appliedTemplate)

            meetingToolbar(for: meeting, appliedTemplate: appliedTemplate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.vertical, MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundBase)
    }

    @ViewBuilder
    private func scrollableMeetingContext(for meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            threadBreadcrumb

            activeMeetingMicrophoneControl(for: meeting)

            meetingAudioSection(for: meeting)

            activeMeetingAudioWarningBanner(for: meeting)

            if !showsManualNotesEditor(for: meeting), isRawTranscript(meeting), documentMode == .notes {
                transcriptCTA
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }

    private func showsScrollableMeetingContext(for meeting: MeetingRecord) -> Bool {
        if threadContext != nil {
            return true
        }
        if meeting.status == .recording,
           appState.activeMeetingMicrophone?.meetingID == meeting.id {
            return true
        }
        if meeting.status == .recording {
            return true
        }
        if !controller.meetingRecordingUnits(for: meeting.id).isEmpty {
            return true
        }
        if meeting.status == .recording,
           appState.activeMeetingAudioWarning?.meetingID == meeting.id {
            return true
        }
        return !showsManualNotesEditor(for: meeting)
            && isRawTranscript(meeting)
            && documentMode == .notes
    }

    @ViewBuilder
    private func processingMetadataView(
        for meeting: MeetingRecord,
        mode: MeetingDocumentMode
    ) -> some View {
        let run = mode == .notes
            ? meeting.processingMetadata.summary
            : meeting.processingMetadata.transcription
        if let run {
            processingMetadataItem(
                title: mode == .notes ? "Generated" : "Transcribed",
                systemImage: mode == .notes ? "sparkles" : "waveform",
                run: run
            )
        }
    }

    private func processingMetadataItem(
        title: String,
        systemImage: String,
        run: MeetingProcessingRunMetadata
    ) -> some View {
        let label = Self.processingRunLabel(title: title, run: run)
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text(label)
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            label.replacingOccurrences(of: " · ", with: ", ")
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Self.processingRunHelp(run))
    }

    static func processingDateLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func processingDurationLabel(_ duration: TimeInterval) -> String {
        let seconds = max(duration, 0)
        if seconds < 1 {
            return String(format: "%.1fs", seconds)
        }
        let rounded = Int(seconds.rounded())
        if rounded < 60 {
            return "\(rounded)s"
        }
        if rounded < 3_600 {
            return "\(rounded / 60)m \(rounded % 60)s"
        }
        return "\(rounded / 3_600)h \((rounded % 3_600) / 60)m"
    }

    static func processingRunLabel(title: String, run: MeetingProcessingRunMetadata) -> String {
        var parts = [
            "\(title) \(processingDateLabel(run.completedAt))",
            run.displayName,
        ]
        if let thinkingStatus = run.thinkingStatus {
            switch thinkingStatus {
            case .used:
                parts.append("Thinking")
            case .notUsed:
                parts.append("No thinking")
            case .notReported:
                parts.append("Thinking not reported")
            }
        }
        if let diagnostics = run.aecDiagnostics {
            parts.append(aecRunStatusLabel(diagnostics))
        }
        parts.append(processingDurationLabel(run.durationSeconds))
        return parts.joined(separator: " · ")
    }

    private static func processingRunHelp(_ run: MeetingProcessingRunMetadata) -> String {
        let model = run.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var help = model.isEmpty
            ? "Backend: \(run.backend)"
            : "Backend: \(run.backend)\nModel: \(model)"
        if let thinkingStatus = run.thinkingStatus {
            help += "\nThinking: \(thinkingStatus.rawValue)"
        }
        if let audioSource = run.audioSource {
            help += "\nAudio source: \(audioSource)"
        }
        if let aecModel = run.aecModel {
            help += "\nRequested AEC: \(aecLabel(aecModel))"
        }
        if let diagnostics = run.aecDiagnostics {
            help += "\nActual AEC: \(aecLabel(diagnostics.processor))"
            help += "\nAEC ready: \(diagnostics.ready ? "yes" : "no")"
            help += "\nAEC frames: \(diagnostics.processedFrames)"
            help += "\nAEC source units: \(diagnostics.appliedSourceUnitCount)/"
                + "\(diagnostics.sourceUnitCount) applied"
            help += "\nSystem reference: \(diagnostics.fullReferenceFrames) full, "
                + "\(diagnostics.partialReferenceFrames) partial, "
                + "\(diagnostics.missingReferenceFrames) missing"
            if let error = diagnostics.processingError {
                help += "\nAEC processing error: \(error)"
            }
        }
        return help
    }

    private static func aecRunStatusLabel(
        _ diagnostics: MeetingAecRunDiagnostics
    ) -> String {
        if diagnostics.processingError != nil {
            return "AEC degraded"
        }
        if diagnostics.appliedSourceUnitCount == diagnostics.sourceUnitCount,
           diagnostics.sourceUnitCount > 0 {
            return "AEC \(aecLabel(diagnostics.processor))"
        }
        if diagnostics.appliedSourceUnitCount > 0 {
            return "AEC partially applied"
        }
        guard diagnostics.ready else { return "AEC unavailable" }
        guard diagnostics.processedFrames > 0 else { return "AEC not applied" }
        if diagnostics.fullReferenceFrames + diagnostics.partialReferenceFrames == 0 {
            return "AEC no reference"
        }
        return "AEC degraded"
    }

    private static func aecLabel(_ value: String) -> String {
        switch value {
        case "localvqe_v1_2": return "LocalVQE v1.2"
        case "localvqe_gtcrn_49k": return "LocalVQE GTCRN 49K"
        case "dtln": return "DTLN"
        case "unavailable": return "Unavailable"
        default: return value
        }
    }

    @ViewBuilder
    private func activeMeetingMicrophoneControl(for meeting: MeetingRecord) -> some View {
        if meeting.status == .recording,
           let microphone = appState.activeMeetingMicrophone,
           microphone.meetingID == meeting.id {
            TimelineView(.periodic(from: .now, by: 0.12)) { _ in
                let transition = controller.activeMeetingMicrophoneRouteTransition()
                let activeName = transition?.activeDeviceName
                    ?? microphone.activeDeviceName
                let desiredName = transition?.desiredDeviceName
                    ?? microphone.activeDeviceName
                let phase = transition?.phase ?? .stable
                let showsWarning = !microphone.selectionAvailable || phase == .failed

                HStack(spacing: MuesliTheme.spacing8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            showsWarning
                                ? Color.orange
                                : MuesliTheme.textSecondary
                        )

                    MeetingMicrophoneLevelBars(
                        powerDB: controller.activeMeetingMicrophonePower()
                    )

                    Menu {
                        Button {
                            controller.selectActiveMeetingInputDeviceUID(nil)
                        } label: {
                            Label(
                                microphone.automaticDeviceName.map {
                                    "Automatic — \($0)"
                                } ?? "Automatic",
                                systemImage: microphone.selectionUID == nil
                                    ? "checkmark"
                                    : "arrow.triangle.2.circlepath"
                            )
                        }

                        if !microphone.availableDevices.isEmpty {
                            Divider()
                        }

                        ForEach(microphone.availableDevices) { device in
                            Button {
                                controller.selectActiveMeetingInputDeviceUID(device.uid)
                            } label: {
                                Label(
                                    device.name,
                                    systemImage: microphone.selectionUID == device.uid
                                        ? "checkmark"
                                        : (device.isBuiltIn ? "laptopcomputer" : "mic")
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Recording from \(activeName)")
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            showsWarning
                                ? Color.orange
                                : MuesliTheme.textPrimary
                        )
                    }
                    .menuStyle(.borderlessButton)

                    if phase == .switching || phase == .retrying {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Text(microphoneRouteStatusText(
                        phase: phase,
                        desiredName: desiredName,
                        attempt: transition?.attempt ?? 0,
                        followsSystemDefault: microphone.selectionUID == nil
                    ))
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(
                        phase == .failed
                            ? Color.orange
                            : MuesliTheme.textTertiary
                    )

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, MuesliTheme.spacing8)
            .background(MuesliTheme.surfacePrimary.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(
                        microphone.selectionAvailable
                            ? MuesliTheme.surfaceBorder
                            : Color.orange.opacity(0.4),
                        lineWidth: 1
                    )
            )
        }
    }

    private func finalSpeakerControlLabel(
        _ preference: MeetingDiarizationPreference,
        resolved: ResolvedMeetingDiarizationPolicy
    ) -> String {
        let policy: String
        switch preference.finalPolicy {
        case .followSettings:
            if resolved.enabled {
                return "Settings · Separate with \(speakerProfileLabel(resolved.profileID))"
            }
            return "Settings · Keep as Others"
        case .enabled:
            policy = "Separate with"
        case .disabled:
            return "Keep as Others"
        }
        return "\(policy) \(speakerProfileLabel(resolved.profileID))"
    }

    private func speakerProfileLabel(_ profile: MeetingDiarizationProfileID) -> String {
        switch profile {
        case .automatic: return "Automatic"
        case .offlineQuality: return "Offline quality"
        case .stableFourSpeaker: return "Stable up to 4"
        }
    }

    private func microphoneRouteStatusText(
        phase: MeetingMicRouteTransitionPhase,
        desiredName: String,
        attempt: Int,
        followsSystemDefault: Bool
    ) -> String {
        switch phase {
        case .stable:
            return followsSystemDefault ? "Follows System Default" : "This meeting only"
        case .switching:
            return "Trying to switch to \(desiredName)…"
        case .retrying:
            return "Retrying \(desiredName)… (attempt \(max(attempt, 2)))"
        case .failed:
            return "Couldn’t switch to \(desiredName) — still recording from the current microphone"
        }
    }

    @ViewBuilder
    private func meetingAudioSection(for meeting: MeetingRecord) -> some View {
        let units = controller.meetingRecordingUnits(for: meeting.id)
        let recordings = units.map(\.recording)
        if !recordings.isEmpty {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                HStack(spacing: MuesliTheme.spacing12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isMeetingAudioExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: MuesliTheme.spacing8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .rotationEffect(.degrees(isMeetingAudioExpanded ? 90 : 0))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    recordings.count == 1
                                        ? "Meeting audio · 1 recording"
                                        : "Meeting audio · \(recordings.count) recordings"
                                )
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(MuesliTheme.textPrimary)
                                Text(meetingAudioRetentionLabel(meeting: meeting, recordings: recordings))
                                    .font(MuesliTheme.captionMedium())
                                    .foregroundStyle(MuesliTheme.textTertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Toggle(
                        "Keep audio",
                        isOn: Binding(
                            get: { meeting.recordingRetentionProtected },
                            set: {
                                controller.setMeetingRecordingRetentionProtected(
                                    meetingID: meeting.id,
                                    protected: $0
                                )
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)

                    if recordings.count > 1 {
                        Button(role: .destructive) {
                            showDeleteAllAudioConfirmation = true
                        } label: {
                            Label("Delete all", systemImage: "trash")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MuesliTheme.recording)
                    }
                }

                if isMeetingAudioExpanded {
                    ForEach(Array(units.enumerated()), id: \.element.recording.id) { index, unit in
                        let recording = unit.recording
                        VStack(alignment: .leading, spacing: 6) {
                            if recordings.count > 1 {
                                HStack {
                                    Text("Recording \(index + 1) · \(recordingCreatedAtLabel(recording.createdAt))")
                                        .font(MuesliTheme.captionMedium())
                                        .foregroundStyle(MuesliTheme.textSecondary)
                                    Spacer()
                                    recordingActions(recording)
                                }
                            }

                            HStack(spacing: MuesliTheme.spacing8) {
                                MeetingRecordingPlayerView(
                                    recordingID: recording.id,
                                    recordingPath: recording.path,
                                    supportsSeparatedChannels: recording.sourceLayout != nil,
                                    onLeaseRelease: {
                                        controller.performRetentionCleanup()
                                    }
                                )

                                if recordings.count == 1 {
                                    recordingActions(recording)
                                }
                            }

                            if let stateLabel = recordingStateLabel(
                                unit,
                                meeting: meeting
                            ) {
                                Label(stateLabel.text, systemImage: stateLabel.systemImage)
                                    .font(MuesliTheme.captionMedium())
                                    .foregroundStyle(stateLabel.color)
                            }
                        }
                    }
                }
            }
            .padding(MuesliTheme.spacing12)
            .background(MuesliTheme.surfacePrimary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    private func recordingStateLabel(
        _ unit: MeetingRecordingUnitRecord,
        meeting: MeetingRecord
    ) -> (text: String, systemImage: String, color: Color)? {
        if !meeting.recordingRetentionProtected,
           let deleteAfter = unit.recording.deleteAfter,
           deleteAfter <= Date() {
            return (
                "Deletion pending while audio is in use",
                "clock.arrow.circlepath",
                MuesliTheme.textTertiary
            )
        }
        if unit.recording.sourceLayout != nil {
            return (
                "Original microphone and system channels retained separately",
                "waveform.badge.mic",
                MuesliTheme.textTertiary
            )
        }
        switch unit.sourceBundle?.sourceState {
        case .recoveryPending:
            return (
                "Finishing original audio recovery",
                "arrow.triangle.2.circlepath",
                MuesliTheme.textTertiary
            )
        case .degraded:
            return (
                "One original audio source is unavailable",
                "exclamationmark.triangle",
                MuesliTheme.textTertiary
            )
        case .invalid:
            return (
                "Original source tracks unavailable; playback is preserved",
                "exclamationmark.triangle",
                MuesliTheme.textTertiary
            )
        case .complete, .none:
            return nil
        }
    }

    private func recordingActions(_ recording: MeetingRecordingRecord) -> some View {
        Menu {
            Button {
                controller.revealMeetingRecordingInFinder(path: recording.path)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Button(role: .destructive) {
                recordingPendingDeletion = recording
            } label: {
                Label("Delete Recording…", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recording actions")
    }

    private func meetingAudioRetentionLabel(
        meeting: MeetingRecord,
        recordings: [MeetingRecordingRecord]
    ) -> String {
        if meeting.recordingRetentionProtected {
            return "Kept indefinitely"
        }
        guard let nextDeletion = recordings.compactMap(\.deleteAfter).min() else {
            return "Automatic deletion will be scheduled"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Deletes \(formatter.localizedString(for: nextDeletion, relativeTo: Date()))"
    }

    private func recordingCreatedAtLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private func meetingMetadata(
        for meeting: MeetingRecord,
        appliedTemplate: MeetingTemplateSnapshot
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MuesliTheme.spacing12) {
                meetingMetadataFacts(for: meeting)
                if let label = SyncOriginDisplay.badgeLabel(forMeetingSource: meeting.source) {
                    SyncOriginBadge(label: label)
                }
                templateChip(for: appliedTemplate)
                folderPill(for: meeting)
            }

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                HStack(spacing: MuesliTheme.spacing12) {
                    meetingMetadataFacts(for: meeting)
                    if let label = SyncOriginDisplay.badgeLabel(forMeetingSource: meeting.source) {
                        SyncOriginBadge(label: label)
                    }
                }
                HStack(spacing: MuesliTheme.spacing8) {
                    templateChip(for: appliedTemplate)
                    folderPill(for: meeting)
                }
            }
        }
    }

    private func meetingMetadataFacts(for meeting: MeetingRecord) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            metadataFact(MeetingBrowserLogic.formatStartTime(meeting.startTime))
            metadataFact(formatDuration(meeting.durationSeconds))
            metadataFact("\(meeting.wordCount) words")
        }
    }

    private func metadataFact(_ text: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(MuesliTheme.textTertiary)
                .frame(width: 5, height: 5)
            Text(text)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func content(for meeting: MeetingRecord) -> some View {
        if meeting.status == .recording {
            if recordingMode == .notes {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    let persistedNotes = Self.notesContent(for: meeting)
                    let hasPersistedNotes = !meeting.formattedNotes
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !meeting.rawTranscript
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if hasPersistedNotes {
                        MeetingNotesView(markdown: persistedNotes, scrollable: false)
                            .frame(maxWidth: 980, alignment: .topLeading)
                    }
                    manualNotesSection(for: meeting)
                }
                .meetingDocumentLayout()
            } else {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    activeMeetingLiveControls(for: meeting)
                    LiveTranscriptSection(appState: appState, transcriptPrefix: meeting.rawTranscript)
                        .frame(maxWidth: .infinity, minHeight: 420)
                }
                .meetingDocumentLayout()
            }
        } else if isEditingNotes {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                manualNotesSection(for: meeting)
                contentToolbar(for: meeting)
                processingMetadataView(for: meeting, mode: .notes)

                TextEditor(text: $editableNotes)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(MuesliTheme.spacing24)
                    .background(MuesliTheme.backgroundBase)
                    .frame(maxWidth: 980, minHeight: 420, alignment: .topLeading)
                    .onChange(of: editableNotes) { _, _ in
                        debounceSaveNotes(meetingID: meeting.id)
                    }
            }
            .meetingDocumentLayout()
        } else if isEditingTranscript {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                manualNotesSection(for: meeting)
                contentToolbar(for: meeting)
                processingMetadataView(for: meeting, mode: .transcript)

                TextEditor(text: $editableTranscript)
                    .font(.system(size: 14))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(MuesliTheme.spacing24)
                    .background(MuesliTheme.backgroundBase)
                    .frame(maxWidth: 980, minHeight: 420, alignment: .topLeading)
                    .onChange(of: editableTranscript) { _, _ in
                        debounceSaveTranscript(meetingID: meeting.id)
                    }
            }
            .meetingDocumentLayout()
        } else if showsManualNotesEditor(for: meeting) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                manualNotesSection(for: meeting)
            }
            .meetingDocumentLayout()
        } else {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                manualNotesSection(for: meeting)
                if controller.meetingSpeakerControlsState(for: meeting).summaryIsStale {
                    staleSummaryBanner(for: meeting)
                }
                if documentMode == .transcript {
                    transcriptSpeakerControls(for: meeting)
                }
                contentToolbar(for: meeting)
                processingMetadataView(for: meeting, mode: documentMode)

                if documentMode == .notes {
                    MeetingNotesView(
                        markdown: Self.notesContent(for: meeting),
                        scrollable: false
                    )
                } else {
                    MeetingTranscriptView(
                        transcript: meeting.rawTranscript,
                        scrollable: false
                    )
                }
            }
            .meetingDocumentLayout()
        }
    }

    private var documentModePicker: some View {
        Picker("", selection: $documentMode) {
            Text("Summary").tag(MeetingDocumentMode.notes)
            Text("Transcript").tag(MeetingDocumentMode.transcript)
        }
        .pickerStyle(.segmented)
        .tint(MuesliTheme.accent)
        .frame(width: 220)
        .disabled(isEditingNotes || isEditingTranscript)
    }

    private var recordingModePicker: some View {
        Picker("", selection: $recordingMode) {
            Text("Notes").tag(RecordingContentMode.notes)
            Text("Live").tag(RecordingContentMode.live)
        }
        .pickerStyle(.segmented)
        .tint(MuesliTheme.accent)
        .frame(width: 180)
    }

    @ViewBuilder
    private func activeMeetingLiveControls(for meeting: MeetingRecord) -> some View {
        let state = appState.meetingLiveState
        let diarizationState = appState.meetingLiveDiarizationState
        let descriptor = MeetingASRModelCatalog.resolve(id: state.selection)
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Live transcription model")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textSecondary)

                liveModelPicker(
                    state: state,
                    meetingID: meeting.id
                )

                if let descriptor {
                    Text(descriptor.capabilities.liveMode.settingsBadge)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            HStack(spacing: MuesliTheme.spacing8) {
                liveStatusBadge(state: state)
                Spacer(minLength: MuesliTheme.spacing12)
                livePrimaryAction(state: state, meetingID: meeting.id)
            }

            Text(liveStatusDescription(state: state, descriptor: descriptor))
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(state.phase == .failed ? MuesliTheme.recording : MuesliTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Separate remote speakers")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Provisional Live labels for system audio only")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer(minLength: MuesliTheme.spacing12)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { diarizationState.enabled },
                        set: { enabled in
                            controller.setActiveMeetingLiveDiarizationEnabled(
                                enabled,
                                meetingID: meeting.id
                            )
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!capturedLiveDiarizationSupported(diarizationState))
            }

            HStack(spacing: MuesliTheme.spacing8) {
                liveDiarizationStatusBadge(state: diarizationState)
                if diarizationState.epoch > 1,
                   diarizationState.phase != .off {
                    Text("Epoch \(diarizationState.epoch)")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            Text(liveDiarizationStatusDescription(diarizationState))
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(
                    diarizationState.phase == .failed
                        ? MuesliTheme.recording
                        : MuesliTheme.textTertiary
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        }
    }

    private func liveModelPicker(
        state: MeetingLiveRuntimeState,
        meetingID: Int64
    ) -> some View {
        Picker(
            "",
            selection: Binding(
                get: { state.selection },
                set: { modelID in
                    guard state.phase == .off || state.phase == .failed else {
                        return
                    }
                    controller.selectActiveMeetingLiveModel(
                        modelID,
                        meetingID: meetingID
                    )
                }
            )
        ) {
            Section("Recommended — Streaming") {
                ForEach(MeetingASRModelCatalog.streamingLive) { option in
                    Text(
                        isLiveModelAvailable(option)
                            ? option.label
                            : "\(option.label) — Not downloaded"
                    )
                    .tag(option.id)
                    .disabled(!isLiveModelAvailable(option))
                }
            }
            Section("Available — Chunked, higher CPU") {
                ForEach(MeetingASRModelCatalog.chunkedLive) { option in
                    Text(
                        isLiveModelAvailable(option)
                            ? option.label
                            : "\(option.label) — Not downloaded"
                    )
                    .tag(option.id)
                    .disabled(!isLiveModelAvailable(option))
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 260, maxWidth: 360, alignment: .leading)
        .disabled(state.phase != .off && state.phase != .failed)
        .help(
            state.phase == .off || state.phase == .failed
                ? "Choose a Live model for this meeting only"
                : "Stop Live before changing the model"
        )
    }

    @ViewBuilder
    private func liveStatusBadge(state: MeetingLiveRuntimeState) -> some View {
        switch state.phase {
        case .off:
            statusPill("Off", color: MuesliTheme.textTertiary)
        case .loading:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
                Text("Starting")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(MuesliTheme.textSecondary)
        case .running:
            statusPill(state.kind == .streaming ? "Live · Streaming" : "Live · Chunked", color: MuesliTheme.success)
        case .lagging:
            statusPill("Live · Lagging", color: .orange)
        case .suspended:
            statusPill("Live · Paused", color: MuesliTheme.textSecondary)
        case .stopping:
            statusPill("Stopping", color: MuesliTheme.textSecondary)
        case .failed:
            statusPill("Live failed", color: MuesliTheme.recording)
        }
    }

    private func statusPill(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func liveDiarizationStatusBadge(
        state: MeetingLiveDiarizationRuntimeState
    ) -> some View {
        switch state.phase {
        case .off:
            statusPill("Speaker labels off", color: MuesliTheme.textTertiary)
        case .loading:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
                Text("Loading speaker model")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(MuesliTheme.textSecondary)
        case .running:
            statusPill("Remote speakers live", color: MuesliTheme.success)
        case .suspended:
            statusPill("Speaker labels paused", color: MuesliTheme.textSecondary)
        case .lagging:
            statusPill("Speaker labels catching up", color: .orange)
        case .failed:
            statusPill("Speaker labels unavailable", color: MuesliTheme.recording)
        }
    }

    private func liveDiarizationStatusDescription(
        _ state: MeetingLiveDiarizationRuntimeState
    ) -> String {
        if let message = state.message, !message.isEmpty {
            return message
        }
        switch state.phase {
        case .off:
            if !capturedLiveDiarizationSupported(state) {
                return "This model doesn't support Live speaker diarization."
            }
            return "Independent from Live transcription. Final speaker separation follows this meeting’s Final setting."
        case .loading:
            return "Loading the installed Stable up to 4 model. Earlier audio is not backfilled."
        case .running:
            return "Remote labels are provisional. Microphone speech always remains You."
        case .suspended:
            return "Speaker separation resumes with the meeting recording."
        case .lagging:
            return "Only provisional labels are delayed; raw recording and captions continue."
        case .failed:
            return "Install or repair Stable up to 4 in Models, then enable this again. Raw recording and captions are unaffected."
        }
    }

    private func capturedLiveDiarizationSupported(
        _ state: MeetingLiveDiarizationRuntimeState
    ) -> Bool {
        MeetingDiarizationProfiles.resolve(state.profileID).engineID == .sortformerBalanced
    }

    @ViewBuilder
    private func livePrimaryAction(state: MeetingLiveRuntimeState, meetingID: Int64) -> some View {
        switch state.phase {
        case .off, .failed:
            Button {
                controller.startActiveMeetingLive(meetingID: meetingID)
            } label: {
                Label(state.phase == .failed ? "Retry Live" : "Start Live", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.backgroundBase)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .frame(height: 30)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .disabled(
                MeetingASRModelCatalog.resolve(id: state.selection)
                    .map(isLiveModelAvailable) != true
            )
        case .loading:
            liveStopButton(label: "Cancel", meetingID: meetingID)
        case .running, .lagging, .suspended:
            liveStopButton(label: "Stop Live", meetingID: meetingID)
        case .stopping:
            EmptyView()
        }
    }

    private func liveStopButton(label: String, meetingID: Int64) -> some View {
        Button {
            controller.stopActiveMeetingLive(meetingID: meetingID)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .frame(height: 30)
                .background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func liveStatusDescription(
        state: MeetingLiveRuntimeState,
        descriptor: MeetingASRModelDescriptor?
    ) -> String {
        if state.phase == .failed, let message = state.message {
            return "\(message) The complete Final transcript will still run after Stop."
        }
        if state.phase == .lagging, let message = state.message {
            return "\(message) Dropped preview chunks: \(state.droppedPreviewChunks)."
        }
        if state.phase == .off {
            return "Live preview is off. The complete Final transcript will still run after Stop."
        }
        if state.phase == .loading {
            return "Loading \(descriptor?.label ?? "the selected model"). Preview begins when it is ready; earlier audio is not backfilled."
        }
        if state.phase == .suspended {
            return "Live preview is suspended while the meeting recording is paused."
        }
        if state.phase == .stopping {
            return "Finishing Live preview tasks. The meeting recording continues."
        }
        if state.kind == .chunked {
            return "Chunked preview may use more CPU. This choice applies only to the current meeting."
        }
        return "Streaming preview is active. This choice applies only to the current meeting."
    }

    private func isLiveModelAvailable(_ descriptor: MeetingASRModelDescriptor) -> Bool {
        if let minimum = descriptor.capabilities.minimumMacOSMajorVersion,
           ProcessInfo.processInfo.operatingSystemVersion.majorVersion < minimum {
            return false
        }
        return MeetingASRModelCatalog.isDownloaded(descriptor)
    }

    private func showsManualNotesEditor(for meeting: MeetingRecord) -> Bool {
        switch meeting.status {
        case .recording, .processing, .noteOnly, .failed:
            return true
        case .completed:
            return false
        }
    }

    private func canEditManualNotes(for meeting: MeetingRecord) -> Bool {
        meeting.status != .processing
    }

    private static func defaultManualNotesExpansion(for meeting: MeetingRecord) -> Bool {
        switch meeting.status {
        case .recording, .noteOnly, .failed:
            return true
        case .processing, .completed:
            return false
        }
    }

    private func isPreparingThisMeeting(_ meeting: MeetingRecord) -> Bool {
        meeting.status == .recording
            && appState.isMeetingStarting
            && !appState.isMeetingRecording
    }

    @ViewBuilder
    private func meetingToolbar(for meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> some View {
        Group {
            if showsManualNotesEditor(for: meeting) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MuesliTheme.spacing12) {
                        recordingControlGroup(for: meeting)
                        failedMeetingPostProcessingActions(for: meeting)
                        Spacer(minLength: MuesliTheme.spacing16)
                        if meeting.status == .recording {
                            recordingModePicker
                        }
                    }

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        recordingControlGroup(for: meeting)
                        failedMeetingPostProcessingActions(for: meeting)
                        if meeting.status == .recording {
                            recordingModePicker
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MuesliTheme.spacing12) {
                        headerActions(for: meeting, appliedTemplate: appliedTemplate)
                        Spacer(minLength: MuesliTheme.spacing16)
                        documentModePicker
                    }

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        HStack(spacing: MuesliTheme.spacing12) {
                            if shouldShowResumeChooser(for: meeting) {
                                resumeRecordingButton(for: meeting)
                            }
                            Spacer(minLength: MuesliTheme.spacing16)
                            documentModePicker
                        }
                        compactHeaderActions(for: meeting, appliedTemplate: appliedTemplate)
                    }
                }
            }
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func failedMeetingPostProcessingActions(for meeting: MeetingRecord) -> some View {
        if meeting.status == .failed {
            let hasRetainedRecording = meeting.savedRecordingPath != nil
                || !controller.meetingRecordingUnits(for: meeting.id).isEmpty
            let hasTranscript = !meeting.rawTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty

            if hasRetainedRecording || hasTranscript {
                HStack(spacing: MuesliTheme.spacing8) {
                    if hasRetainedRecording {
                        retranscribeAction(for: meeting)
                    }
                    if hasTranscript {
                        summaryAction(for: meeting)
                            .disabled(isRetranscribing)
                    }
                }
            }
        }
    }

    private func headerActions(for meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if shouldShowResumeChooser(for: meeting) {
                resumeRecordingButton(for: meeting)

                Divider()
                    .background(MuesliTheme.surfaceBorder)
                    .frame(height: 24)
                    .padding(.horizontal, MuesliTheme.spacing4)
            }

            exportMenu(for: meeting)
            moreActionsMenu(for: meeting)
        }
    }

    private func compactHeaderActions(for meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MuesliTheme.spacing8) {
                exportMenu(for: meeting)
                moreActionsMenu(for: meeting)
            }
        }
    }

    @ViewBuilder
    private func summaryAction(for meeting: MeetingRecord) -> some View {
        if isSummarizing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Summarizing...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            .padding(.horizontal, MuesliTheme.spacing8)
        } else {
            HStack(spacing: 0) {
                toolbarActionButton("sparkles", label: primarySummaryActionLabel(for: meeting)) {
                    startSummary(for: meeting)
                }
                .disabled(isTranscriptOnlyBackend)
                .help(isTranscriptOnlyBackend
                      ? "Choose a summary provider in Settings to generate meeting notes"
                      : "Re-summarize the meeting notes")

                Divider()
                    .background(MuesliTheme.surfaceBorder)
                    .frame(height: 16)

                summaryBackendOverrideMenu(for: meeting)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func summaryBackendOverrideMenu(for meeting: MeetingRecord) -> some View {
        let options = controller.meetingSummaryRunOptions()
        return Menu {
            Section("Run once with") {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    let isConfigured = controller.isMeetingSummaryBackendConfigured(option)
                    Button {
                        startSummary(for: meeting, using: option)
                    } label: {
                        HStack {
                            if index == 0 {
                                Image(systemName: "checkmark")
                            }
                            Text(summaryBackendMenuLabel(
                                option,
                                isDefault: index == 0,
                                isConfigured: isConfigured
                            ))
                        }
                    }
                    .disabled(!isConfigured)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(width: 24, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Re-summarize once with another configured backend")
    }

    private func summaryBackendMenuLabel(
        _ option: MeetingSummaryBackendOption,
        isDefault: Bool,
        isConfigured: Bool
    ) -> String {
        if !isConfigured {
            return "\(option.label) — Not configured"
        }
        return isDefault ? "\(option.label) — Default" : option.label
    }

    private func startSummary(
        for meeting: MeetingRecord,
        using summaryBackend: MeetingSummaryBackendOption? = nil
    ) {
        isSummarizing = true
        let completion: (Result<Void, Error>) -> Void = { [meeting] result in
            isSummarizing = false
            switch result {
            case .success:
                manualNotesChangedLocally = false
                if let updated = controller.meeting(id: meeting.id) {
                    syncLocalState(with: updated)
                }
            case .failure(let error):
                syncPendingTemplateSelectionIfNeeded(
                    for: controller.meeting(id: meeting.id) ?? meeting
                )
                summaryErrorMessage = error.localizedDescription
            }
        }
        if hasPendingTemplateChange(for: meeting) {
            controller.applyMeetingTemplate(
                id: pendingTemplateID,
                to: meeting,
                summaryBackend: summaryBackend,
                completion: completion
            )
        } else {
            controller.resummarize(
                meeting: meeting,
                summaryBackend: summaryBackend,
                completion: completion
            )
        }
    }

    @ViewBuilder
    private func editButton(for meeting: MeetingRecord) -> some View {
        toolbarActionButton(
            isEditingNotes || isEditingTranscript ? "checkmark.circle" : "pencil",
            label: editButtonLabel
        ) {
            if isEditingNotes {
                notesSaveTask?.cancel()
                notesSaveTask = nil
                controller.updateMeetingNotes(id: meeting.id, notes: editableNotes)
                isEditingNotes = false
            } else if isEditingTranscript {
                guard !isRetranscribing else { return }
                transcriptSaveTask?.cancel()
                transcriptSaveTask = nil
                let shouldPromptForResummary = Self.shouldPromptForTranscriptResummary(
                    hadStructuredNotes: transcriptEditHadStructuredNotes,
                    originalTranscript: transcriptEditOriginalTranscript,
                    editedTranscript: editableTranscript
                )
                controller.updateMeetingTranscript(id: meeting.id, transcript: editableTranscript)
                isEditingTranscript = false
                transcriptEditOriginalTranscript = nil
                transcriptEditHadStructuredNotes = false
                if shouldPromptForResummary {
                    transcriptResummaryPromptMeetingID = meeting.id
                }
            } else if documentMode == .transcript {
                editableTranscript = meeting.rawTranscript
                transcriptEditOriginalTranscript = meeting.rawTranscript
                transcriptEditHadStructuredNotes = meeting.notesState == .structuredNotes
                isEditingTranscript = true
            } else {
                documentMode = .notes
                editableNotes = Self.notesContent(for: meeting)
                isEditingNotes = true
            }
        }
        .disabled(isRetranscribing && !isEditingNotes && !isEditingTranscript)
    }

    @ViewBuilder
    private func retranscribeAction(for meeting: MeetingRecord) -> some View {
        if meeting.savedRecordingPath != nil
            || !controller.meetingRecordingUnits(for: meeting.id).isEmpty {
            if isRetranscribing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Re-transcribing...")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                .padding(.horizontal, MuesliTheme.spacing8)
            } else {
                let isDisabled = meeting.status == .recording
                    || meeting.status == .processing
                    || isEditingNotes
                    || isEditingTranscript
                    || isSummarizing
                HStack(spacing: 0) {
                    Button {
                        if controller.meetingSpeakerControlsState(for: meeting)
                            .activePresentation == .manual {
                            openRetranscriptionOptions(for: meeting)
                        } else {
                            startRetranscription(for: meeting)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                            Text("Re-transcribe")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .padding(.leading, MuesliTheme.spacing8)
                        .padding(.trailing, 6)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .background(MuesliTheme.surfaceBorder)
                        .frame(height: 16)

                    retranscriptionBackendOverrideMenu(for: meeting)
                }
                .fixedSize(horizontal: true, vertical: false)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
                .disabled(isDisabled)
            }
        }
    }

    private func retranscriptionBackendOverrideMenu(for meeting: MeetingRecord) -> some View {
        let options = controller.availableMeetingRetranscriptionBackends()
        return Button {
            openRetranscriptionOptions(for: meeting)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(width: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(options.isEmpty)
        .help("Choose one-time transcription and remote-speaker options")
    }

    private func openRetranscriptionOptions(for meeting: MeetingRecord) {
        let options = controller.availableMeetingRetranscriptionBackends()
        guard let first = options.first else { return }
        retranscriptionBackendKey = backendKey(first)
        let state = controller.meetingSpeakerControlsState(for: meeting)
        retranscriptionSpeakerChoice = state.hasCompatibleAnalysis
            ? .reuseCompatible
            : .meetingDefault
        showRetranscriptionOptions = true
    }

    private func startRetranscription(
        for meeting: MeetingRecord,
        using backend: BackendOption? = nil,
        diarizationMode: MeetingDiarizationRunMode = .meetingDefault
    ) {
        isRetranscribing = true
        controller.retranscribe(
            meeting: meeting,
            using: backend,
            diarizationMode: diarizationMode
        ) { [meeting] result in
            isRetranscribing = false
            switch result {
            case .success:
                if let updated = controller.meeting(id: meeting.id) {
                    syncLocalState(with: updated)
                }
            case .failure(let error):
                retranscriptionErrorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func retranscriptionOptionsSheet(for meeting: MeetingRecord) -> some View {
        let options = controller.availableMeetingRetranscriptionBackends()
        let state = controller.meetingSpeakerControlsState(for: meeting)
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Re-transcribe Meeting")
                    .font(MuesliTheme.title3())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("These choices apply to this run only and do not change Settings or this meeting's default.")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.activePresentation == .manual {
                Label(
                    "A manually edited transcript is active. Re-transcription will show a new generated version, but your Manual version will remain saved and can be restored from Transcript view.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(MuesliTheme.spacing12)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Transcription")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                Picker("", selection: $retranscriptionBackendKey) {
                    ForEach(options.indices, id: \.self) { index in
                        let option = options[index]
                        Text(index == 0 ? "\(option.label) — Default" : option.label)
                            .tag(backendKey(option))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Remote speakers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                Picker("", selection: $retranscriptionSpeakerChoice) {
                    Text("Use meeting setting")
                        .tag(MeetingRetranscriptionSpeakerChoice.meetingDefault)
                    if state.hasCompatibleAnalysis {
                        Text("Keep current speaker analysis")
                            .tag(MeetingRetranscriptionSpeakerChoice.reuseCompatible)
                    }
                    if !installedSpeakerProfiles.isEmpty {
                        Divider()
                        ForEach(installedSpeakerProfiles, id: \.self) { profile in
                            Text("Analyze again — \(speakerProfileLabel(profile))")
                                .tag(MeetingRetranscriptionSpeakerChoice.rerun(profile))
                        }
                    }
                    Divider()
                    Text("Off — label remote audio as Others")
                        .tag(MeetingRetranscriptionSpeakerChoice.disabled)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Text(retranscriptionSpeakerChoiceDescription)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: MuesliTheme.spacing8) {
                Spacer()
                Button("Cancel") {
                    showRetranscriptionOptions = false
                }
                Button("Re-transcribe") {
                    guard let backend = options.first(where: {
                        backendKey($0) == retranscriptionBackendKey
                    }) else { return }
                    let mode = retranscriptionSpeakerChoice.runMode
                    showRetranscriptionOptions = false
                    startRetranscription(
                        for: meeting,
                        using: backend,
                        diarizationMode: mode
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(options.isEmpty)
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(width: 520)
    }

    private var retranscriptionSpeakerChoiceDescription: String {
        switch retranscriptionSpeakerChoice {
        case .meetingDefault:
            return "Resolves Follow Settings / On / Off for this meeting. A compatible saved analysis is reused automatically."
        case .reuseCompatible:
            return "Runs no diarizer. The saved analysis must still match the retained system-audio timeline."
        case .rerun(.stableFourSpeaker):
            return "Runs Sortformer locally once. Use only when there are no more than four remote speakers."
        case .rerun:
            return "Runs the selected local speaker model once after transcription."
        case .disabled:
            return "Runs no speaker model. Microphone remains You and all system audio is shown as Others."
        }
    }

    private func backendKey(_ option: BackendOption) -> String {
        "\(option.backend)\u{1f}\(option.model)"
    }

    @ViewBuilder
    private func templateMenu(for meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> some View {
        Menu {
            Button {
                pendingTemplateID = MeetingTemplates.autoID
            } label: {
                templateMenuItem(
                    title: MeetingTemplates.auto.title,
                    systemImage: MeetingTemplates.auto.icon,
                    isSelected: pendingTemplateID == MeetingTemplates.autoID
                )
            }

            Section("Built-in Templates") {
                ForEach(controller.builtInMeetingTemplates()) { template in
                    Button {
                        pendingTemplateID = template.id
                    } label: {
                        templateMenuItem(
                            title: template.title,
                            systemImage: template.icon,
                            isSelected: pendingTemplateID == template.id
                        )
                    }
                }
            }

            if !controller.customMeetingTemplates().isEmpty {
                Section("Custom Templates") {
                    ForEach(controller.customMeetingTemplates()) { template in
                        Button {
                            pendingTemplateID = template.id
                        } label: {
                            let resolved = MeetingTemplates.customDefinition(from: template)
                            templateMenuItem(
                                title: template.name,
                                systemImage: resolved.icon,
                                isSelected: pendingTemplateID == template.id
                            )
                        }
                    }
                }
            }

            Divider()

            Button("Manage Templates…") {
                controller.showMeetingTemplatesManager()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName(forSelectionOn: meeting, appliedTemplate: appliedTemplate))
                    .font(.system(size: 11, weight: .semibold))
                Text(labelForSelection(on: meeting, appliedTemplate: appliedTemplate))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func contentToolbar(for meeting: MeetingRecord) -> some View {
        let appliedTemplate = controller.meetingTemplateSnapshot(for: meeting)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MuesliTheme.spacing8) {
                Spacer()
                documentProcessingActions(
                    for: meeting,
                    appliedTemplate: appliedTemplate
                )
                editButton(for: meeting)
                copyDocumentButton(for: meeting)
            }

            VStack(alignment: .trailing, spacing: MuesliTheme.spacing8) {
                HStack(spacing: MuesliTheme.spacing8) {
                    documentProcessingActions(
                        for: meeting,
                        appliedTemplate: appliedTemplate
                    )
                }
                HStack(spacing: MuesliTheme.spacing8) {
                    editButton(for: meeting)
                    copyDocumentButton(for: meeting)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: 980, alignment: .leading)
    }

    @ViewBuilder
    private func transcriptSpeakerControls(for meeting: MeetingRecord) -> some View {
        let state = controller.meetingSpeakerControlsState(for: meeting)
        let resolved = MeetingDiarizationPolicyResolver.resolve(
            globalEnabled: appState.config.meetingFinalDiarizationEnabledByDefault,
            globalProfileID: appState.config.resolvedMeetingFinalDiarizationProfile,
            preference: state.preference
        )
        let selectableModes = state.availablePresentations.filter {
            $0 == .manual || $0 == .separated || $0 == .collapsed
        }
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Label("Remote speakers", systemImage: "person.2.wave.2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)

                if isAnalyzingSpeakers {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing speakers…")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                } else {
                    Menu {
                        Section("Final transcript") {
                            Button {
                                controller.setMeetingFinalDiarizationPolicy(
                                    meetingID: meeting.id,
                                    policy: .followSettings
                                )
                            } label: {
                                Label(
                                    appState.config.meetingFinalDiarizationEnabledByDefault
                                        ? "Follow Settings — separate speakers"
                                        : "Follow Settings — keep as Others",
                                    systemImage: state.preference.finalPolicy == .followSettings
                                        ? "checkmark"
                                        : "gearshape"
                                )
                            }

                            Button {
                                controller.setMeetingFinalDiarizationPolicy(
                                    meetingID: meeting.id,
                                    policy: .enabled
                                )
                            } label: {
                                Label(
                                    "Separate speakers in this meeting",
                                    systemImage: state.preference.finalPolicy == .enabled
                                        ? "checkmark"
                                        : "person.2"
                                )
                            }

                            Button {
                                controller.setMeetingFinalDiarizationPolicy(
                                    meetingID: meeting.id,
                                    policy: .disabled
                                )
                            } label: {
                                Label(
                                    "Keep all remote speech as Others",
                                    systemImage: state.preference.finalPolicy == .disabled
                                        ? "checkmark"
                                        : "person.2.slash"
                                )
                            }
                        }

                        if resolved.enabled {
                            Section("Model") {
                                Button {
                                    controller.setMeetingDiarizationProfile(
                                        meetingID: meeting.id,
                                        profileID: nil
                                    )
                                } label: {
                                    Label(
                                        "Use model selected in Settings",
                                        systemImage: state.preference.preferredProfileID == nil
                                            ? "checkmark"
                                            : "gearshape"
                                    )
                                }

                                ForEach(installedSpeakerProfiles, id: \.self) { profile in
                                    Button {
                                        controller.setMeetingDiarizationProfile(
                                            meetingID: meeting.id,
                                            profileID: profile
                                        )
                                    } label: {
                                        Label(
                                            speakerProfileLabel(profile),
                                            systemImage: state.preference.preferredProfileID == profile
                                                ? "checkmark"
                                                : "waveform.badge.magnifyingglass"
                                        )
                                    }
                                }

                                if speakerAssetStatuses.isEmpty {
                                    Button("Checking installed models…") {}
                                        .disabled(true)
                                } else if installedSpeakerProfiles.isEmpty {
                                    Button("No installed speaker models") {}
                                        .disabled(true)
                                }
                            }
                        }

                        if !selectableModes.isEmpty, let activeMode = state.activePresentation {
                            Section("Transcript view") {
                                ForEach(selectableModes, id: \.self) { mode in
                                    Button {
                                        controller.activateMeetingTranscriptPresentation(
                                            meetingID: meeting.id,
                                            mode: mode
                                        ) { result in
                                            if case .failure(let error) = result {
                                                speakerAnalysisErrorMessage = error.localizedDescription
                                            }
                                        }
                                    } label: {
                                        Label(
                                            transcriptPresentationLabel(
                                                mode,
                                                collapsedLabel: state.collapsedPresentationLabel
                                            ),
                                            systemImage: mode == activeMode
                                                ? "checkmark"
                                                : "text.alignleft"
                                        )
                                    }
                                }
                            }
                        }

                        if state.canAnalyzeAgain, !installedSpeakerProfiles.isEmpty {
                            Section("Analyze again") {
                                ForEach(installedSpeakerProfiles, id: \.self) { profile in
                                    Button {
                                        startSpeakerAnalysis(for: meeting, profileID: profile)
                                    } label: {
                                        Label(
                                            "Analyze again — \(speakerProfileLabel(profile))",
                                            systemImage: "person.2.badge.gearshape"
                                        )
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(finalSpeakerControlLabel(state.preference, resolved: resolved))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.textPrimary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Spacer(minLength: 0)
            }

            if let warning = state.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 980, alignment: .leading)
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.surfacePrimary.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        }
    }

    private var installedSpeakerProfiles: [MeetingDiarizationProfileID] {
        MeetingDiarizationProfiles.installedConcreteProfiles(
            from: speakerAssetStatuses
        )
    }

    private func refreshSpeakerAssetStatuses() {
        Task {
            speakerAssetStatuses = await controller.meetingDiarizationAssetStatuses()
        }
    }

    private func startSpeakerAnalysis(
        for meeting: MeetingRecord,
        profileID: MeetingDiarizationProfileID
    ) {
        isAnalyzingSpeakers = true
        controller.analyzeMeetingSpeakersAgain(
            meeting: meeting,
            profileID: profileID
        ) { result in
            isAnalyzingSpeakers = false
            if case .failure(let error) = result {
                speakerAnalysisErrorMessage = error.localizedDescription
            }
        }
    }

    private func transcriptPresentationLabel(
        _ mode: MeetingTranscriptPresentationMode,
        collapsedLabel: String
    ) -> String {
        switch mode {
        case .manual: return "Manual"
        case .separated: return "Separated"
        case .collapsed: return collapsedLabel
        case .legacyRendered: return "Transcript"
        }
    }

    private func staleSummaryBanner(for meeting: MeetingRecord) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Label(
                "This summary is based on a different transcript view.",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath"
            )
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.textSecondary)

            Spacer(minLength: MuesliTheme.spacing8)

            Button("Re-summarize") {
                startSummary(for: meeting)
            }
            .buttonStyle(.borderless)
            .disabled(isSummarizing || isTranscriptOnlyBackend)
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: 980, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func documentProcessingActions(
        for meeting: MeetingRecord,
        appliedTemplate: MeetingTemplateSnapshot
    ) -> some View {
        if documentMode == .notes {
            templateMenu(for: meeting, appliedTemplate: appliedTemplate)
            summaryAction(for: meeting)
        } else {
            retranscribeAction(for: meeting)
        }
    }

    private func copyDocumentButton(for meeting: MeetingRecord) -> some View {
        Button(action: {
            controller.copyToClipboard(activeCopyText(for: meeting))
        }) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(copyButtonLabel)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .fill(MuesliTheme.accent.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func manualNotesSection(for meeting: MeetingRecord) -> some View {
        let isEditable = canEditManualNotes(for: meeting)
        let trimmedNotes = editableManualNotes
            .trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isManualNotesExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: MuesliTheme.spacing8) {
                    Image(systemName: trimmedNotes.isEmpty ? "square.and.pencil" : "person.text.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textSecondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(trimmedNotes.isEmpty ? "Add your notes" : "Your notes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textPrimary)
                        if !isManualNotesExpanded, !trimmedNotes.isEmpty {
                            Text(manualNotesCollapsedPreview(trimmedNotes))
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: MuesliTheme.spacing12)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .rotationEffect(.degrees(isManualNotesExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isManualNotesExpanded {
                Text("Written by you and stored separately from the generated summary. These notes are used as protected context when you generate or update the summary.")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if meeting.status == .processing {
                    Label(
                        "Finalizing this meeting. Your notes will be editable when processing finishes.",
                        systemImage: "clock"
                    )
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textTertiary)
                }

                manualNotesToolbar(for: meeting)
                    .disabled(!isEditable)

                MarkdownRichTextEditor(
                    text: $editableManualNotes,
                    command: $manualEditorCommand,
                    shouldFocus: false,
                    isEditable: isEditable,
                    onTextChange: { notes in
                        guard isEditable else { return }
                        saveManualNotes(meetingID: meeting.id, notes: notes)
                    }
                )
                .frame(maxWidth: 980, minHeight: 150, maxHeight: 260, alignment: .topLeading)
                .background(MuesliTheme.backgroundBase)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )

                if summaryNeedsManualNotesUpdate(for: meeting) {
                    HStack(alignment: .center, spacing: MuesliTheme.spacing8) {
                        Label(
                            "The generated summary does not include your latest note changes.",
                            systemImage: "exclamationmark.circle"
                        )
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textSecondary)

                        Spacer(minLength: MuesliTheme.spacing8)

                        Button("Update summary") {
                            startSummary(for: meeting)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isSummarizing)
                    }
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: 980, alignment: .leading)
        .background(MuesliTheme.surfacePrimary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func manualNotesCollapsedPreview(_ notes: String) -> String {
        let firstLine = notes.split(whereSeparator: \.isNewline).first.map(String.init) ?? notes
        let wordCount = DictationStore.countWords(in: notes)
        return "\(firstLine) · \(wordCount) \(wordCount == 1 ? "word" : "words")"
    }

    private func summaryNeedsManualNotesUpdate(for meeting: MeetingRecord) -> Bool {
        guard meeting.status == .completed,
              meeting.notesState == .structuredNotes else {
            return false
        }
        if manualNotesChangedLocally,
           editableManualNotes != meeting.manualNotes {
            return true
        }
        guard let notesUpdatedAt = meeting.processingMetadata.manualNotesUpdatedAt else {
            return false
        }
        guard let summaryCompletedAt = meeting.processingMetadata.summary?.completedAt else {
            return true
        }
        return notesUpdatedAt > summaryCompletedAt
    }

    @ViewBuilder
    private func manualNotesToolbar(for meeting: MeetingRecord) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if canEditManualNotes(for: meeting) {
                Text(manualNotesSaveStatus.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            Spacer()

            markdownToolbarButton(systemImage: "textformat.size", label: "Heading") {
                manualEditorCommand = MarkdownEditorCommand(kind: .heading)
            }
            markdownToolbarButton(systemImage: "bold", label: "Bold") {
                manualEditorCommand = MarkdownEditorCommand(kind: .bold)
            }
            markdownToolbarButton(systemImage: "list.bullet", label: "Bullet") {
                manualEditorCommand = MarkdownEditorCommand(kind: .bullet)
            }
            markdownToolbarButton(systemImage: "checklist", label: "Checkbox") {
                manualEditorCommand = MarkdownEditorCommand(kind: .checkbox)
            }
        }
        .frame(maxWidth: 980, alignment: .leading)
    }

    @ViewBuilder
    private func statusChip(for meeting: MeetingRecord) -> some View {
        let isPreparing = isPreparingThisMeeting(meeting)
        let isPaused = meeting.status == .recording && appState.isMeetingRecordingPaused
        let label = isPreparing ? "Preparing" : isPaused ? "Paused" : meeting.status.displayLabel
        let color = isPreparing || isPaused ? MuesliTheme.transcribing : meeting.status.displayColor
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, 6)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func recordingControlGroup(for meeting: MeetingRecord) -> some View {
        if meeting.status == .recording {
            if isPreparingThisMeeting(meeting) {
                meetingPreparationControlGroup(for: meeting)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        statusChip(for: meeting)
                        pauseResumeRecordingButton
                        stopRecordingButton
                        discardRecordingButton
                    }
                    .recordingControlsBackground()

                    VStack(alignment: .trailing, spacing: MuesliTheme.spacing8) {
                        statusChip(for: meeting)
                        HStack(spacing: MuesliTheme.spacing8) {
                            pauseResumeRecordingButton
                            stopRecordingButton
                            discardRecordingButton
                        }
                        .recordingControlsBackground()
                    }
                }
            }
        } else if meeting.status == .failed,
                  controller.hasRecoverableMeetingAudio(meetingID: meeting.id) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MuesliTheme.spacing8) {
                    statusChip(for: meeting)
                    retryFinalProcessingButton(for: meeting)
                    discardRecoveryAudioButton
                }

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    statusChip(for: meeting)
                    HStack(spacing: MuesliTheme.spacing8) {
                        retryFinalProcessingButton(for: meeting)
                        discardRecoveryAudioButton
                    }
                }
            }
        } else if controller.canDeleteMeeting(meeting), meeting.status == .noteOnly || meeting.status == .failed {
            HStack(spacing: MuesliTheme.spacing8) {
                statusChip(for: meeting)
                deleteButton
            }
        } else if meeting.status == .processing,
                  let progress = appState.meetingProcessing[meeting.id] {
            processingProgressCard(statusChip: statusChip(for: meeting), progress: progress)
        } else {
            statusChip(for: meeting)
        }
    }

    /// Per-meeting processing progress in the detail toolbar: status chip + phase + timers.
    private func processingProgressCard(
        statusChip: some View,
        progress: MeetingProcessingProgress
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            statusChip
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Фаза: \(progress.phaseIndex)/\(progress.phaseCount) \(progress.phaseLabel)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Text("Фаза: \(MeetingProcessingProgress.elapsedString(from: progress.phaseStartedAt, to: context.date)) · Всего: \(MeetingProcessingProgress.elapsedString(from: progress.totalStartedAt, to: context.date))")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, 6)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func retryFinalProcessingButton(for meeting: MeetingRecord) -> some View {
        Button {
            controller.retryMeetingFinalProcessing(meetingID: meeting.id)
        } label: {
            Label("Retry Final transcript", systemImage: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.backgroundBase)
                .padding(.horizontal, MuesliTheme.spacing12)
                .frame(height: 30)
                .background(MuesliTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .help("Run the saved Final model over the complete recovery audio")
    }

    private var discardRecoveryAudioButton: some View {
        Button {
            showDiscardRecoveryAudioConfirmation = true
        } label: {
            Label("Discard recovery audio", systemImage: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.recording)
                .padding(.horizontal, MuesliTheme.spacing8)
                .frame(height: 30)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    /// The resume control only makes sense on a finished meeting when no other
    /// recording/editing workflow is active.
    private func shouldShowResumeChooser(for meeting: MeetingRecord) -> Bool {
        controller.canResumeFinishedMeeting(meeting)
            && !appState.isMeetingRecording
            && !appState.isMeetingStarting
            && !isEditingNotes
            && !isEditingTranscript
            && !isSummarizing
            && !isRetranscribing
    }

    @ViewBuilder
    private func meetingPreparationControlGroup(for meeting: MeetingRecord) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MuesliTheme.spacing8) {
                statusChip(for: meeting)
                meetingPreparationStatus
                cancelMeetingPreparationButton
            }
            .recordingControlsBackground()

            VStack(alignment: .trailing, spacing: MuesliTheme.spacing8) {
                statusChip(for: meeting)
                HStack(spacing: MuesliTheme.spacing8) {
                    meetingPreparationStatus
                    cancelMeetingPreparationButton
                }
                .recordingControlsBackground()
            }
        }
    }

    @ViewBuilder
    private func markdownToolbarButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MuesliTheme.textSecondary)
            .frame(width: 34, height: 30)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    @ViewBuilder
    private func exportMenu(for meeting: MeetingRecord) -> some View {
        let currentContent: MeetingExportContent = documentMode == .transcript ? .transcript : .notes
        let currentLabel = documentMode == .transcript ? "Export Transcript" : "Export Notes"
        Menu {
            Button {
                MeetingExporter.export(meeting: meeting, content: currentContent)
            } label: {
                Label(currentLabel, systemImage: documentMode == .transcript ? "text.quote" : "doc.text")
            }
            Button {
                MeetingExporter.export(meeting: meeting, content: .fullMeeting)
            } label: {
                Label("Export Full Meeting", systemImage: "doc.on.doc")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                Text("Export")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isEditingNotes || isEditingTranscript)
    }

    @ViewBuilder
    private func moreActionsMenu(for meeting: MeetingRecord) -> some View {
        if meeting.savedRecordingPath != nil || controller.canDeleteMeeting(meeting) {
            Menu {
                if let savedRecordingPath = meeting.savedRecordingPath {
                    Button {
                        controller.revealMeetingRecordingInFinder(path: savedRecordingPath)
                    } label: {
                        Label("Show Recording", systemImage: "folder")
                    }
                }

                if controller.canDeleteMeeting(meeting) {
                    if meeting.savedRecordingPath != nil {
                        Divider()
                    }
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Meeting", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    private func templateMenuItem(title: String, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark" : systemImage)
                .frame(width: 12)
            Text(title)
        }
    }

    @ViewBuilder
    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 5)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func toolbarActionButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var deleteButton: some View {
        iconButton("trash", label: "Delete") {
            showDeleteConfirmation = true
        }
    }

    private var meetingPreparationStatus: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
                .accessibilityLabel("Preparing transcription")
            Text(appState.meetingStartStatus ?? "Meeting transcription will start shortly.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, 7)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var cancelMeetingPreparationButton: some View {
        iconButton("xmark", label: "Cancel") {
            controller.cancelMeetingPreparation()
        }
        .help("Cancel meeting preparation")
    }

    private var pauseResumeRecordingButton: some View {
        let isPaused = appState.isMeetingRecordingPaused
        return Button {
            controller.toggleMeetingRecordingPause()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(isPaused ? "Resume" : "Pause")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isPaused ? MuesliTheme.backgroundBase : MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(isPaused ? MuesliTheme.accent : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isPaused ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!appState.isMeetingRecording)
        .help(isPaused ? "Resume recording" : "Pause recording")
    }

    /// Shown on a finished meeting when no recording is active. A split control:
    /// the left segment resumes recording into this meeting artifact; the right
    /// chevron opens a menu that also offers starting a linked follow-up meeting.
    /// (Not `Menu(primaryAction:)` — with a plain custom label on macOS the
    /// chevron segment doesn't render, leaving the menu unreachable.)
    @ViewBuilder
    private func resumeRecordingButton(for meeting: MeetingRecord) -> some View {
        HStack(spacing: 1) {
            Button {
                controller.resumeFinishedMeeting(meetingID: meeting.id)
            } label: {
                HStack(spacing: 6) {
                    resumeRecordingIcon
                    Text("Resume")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(MuesliTheme.backgroundBase)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 7)
                .background(MuesliTheme.accent)
            }
            .buttonStyle(.plain)
            .help("Resume recording")

            Menu {
                Button {
                    controller.resumeFinishedMeeting(meetingID: meeting.id)
                } label: {
                    HStack(spacing: 6) {
                        resumeRecordingIcon
                        Text("Resume recording")
                    }
                }
                Button {
                    controller.startFollowUpMeeting(fromMeetingID: meeting.id)
                } label: {
                    Label("Start a follow-up", systemImage: "arrow.turn.down.right")
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MuesliTheme.backgroundBase)
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)
                    .background(MuesliTheme.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .help("Resume recording, or start a follow-up meeting")
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    /// Record circle with a small "+" badge — distinguishes "resume recording
    /// into this meeting" from the plain "Record Meeting" action (record.circle).
    private var resumeRecordingIcon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "record.circle")
                .font(.system(size: 11, weight: .semibold))
            Image(systemName: "plus")
                .font(.system(size: 7, weight: .bold))
                .offset(x: 4, y: -3)
        }
    }

    private var stopRecordingButton: some View {
        Button {
            if let meeting {
                flushTitleSave(meetingID: meeting.id)
            }
            controller.stopMeetingRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(MuesliTheme.recording)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(!appState.isMeetingRecording)
        .help("Stop recording")
    }

    private var discardRecordingButton: some View {
        iconButton("xmark", label: "Discard") {
            controller.discardMeetingWithConfirmation()
        }
    }

    @ViewBuilder
    private func templateChip(for snapshot: MeetingTemplateSnapshot) -> some View {
        HStack(spacing: 5) {
            Image(systemName: iconName(for: snapshot))
                .font(.system(size: 10))
            Text(templateChipLabel(for: snapshot))
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(MuesliTheme.accent)
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, 4)
        .background(MuesliTheme.accentSubtle)
        .clipShape(Capsule())
    }

    private func templateChipLabel(for snapshot: MeetingTemplateSnapshot) -> String {
        switch snapshot.kind {
        case .auto:
            return "Auto summary"
        case .builtin, .custom:
            return snapshot.name
        }
    }

    /// Breadcrumb strip shown when this meeting is part of a follow-up thread:
    /// a link to the direct predecessor, total thread size, and direct follow-ups
    /// in chronological order. Root meetings show no predecessor link.
    @ViewBuilder
    private var threadBreadcrumb: some View {
        if let threadContext {
            VStack(alignment: .leading, spacing: 4) {
                if let predecessor = threadContext.predecessor {
                    threadLink(
                        icon: "arrow.turn.left.up",
                        text: "Follow-up to: \(predecessor.title) \u{00B7} \(MeetingBrowserLogic.formatStartTime(predecessor.startTime))",
                        targetID: predecessor.id
                    )
                }
                Text("Thread \u{00B7} \(threadContext.count) meetings")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                switch threadContext.successors.count {
                case 0:
                    EmptyView()
                case 1:
                    if let successor = threadContext.successors.first {
                        threadLink(
                            icon: "arrow.turn.left.down",
                            text: "Followed by: \(successor.title) \u{00B7} \(MeetingBrowserLogic.formatStartTime(successor.startTime))",
                            targetID: successor.id
                        )
                    }
                default:
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Follow-ups (\(threadContext.successors.count))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MuesliTheme.textTertiary)
                        ForEach(threadContext.successors) { successor in
                            threadLink(
                                icon: "arrow.turn.left.down",
                                text: "\(successor.title) \u{00B7} \(MeetingBrowserLogic.formatStartTime(successor.startTime))",
                                targetID: successor.id
                            )
                        }
                    }
                }
            }
        }
    }

    private func threadLink(icon: String, text: String, targetID: Int64) -> some View {
        Button {
            controller.showMeetingDocument(id: targetID)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(MuesliTheme.accent)
        }
        .buttonStyle(.plain)
        .help("Open this meeting")
    }

    @ViewBuilder
    private func folderPill(for meeting: MeetingRecord) -> some View {
        let currentFolder = meeting.folderID.flatMap { fid in
            appState.folders.first(where: { $0.id == fid })
        }
        let hasFolder = currentFolder != nil
        Button {
            showFolderPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: hasFolder ? "folder.fill" : "plus")
                    .font(.system(size: 10))
                Text(currentFolder?.name ?? "Add to folder")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(hasFolder ? MuesliTheme.accent : MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 4)
            .background(hasFolder ? MuesliTheme.accentSubtle : MuesliTheme.backgroundRaised)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        hasFolder ? Color.clear : MuesliTheme.textTertiary.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, dash: hasFolder ? [] : [3, 2])
                    )
            )
        }
        .buttonStyle(.plain)
        .help(hasFolder ? "Change folder" : "Add to folder")
        .popover(isPresented: $showFolderPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if !appState.folders.isEmpty {
                    ForEach(appState.folders) { folder in
                        let isActive = meeting.folderID == folder.id
                        folderPopoverRow(icon: "folder", label: folder.name, isActive: isActive) {
                            controller.moveMeeting(id: meeting.id, toFolder: isActive ? nil : folder.id)
                            showFolderPopover = false
                        }
                    }
                    Divider().padding(.vertical, 4)
                }
                folderPopoverRow(icon: "folder.badge.plus", label: "New Folder...") {
                    showFolderPopover = false
                    newFolderName = ""
                    showNewFolderPrompt = true
                }
            }
            .padding(8)
            .frame(minWidth: 200)
        }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                controller.createFolderAndMoveMeeting(name: trimmed, meetingID: meeting.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a new folder and move this meeting into it.")
        }
    }

    @ViewBuilder
    private func folderPopoverRow(icon: String, label: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(label)
                    .font(MuesliTheme.callout())
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var transcriptCTA: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if isTranscriptOnlyBackend {
                Image(systemName: "sparkles")
                    .foregroundStyle(MuesliTheme.accent)
                Text("Choose a summary provider in Settings to generate AI meeting notes.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            } else if hasApiKey {
                Image(systemName: "sparkles")
                    .foregroundStyle(MuesliTheme.accent)
                Text("Use \(primarySummaryActionLabel) to turn this raw transcript into AI meeting notes and a cleaned-up title.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            } else {
                Image(systemName: "key.fill")
                    .foregroundStyle(MuesliTheme.accent)
                Text("Add your API key in Settings to generate meeting notes")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                Spacer()
                Button("Open Settings") {
                    controller.openHistoryWindow(tab: .settings)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    @ViewBuilder
    private func activeMeetingAudioWarningBanner(for meeting: MeetingRecord) -> some View {
        if meeting.status == .recording,
           let warning = appState.activeMeetingAudioWarning,
           warning.meetingID == meeting.id {
            HStack(alignment: .top, spacing: MuesliTheme.spacing8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(warning.message)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Spacer(minLength: MuesliTheme.spacing8)
            }
            .padding(MuesliTheme.spacing12)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var hasApiKey: Bool {
        let config = appState.config
        if appState.selectedMeetingSummaryBackend == .chatGPT {
            return appState.isChatGPTAuthenticated
        } else if appState.selectedMeetingSummaryBackend == .openAI {
            return !config.openAIAPIKey.isEmpty || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
        } else if appState.selectedMeetingSummaryBackend == .ollama {
            return true
        } else if appState.selectedMeetingSummaryBackend == .lmStudio {
            return MeetingSummaryClient.lmStudioHasRequiredSettings(config: config)
        } else if appState.selectedMeetingSummaryBackend == .customLLM {
            return MeetingSummaryClient.customLLMHasRequiredSettings(config: config)
        } else if appState.selectedMeetingSummaryBackend == .gemmaLocal {
            // On-device: configured once the selected Gemma model is downloaded.
            return GemmaSummaryModel.resolve(id: config.gemmaSummaryModel).isDownloaded
        } else if appState.selectedMeetingSummaryBackend == .transcriptOnly {
            // No provider is configured; summaries are opt-in in Settings.
            return false
        } else {
            return !config.openRouterAPIKey.isEmpty || ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil
        }
    }

    private var isTranscriptOnlyBackend: Bool {
        appState.selectedMeetingSummaryBackend == .transcriptOnly
    }

    private var primarySummaryActionLabel: String {
        guard let meeting else { return "Re-summarize" }
        return primarySummaryActionLabel(for: meeting)
    }

    private var copyButtonLabel: String {
        "Copy"
    }

    private var editButtonLabel: String {
        if isEditingNotes || isEditingTranscript {
            return "Done"
        }
        return documentMode == .transcript ? "Edit Transcript" : "Edit Summary"
    }

    private func primarySummaryActionLabel(for meeting: MeetingRecord) -> String {
        hasPendingTemplateChange(for: meeting) ? "Apply Template" : "Re-summarize"
    }

    private func activeCopyText(for meeting: MeetingRecord) -> String {
        switch documentMode {
        case .notes:
            return isEditingNotes ? editableNotes : Self.notesContent(for: meeting)
        case .transcript:
            return isEditingTranscript ? editableTranscript : meeting.rawTranscript
        }
    }

    private func isRawTranscript(_ meeting: MeetingRecord) -> Bool {
        meeting.notesState != .structuredNotes
    }

    private func hasPendingTemplateChange(for meeting: MeetingRecord) -> Bool {
        resolvedPendingTemplateDefinition(for: meeting).id != controller.meetingTemplateSnapshot(for: meeting).id
    }

    private func labelForSelection(on meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> String {
        if pendingTemplateID == appliedTemplate.id {
            return appliedTemplate.name
        }
        return resolvedPendingTemplateDefinition(for: meeting).title
    }

    private func iconName(forSelectionOn meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> String {
        if pendingTemplateID == appliedTemplate.id {
            return iconName(for: appliedTemplate)
        }
        return resolvedPendingTemplateDefinition(for: meeting).icon
    }

    private func iconName(for snapshot: MeetingTemplateSnapshot) -> String {
        switch snapshot.kind {
        case .auto:
            return MeetingTemplates.auto.icon
        case .builtin, .custom:
            return MeetingTemplates.resolveDefinition(
                id: snapshot.id,
                customTemplates: appState.config.customMeetingTemplates,
                builtInOverrides: appState.config.builtInMeetingTemplateOverrides
            ).icon
        }
    }

    static func notesContent(for meeting: MeetingRecord) -> String {
        if meeting.status == .noteOnly {
            return meeting.manualNotes
        }
        if meeting.notesState != .structuredNotes {
            return "# \(meeting.title)\n\n## Raw Transcript\n\n\(meeting.rawTranscript)"
        }
        return meeting.formattedNotes
    }

    private static func defaultDocumentMode(for meeting: MeetingRecord) -> MeetingDocumentMode {
        if meeting.status == .noteOnly || meeting.status == .recording || meeting.status == .processing || meeting.status == .failed {
            return .notes
        }
        return meeting.notesState == .structuredNotes
            ? MeetingDocumentMode.notes
            : MeetingDocumentMode.transcript
    }

    private func debounceSaveTitle(meetingID: Int64) {
        titleSaveTask?.cancel()
        let title = editableTitle
        let c = controller
        c.cacheMeetingTitle(id: meetingID, title: title)
        let item = DispatchWorkItem { c.updateMeetingTitle(id: meetingID, title: title) }
        titleSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func flushTitleSave(meetingID: Int64) {
        titleSaveTask?.cancel()
        titleSaveTask = nil
        controller.updateMeetingTitle(id: meetingID, title: editableTitle)
    }

    private func debounceSaveNotes(meetingID: Int64) {
        notesSaveTask?.cancel()
        let notes = editableNotes
        let c = controller
        let item = DispatchWorkItem { c.updateMeetingNotes(id: meetingID, notes: notes) }
        notesSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func debounceSaveTranscript(meetingID: Int64) {
        transcriptSaveTask?.cancel()
        let transcript = editableTranscript
        let c = controller
        let item = DispatchWorkItem { c.updateMeetingTranscript(id: meetingID, transcript: transcript) }
        transcriptSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func saveManualNotes(meetingID: Int64, notes: String) {
        manualNotesSaveStatus = .saving
        manualNotesChangedLocally = true
        controller.cacheMeetingManualNotes(id: meetingID, notes: notes)
        scheduleManualNotesSaveStatusCheck(meetingID: meetingID, notes: notes)
    }

    private func scheduleManualNotesSaveStatusCheck(meetingID: Int64, notes: String) {
        manualNotesSaveStatusTask?.cancel()
        let item = DispatchWorkItem {
            guard loadedMeetingID == meetingID else { return }
            guard editableManualNotes == notes else { return }
            if controller.hasPersistedMeetingManualNotes(id: meetingID, notes: notes) {
                manualNotesSaveStatus = .saved
            }
        }
        manualNotesSaveStatusTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: item)
    }

    private var summaryErrorBinding: Binding<Bool> {
        Binding(
            get: { summaryErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    summaryErrorMessage = nil
                }
            }
        )
    }

    private var retranscriptionErrorBinding: Binding<Bool> {
        Binding(
            get: { retranscriptionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    retranscriptionErrorMessage = nil
                }
            }
        )
    }

    private var speakerAnalysisErrorBinding: Binding<Bool> {
        Binding(
            get: { speakerAnalysisErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    speakerAnalysisErrorMessage = nil
                }
            }
        )
    }

    private var recordingDeletionBinding: Binding<Bool> {
        Binding(
            get: { recordingPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    recordingPendingDeletion = nil
                }
            }
        )
    }

    private var transcriptResummaryPromptBinding: Binding<Bool> {
        Binding(
            get: { transcriptResummaryPromptMeetingID != nil },
            set: { isPresented in
                if !isPresented {
                    transcriptResummaryPromptMeetingID = nil
                }
            }
        )
    }

    private static func shouldPromptForTranscriptResummary(
        hadStructuredNotes: Bool,
        originalTranscript: String?,
        editedTranscript: String
    ) -> Bool {
        guard hadStructuredNotes, let originalTranscript else { return false }
        return originalTranscript != editedTranscript
    }

    private func resummarizeAfterTranscriptEdit() {
        guard let meetingID = transcriptResummaryPromptMeetingID else { return }
        transcriptResummaryPromptMeetingID = nil
        guard let updatedMeeting = controller.meeting(id: meetingID) else { return }
        isSummarizing = true
        controller.resummarize(meeting: updatedMeeting) { [meetingID] result in
            isSummarizing = false
            switch result {
            case .success:
                if let refreshed = controller.meeting(id: meetingID) {
                    syncLocalState(with: refreshed)
                }
            case .failure(let error):
                summaryErrorMessage = error.localizedDescription
            }
        }
    }

    private func resolvedPendingTemplateDefinition(for meeting: MeetingRecord) -> MeetingTemplateDefinition {
        if let resolved = MeetingTemplates.resolveExactDefinition(
            id: pendingTemplateID,
            customTemplates: appState.config.customMeetingTemplates,
            builtInOverrides: appState.config.builtInMeetingTemplateOverrides
        ) {
            return resolved
        }
        return MeetingTemplates.resolveDefinition(
            id: controller.meetingTemplateSnapshot(for: meeting).id,
            customTemplates: appState.config.customMeetingTemplates,
            builtInOverrides: appState.config.builtInMeetingTemplateOverrides
        )
    }

    private func syncPendingTemplateSelectionIfNeeded(for meeting: MeetingRecord?) {
        guard let meeting else { return }
        guard MeetingTemplates.resolveExactDefinition(
            id: pendingTemplateID,
            customTemplates: appState.config.customMeetingTemplates,
            builtInOverrides: appState.config.builtInMeetingTemplateOverrides
        ) == nil else {
            return
        }
        pendingTemplateID = controller.meetingTemplateSnapshot(for: meeting).id
    }

    private func syncLocalState(with meeting: MeetingRecord?) {
        let previousMeetingID = loadedMeetingID
        let meetingChanged = previousMeetingID != meeting?.id
        loadedMeetingID = meeting?.id
        threadContext = meeting.flatMap { controller.meetingThreadContext(for: $0.id) }
        editableTitle = meeting?.title ?? ""
        if meetingChanged || !isEditingNotes {
            editableNotes = meeting.map { Self.notesContent(for: $0) } ?? ""
        }
        if meetingChanged || !isEditingTranscript {
            editableTranscript = meeting?.rawTranscript ?? ""
        }
        if meetingChanged {
            editableManualNotes = meeting?.manualNotes ?? ""
            manualNotesSaveStatus = .saved
            manualNotesChangedLocally = false
            isMeetingAudioExpanded = false
            isManualNotesExpanded = meeting.map(Self.defaultManualNotesExpansion(for:)) ?? false
            transcriptResummaryPromptMeetingID = nil
            transcriptEditOriginalTranscript = nil
            transcriptEditHadStructuredNotes = false
            speakerAnalysisErrorMessage = nil
            showRetranscriptionOptions = false
            retranscriptionBackendKey = ""
            retranscriptionSpeakerChoice = .meetingDefault
        } else {
            syncManualNotesState(with: meeting)
        }
        pendingTemplateID = meeting.map { controller.meetingTemplateSnapshot(for: $0).id } ?? controller.defaultMeetingTemplate().id
        if meetingChanged {
            documentMode = meeting.map(Self.defaultDocumentMode(for:)) ?? .notes
            isEditingNotes = false
            isEditingTranscript = false
            showFolderPopover = false
            showNewFolderPrompt = false
            newFolderName = ""
        }
    }

    private func syncManualNotesState(with meeting: MeetingRecord?) {
        let persistedManualNotes = meeting?.manualNotes ?? ""
        if manualNotesSaveStatus == .saving, editableManualNotes != persistedManualNotes {
            return
        }
        editableManualNotes = persistedManualNotes
        manualNotesSaveStatus = .saved
    }

    private func formatDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded >= 3600 {
            let hours = rounded / 3600
            let minutes = (rounded % 3600) / 60
            return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
        }
        if rounded >= 60 {
            let m = rounded / 60
            let s = rounded % 60
            return s == 0 ? "\(m) min" : "\(m) min \(s) sec"
        }
        return "\(rounded) sec"
    }
}

private extension View {
    func meetingDocumentLayout() -> some View {
        frame(maxWidth: 1080, alignment: .topLeading)
            .padding(.horizontal, 40)
            .padding(.top, MuesliTheme.spacing12)
            .padding(.bottom, MuesliTheme.spacing24)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    func recordingControlsBackground() -> some View {
        padding(5)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
    }
}

private struct ExpandableMeetingTitleField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onTextChange: () -> Void

    @State private var isEditing = false
    @FocusState private var isTitleFocused: Bool

    private let titleFont = Font.system(size: 30, weight: .bold)

    var body: some View {
        Group {
            if isEditing {
                TextField("Meeting Title", text: $text, axis: .vertical)
                    .font(titleFont)
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .textFieldStyle(.plain)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($isTitleFocused)
                    .onSubmit {
                        finishEditing()
                    }
                    .onChange(of: text) { _, _ in
                        onTextChange()
                    }
                    .onChange(of: isTitleFocused) { _, focused in
                        if !focused {
                            finishEditing()
                        }
                    }
                    .accessibilityLabel("Meeting title")
            } else {
                Button {
                    isEditing = true
                    DispatchQueue.main.async {
                        isTitleFocused = true
                    }
                } label: {
                    Text(text.isEmpty ? "Meeting Title" : text)
                        .font(titleFont)
                        .fontWeight(.bold)
                        .foregroundStyle(text.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to edit the full title")
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }

    private func finishEditing() {
        guard isEditing else { return }
        isEditing = false
        isTitleFocused = false
        onSubmit()
    }
}

struct TranscriptChatMessage: Identifiable, Equatable {
    let id: Int
    let timestamp: String?
    let speaker: String?
    let text: String

    var isUser: Bool {
        speaker?.localizedCaseInsensitiveCompare("You") == .orderedSame
    }

    static func messages(from transcript: String, startingAt firstID: Int = 0) -> [TranscriptChatMessage] {
        let normalized = transcript.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var messages: [TranscriptChatMessage] = []
        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parsed = parseLine(line, id: firstID + messages.count)
            messages.append(parsed)
        }

        return messages
    }

    private static func parseLine(_ line: String, id: Int) -> TranscriptChatMessage {
        if line.hasPrefix("["),
           let timestampEnd = line.firstIndex(of: "]") {
            let timestamp = String(line[line.index(after: line.startIndex)..<timestampEnd])
            let remainderStart = line.index(after: timestampEnd)
            let remainder = line[remainderStart...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speakerText = splitSpeakerAndText(remainder)
            return TranscriptChatMessage(
                id: id,
                timestamp: timestamp.isEmpty ? nil : timestamp,
                speaker: speakerText.speaker,
                text: speakerText.text
            )
        }

        let speakerText = splitSpeakerAndText(line)
        return TranscriptChatMessage(
            id: id,
            timestamp: nil,
            speaker: speakerText.speaker,
            text: speakerText.text
        )
    }

    private static func splitSpeakerAndText(_ text: String) -> (speaker: String?, text: String) {
        guard let separator = text.firstIndex(of: ":") else {
            return (nil, text)
        }

        let candidate = text[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelySpeakerLabel(candidate) else {
            return (nil, text)
        }

        let bodyStart = text.index(after: separator)
        let body = text[bodyStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (candidate, body.isEmpty ? text : body)
    }

    private static func isLikelySpeakerLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 32 else { return false }
        if label.localizedCaseInsensitiveCompare("You") == .orderedSame { return true }
        if label.localizedCaseInsensitiveCompare("Others") == .orderedSame { return true }
        if label.range(of: #"^Speaker\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }
}

private struct MeetingTranscriptView: View {
    let transcript: String
    var scrollable = true
    @State private var messages: [TranscriptChatMessage]

    init(transcript: String, scrollable: Bool = true) {
        self.transcript = transcript
        self.scrollable = scrollable
        _messages = State(initialValue: TranscriptChatMessage.messages(from: transcript))
    }

    @ViewBuilder
    var body: some View {
        if scrollable {
            ScrollView {
                transcriptContent
            }
            .onChange(of: transcript) { _, newTranscript in
                messages = TranscriptChatMessage.messages(from: newTranscript)
            }
        } else {
            transcriptContent
                .onChange(of: transcript) { _, newTranscript in
                    messages = TranscriptChatMessage.messages(from: newTranscript)
                }
        }
    }

    private var transcriptContent: some View {
        LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            if messages.isEmpty {
                Text("No transcript available")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(MuesliTheme.spacing24)
            } else {
                ForEach(messages) { message in
                    TranscriptChatBubble(message: message)
                }
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.vertical, MuesliTheme.spacing16)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct TranscriptChatBubble: View {
    let message: TranscriptChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: MuesliTheme.spacing8) {
            if message.isUser {
                Spacer(minLength: 80)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let metadata = metadata {
                    Text(metadata)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .textSelection(.enabled)
                }
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 8)
            .background(message.isUser ? MuesliTheme.accent.opacity(0.18) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(message.isUser ? MuesliTheme.accent.opacity(0.25) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .frame(maxWidth: 680, alignment: message.isUser ? .trailing : .leading)

            if !message.isUser {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private var metadata: String? {
        switch (message.speaker, message.timestamp) {
        case let (speaker?, timestamp?):
            return "\(speaker) \(timestamp)"
        case let (speaker?, nil):
            return speaker
        case let (nil, timestamp?):
            return timestamp
        case (nil, nil):
            return nil
        }
    }
}
