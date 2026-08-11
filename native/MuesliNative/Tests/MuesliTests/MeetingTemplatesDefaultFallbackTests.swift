import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting template default fallback")
struct MeetingTemplatesDefaultFallbackTests {
    private func makeCustom(id: String, name: String) -> CustomMeetingTemplate {
        CustomMeetingTemplate(
            id: id,
            name: name,
            prompt: "Body for \(name)",
            icon: "square.and.pencil"
        )
    }

    @Test("missing meeting template uses configured custom default")
    func missingTemplateUsesConfiguredCustomDefault() {
        let resolved = MeetingTemplates.resolveDefinition(
            id: nil,
            customTemplates: [makeCustom(id: "custom-1", name: "My Notes")],
            defaultTemplateID: "custom-1"
        )

        #expect(resolved.id == "custom-1")
    }

    @Test("fully stamped meeting template wins over configured default")
    func stampedTemplateWinsOverConfiguredDefault() {
        let meeting = MeetingRecord(
            id: 1,
            title: "Meeting",
            startTime: "2026-08-11T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            wordCount: 1,
            folderID: nil,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Saved Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "Saved prompt"
        )
        let resolved = MeetingTemplates.snapshot(
            for: meeting,
            customTemplates: [makeCustom(id: "custom-1", name: "My Notes")],
            defaultTemplateID: "custom-1"
        )

        #expect(resolved.id == MeetingTemplates.autoID)
        #expect(resolved.name == "Saved Auto")
        #expect(resolved.prompt == "Saved prompt")
    }

    @Test("bare Auto id defers to configured default")
    func bareAutoDefersToConfiguredDefault() {
        let resolved = MeetingTemplates.resolveDefinition(
            id: MeetingTemplates.autoID,
            customTemplates: [makeCustom(id: "custom-1", name: "My Notes")],
            defaultTemplateID: "custom-1"
        )

        #expect(resolved.id == "custom-1")
    }

    @Test("invalid configured default falls back to overridden Auto")
    func invalidDefaultFallsBackToOverriddenAuto() {
        let resolved = MeetingTemplates.resolveDefinition(
            id: nil,
            customTemplates: [],
            builtInOverrides: [BuiltInMeetingTemplateOverride(
                id: MeetingTemplates.autoID,
                prompt: "Custom Auto prompt"
            )],
            defaultTemplateID: "deleted-template"
        )

        #expect(resolved.id == MeetingTemplates.autoID)
        #expect(resolved.promptBody == "Custom Auto prompt")
    }

    @Test("built-in override is retained when selected as default")
    func builtInOverrideIsRetainedForDefault() {
        let builtIn = MeetingTemplates.builtIns[0]
        let resolved = MeetingTemplates.resolveDefinition(
            id: nil,
            customTemplates: [],
            builtInOverrides: [BuiltInMeetingTemplateOverride(
                id: builtIn.id,
                name: "My built-in",
                prompt: "My prompt"
            )],
            defaultTemplateID: builtIn.id
        )

        #expect(resolved.id == builtIn.id)
        #expect(resolved.title == "My built-in")
        #expect(resolved.promptBody == "My prompt")
    }
}
