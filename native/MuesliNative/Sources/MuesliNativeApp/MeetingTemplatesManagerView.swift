import SwiftUI
import MuesliCore

struct MeetingTemplatesManagerView: View {
    let appState: AppState
    let controller: MuesliController
    let onClose: () -> Void

    @State private var isCreatingTemplate = false
    @State private var editingTemplateID: String?
    @State private var editingBuiltInTemplateID: String?
    @State private var isEditingSummaryPrompts = false
    @State private var draftTemplateName = ""
    @State private var draftTemplatePrompt = ""
    @State private var draftTemplateIcon = MeetingTemplates.customIconFallback
    @State private var draftSummarySystemPrompt = ""
    @State private var draftSummaryUserPrompt = ""
    @State private var summaryPromptValidationIssues: [String] = []
    @State private var showNameValidationError = false
    @State private var showPromptValidationError = false
    @State private var templateToDelete: CustomMeetingTemplate?
    @State private var templateToReset: MeetingTemplateDefinition?
    @State private var isSummaryPromptResetConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manage Templates")
                        .font(MuesliTheme.title2())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Customize built-in meeting formats or create your own.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                HStack(spacing: MuesliTheme.spacing8) {
                    if isEditingTemplateInProgress {
                        actionButton("Cancel", systemImage: "xmark") {
                            resetActiveEditor()
                        }
                    } else {
                        actionButton("New template", systemImage: "plus") {
                            beginCreatingTemplate()
                        }
                    }

                    actionButton("Done", systemImage: "checkmark") {
                        onClose()
                    }
                    .disabled(isEditingTemplateInProgress)
                    .opacity(isEditingTemplateInProgress ? 0.55 : 1)
                    .help(isEditingTemplateInProgress ? "Finish or cancel template editing before closing." : "Close template manager")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    sectionHeader("Full Summary Prompt")
                    summaryPromptRow

                    if isEditingSummaryPrompts {
                        summaryPromptEditor
                    }

                    sectionHeader("Built-in Templates")
                        .padding(.top, MuesliTheme.spacing8)

                    VStack(spacing: MuesliTheme.spacing8) {
                        ForEach(controller.editableBuiltInMeetingTemplates()) { template in
                            builtInTemplateRow(template)
                        }
                    }

                    sectionHeader("Custom Templates")
                        .padding(.top, MuesliTheme.spacing8)

                    if controller.customMeetingTemplates().isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: MuesliTheme.spacing8) {
                            ForEach(controller.customMeetingTemplates()) { template in
                                customTemplateRow(template)
                            }
                        }
                    }

                    if isEditingTemplateInProgress && !isEditingSummaryPrompts {
                        customTemplateEditor
                    }
                }
                .padding(.bottom, MuesliTheme.spacing4)
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(minWidth: 760, minHeight: 520)
        .background(MuesliTheme.backgroundBase)
        .alert(
            "Delete \"\(templateToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { templateToDelete != nil },
                set: { if !$0 { templateToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                templateToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let template = templateToDelete else { return }
                controller.deleteCustomMeetingTemplate(id: template.id)
                if editingTemplateID == template.id {
                    resetTemplateEditor()
                }
                templateToDelete = nil
            }
        } message: {
            Text("This template will be permanently removed. Existing meetings will keep their saved template snapshot.")
        }
        .alert(
            "Reset \"\(templateToReset?.title ?? "")\"?",
            isPresented: Binding(
                get: { templateToReset != nil },
                set: { if !$0 { templateToReset = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                templateToReset = nil
            }
            Button("Reset to Defaults", role: .destructive) {
                guard let template = templateToReset else { return }
                controller.resetBuiltInMeetingTemplate(id: template.id)
                if editingBuiltInTemplateID == template.id {
                    resetTemplateEditor()
                }
                templateToReset = nil
            }
        } message: {
            Text("Your changes to this built-in template will be removed. Existing meetings will keep their saved template snapshot.")
        }
        .alert("Reset full summary prompt?", isPresented: $isSummaryPromptResetConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Reset to Defaults", role: .destructive) {
                controller.resetMeetingSummaryPrompts()
                if isEditingSummaryPrompts {
                    resetSummaryPromptEditor()
                }
            }
        } message: {
            Text("Both the System message and User input will return to their built-in defaults. Meeting profile templates are not changed.")
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.textSecondary)
    }

    @ViewBuilder
    private var summaryPromptRow: some View {
        let isModified = appState.config.hasMeetingSummaryPromptOverride
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MuesliTheme.accent)
                    Text("Global LLM prompt")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    if isModified {
                        templateBadge("Modified", emphasized: true)
                    }
                }
                Text("System and user messages shared by every meeting profile. The selected profile is inserted through {{template}}.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            HStack(spacing: MuesliTheme.spacing8) {
                actionButton("Edit", systemImage: "pencil") {
                    beginEditingSummaryPrompts()
                }
                actionButton("Reset to Defaults", systemImage: "arrow.counterclockwise") {
                    isSummaryPromptResetConfirmationPresented = true
                }
                .disabled(!isModified)
                .opacity(isModified ? 1 : 0.45)
                .help(isModified ? "Restore both prompt messages" : "The full prompt already uses its defaults")
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var summaryPromptEditor: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit full summary prompt")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("System instructions stay separate from transcript data for every supported LLM backend.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                actionButton("Reset draft", systemImage: "arrow.counterclockwise") {
                    draftSummarySystemPrompt = MeetingSummaryPromptTemplates.defaultSystem
                    draftSummaryUserPrompt = MeetingSummaryPromptTemplates.defaultUser
                    summaryPromptValidationIssues = []
                }
            }

            promptMessageEditor(
                title: "System message",
                help: "Global behavior and the selected meeting profile. Required: {{template}}.",
                text: $draftSummarySystemPrompt,
                placeholderNames: [
                    "template", "template_name", "user_name", "written_notes", "previous_meeting_notes",
                ]
            )

            promptMessageEditor(
                title: "User input",
                help: "Meeting data sent as the user message. Required: {{meeting_title}} (or {{meeting_name}}) and {{transcript}}.",
                text: $draftSummaryUserPrompt,
                placeholderNames: [
                    "meeting_title", "meeting_name", "transcript", "meeting_context", "previous_meeting_notes",
                    "written_notes", "user_name", "template_name", "template",
                ]
            )

            VStack(alignment: .leading, spacing: 5) {
                Text("Conditional blocks")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textSecondary)
                Text("These markers are controls, not text sent literally to the LLM. Everything between {{#name}} and {{/name}} is included only when that value exists; otherwise the entire block is removed.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("{{#written_notes}}Use the user's notes.{{/written_notes}}")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .textSelection(.enabled)
                Text("written_notes = notes typed by the user during recording · previous_meeting_notes = notes from a linked earlier meeting")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !summaryPromptValidationIssues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(summaryPromptValidationIssues, id: \.self) { issue in
                        Text(issue)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.recording)
                    }
                }
            }

            HStack {
                Spacer()
                actionButton("Save full prompt", systemImage: "checkmark.circle") {
                    saveSummaryPromptEditor()
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(
                    summaryPromptValidationIssues.isEmpty
                        ? MuesliTheme.surfaceBorder
                        : MuesliTheme.recording.opacity(0.75),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func promptMessageEditor(
        title: String,
        help: String,
        text: Binding<String>,
        placeholderNames: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(help)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MuesliTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: title == "System message" ? 230 : 260)
                .padding(MuesliTheme.spacing8)
                .background(MuesliTheme.backgroundBase)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    summaryPromptValidationIssues = []
                }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(
                    MeetingSummaryPromptTemplates.placeholders.filter { placeholderNames.contains($0.name) }
                ) { placeholder in
                    Button {
                        appendPromptPlaceholder(placeholder.token, to: text)
                    } label: {
                        Text(placeholder.token)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(MuesliTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(MuesliTheme.accentSubtle)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                    .help("Insert \(placeholder.label): \(placeholder.description)")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: MeetingTemplates.customIconFallback)
                .font(.system(size: 11))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("No custom templates yet.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, 10)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func builtInTemplateRow(_ template: MeetingTemplateDefinition) -> some View {
        let isModified = controller.isBuiltInMeetingTemplateModified(id: template.id)
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: template.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.accent)
                        Text(template.title)
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        templateBadge("Built-in", emphasized: false)
                        if isModified {
                            templateBadge("Modified", emphasized: true)
                        }
                    }
                    Text(template.promptBody)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                HStack(spacing: MuesliTheme.spacing8) {
                    actionButton("Edit", systemImage: "pencil") {
                        beginEditingBuiltInTemplate(template)
                    }
                    actionButton("Copy to New", systemImage: "doc.on.doc") {
                        beginCopyingBuiltInTemplate(template)
                    }
                    actionButton("Reset to Defaults", systemImage: "arrow.counterclockwise") {
                        templateToReset = template
                    }
                    .disabled(!isModified)
                    .opacity(isModified ? 1 : 0.45)
                    .help(
                        isModified
                            ? "Restore the current built-in defaults"
                            : "This template already uses its defaults"
                    )
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func templateBadge(_ title: String, emphasized: Bool) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(emphasized ? MuesliTheme.accent : MuesliTheme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(emphasized ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func customTemplateRow(_ template: CustomMeetingTemplate) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: template.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.accent)
                        Text(template.name)
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textPrimary)
                    }
                    Text(template.prompt)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                HStack(spacing: MuesliTheme.spacing8) {
                    actionButton("Edit", systemImage: "pencil") {
                        beginEditingTemplate(template)
                    }
                    actionButton("Delete", systemImage: "trash", role: .destructive) {
                        templateToDelete = template
                    }
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var customTemplateEditor: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text(templateEditorTitle)
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                TextField("Customer follow-up", text: $draftTemplateName)
                    .textFieldStyle(.roundedBorder)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                showNameValidationError ? MuesliTheme.recording.opacity(0.75) : .clear,
                                lineWidth: 1
                            )
                    }
                    .onChange(of: draftTemplateName) { _, newValue in
                        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            showNameValidationError = false
                        }
                    }
                if showNameValidationError {
                    Text("Enter a template name.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.recording)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                customIconPicker
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                TextEditor(text: $draftTemplatePrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(MuesliTheme.spacing8)
                    .background(MuesliTheme.backgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(
                                showPromptValidationError ? MuesliTheme.recording.opacity(0.75) : MuesliTheme.surfaceBorder,
                                lineWidth: 1
                            )
                    )
                    .onChange(of: draftTemplatePrompt) { _, newValue in
                        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            showPromptValidationError = false
                        }
                    }
                if showPromptValidationError {
                    Text("Enter the prompt instructions for this template.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.recording)
                }
            }

            HStack {
                Spacer()
                actionButton(
                    isCreatingTemplate ? "Create template" : "Save changes",
                    systemImage: isCreatingTemplate ? "plus.circle" : "checkmark.circle"
                ) {
                    saveTemplateEditor()
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func beginCreatingTemplate() {
        isEditingSummaryPrompts = false
        isCreatingTemplate = true
        editingTemplateID = nil
        editingBuiltInTemplateID = nil
        draftTemplateName = ""
        draftTemplatePrompt = ""
        draftTemplateIcon = MeetingTemplates.customIconFallback
        clearValidationErrors()
    }

    private func beginEditingTemplate(_ template: CustomMeetingTemplate) {
        isEditingSummaryPrompts = false
        isCreatingTemplate = false
        editingTemplateID = template.id
        editingBuiltInTemplateID = nil
        draftTemplateName = template.name
        draftTemplatePrompt = template.prompt
        draftTemplateIcon = MeetingTemplates.normalizedCustomIcon(named: template.icon)
        clearValidationErrors()
    }

    private func beginEditingBuiltInTemplate(_ template: MeetingTemplateDefinition) {
        isEditingSummaryPrompts = false
        isCreatingTemplate = false
        editingTemplateID = nil
        editingBuiltInTemplateID = template.id
        draftTemplateName = template.title
        draftTemplatePrompt = template.promptBody
        draftTemplateIcon = MeetingTemplates.normalizedCustomIcon(named: template.icon)
        clearValidationErrors()
    }

    private func beginCopyingBuiltInTemplate(_ template: MeetingTemplateDefinition) {
        isEditingSummaryPrompts = false
        isCreatingTemplate = true
        editingTemplateID = nil
        editingBuiltInTemplateID = nil
        draftTemplateName = "\(template.title) Copy"
        draftTemplatePrompt = template.promptBody
        draftTemplateIcon = MeetingTemplates.normalizedCustomIcon(named: template.icon)
        clearValidationErrors()
    }

    private func resetTemplateEditor() {
        isCreatingTemplate = false
        editingTemplateID = nil
        editingBuiltInTemplateID = nil
        draftTemplateName = ""
        draftTemplatePrompt = ""
        draftTemplateIcon = MeetingTemplates.customIconFallback
        clearValidationErrors()
    }

    private func beginEditingSummaryPrompts() {
        resetTemplateEditor()
        isEditingSummaryPrompts = true
        draftSummarySystemPrompt = appState.config.resolvedMeetingSummarySystemPrompt
        draftSummaryUserPrompt = appState.config.resolvedMeetingSummaryUserPrompt
        summaryPromptValidationIssues = []
    }

    private func saveSummaryPromptEditor() {
        let issues = MeetingSummaryPromptTemplates.validationIssues(
            system: draftSummarySystemPrompt,
            user: draftSummaryUserPrompt
        )
        summaryPromptValidationIssues = issues
        guard issues.isEmpty else { return }
        controller.updateMeetingSummaryPrompts(
            system: draftSummarySystemPrompt,
            user: draftSummaryUserPrompt
        )
        resetSummaryPromptEditor()
    }

    private func resetSummaryPromptEditor() {
        isEditingSummaryPrompts = false
        draftSummarySystemPrompt = ""
        draftSummaryUserPrompt = ""
        summaryPromptValidationIssues = []
    }

    private func resetActiveEditor() {
        resetTemplateEditor()
        resetSummaryPromptEditor()
    }

    private func appendPromptPlaceholder(_ token: String, to text: Binding<String>) {
        let separator = text.wrappedValue.isEmpty || text.wrappedValue.hasSuffix("\n") ? "" : "\n"
        text.wrappedValue += separator + token
        summaryPromptValidationIssues = []
    }

    private func saveTemplateEditor() {
        let trimmedName = draftTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = draftTemplatePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        showNameValidationError = trimmedName.isEmpty
        showPromptValidationError = trimmedPrompt.isEmpty
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }

        if let editingBuiltInTemplateID {
            controller.updateBuiltInMeetingTemplate(
                id: editingBuiltInTemplateID,
                name: trimmedName,
                prompt: trimmedPrompt,
                icon: draftTemplateIcon
            )
        } else if let editingTemplateID {
            controller.updateCustomMeetingTemplate(
                id: editingTemplateID,
                name: trimmedName,
                prompt: trimmedPrompt,
                icon: draftTemplateIcon
            )
        } else {
            controller.createCustomMeetingTemplate(
                name: trimmedName,
                prompt: trimmedPrompt,
                icon: draftTemplateIcon
            )
        }
        resetTemplateEditor()
    }

    private var isEditingTemplateInProgress: Bool {
        isEditingSummaryPrompts || isCreatingTemplate || editingTemplateID != nil || editingBuiltInTemplateID != nil
    }

    private var templateEditorTitle: String {
        if editingBuiltInTemplateID != nil {
            return "Edit built-in template"
        }
        return isCreatingTemplate ? "New template" : "Edit template"
    }

    private func clearValidationErrors() {
        showNameValidationError = false
        showPromptValidationError = false
    }

    @ViewBuilder
    private var customIconPicker: some View {
        let columns = [
            GridItem(.adaptive(minimum: 36, maximum: 36), spacing: 6)
        ]

        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing8) {
                Image(systemName: draftTemplateIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 24, height: 24)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                Text(selectedIconLabel)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(MeetingTemplates.customIconOptions) { icon in
                    Button {
                        draftTemplateIcon = icon.symbolName
                    } label: {
                        Image(systemName: icon.symbolName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(
                                draftTemplateIcon == icon.symbolName
                                    ? MuesliTheme.accent
                                    : MuesliTheme.textSecondary
                            )
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(
                                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                    .fill(
                                        draftTemplateIcon == icon.symbolName
                                            ? MuesliTheme.accent.opacity(0.12)
                                            : MuesliTheme.backgroundRaised
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                    .strokeBorder(
                                        draftTemplateIcon == icon.symbolName
                                            ? MuesliTheme.accent.opacity(0.35)
                                            : MuesliTheme.surfaceBorder,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(icon.label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedIconLabel: String {
        MeetingTemplates.customIconOptions.first(where: { $0.symbolName == draftTemplateIcon })?.label ?? "Custom"
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isDestructive ? MuesliTheme.recording : MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(isDestructive ? MuesliTheme.recording.opacity(0.1) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(
                        isDestructive ? MuesliTheme.recording.opacity(0.2) : MuesliTheme.surfaceBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
