import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting transcript evidence", .serialized)
struct MeetingTranscriptEvidenceTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-evidence-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeEvidence(meetingID: Int64) -> MeetingTranscriptEvidenceBundle {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let transcript = MeetingTranscriptRevision(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            meetingID: meetingID,
            runID: runID,
            sourceTimelineDigest: "timeline",
            backend: "test",
            model: "asr",
            displayName: "Test ASR",
            purpose: "final",
            spans: [
                MeetingASRSpan(
                    id: "mic-1",
                    source: .microphone,
                    startSeconds: 0,
                    endSeconds: 1,
                    recordingUnitID: "unit-1",
                    text: "Hello",
                    timestampPrecision: .modelSegment
                ),
                MeetingASRSpan(
                    id: "sys-1",
                    source: .system,
                    startSeconds: 1.2,
                    endSeconds: 2.2,
                    recordingUnitID: "unit-1",
                    text: "First response",
                    timestampPrecision: .modelSegment
                ),
                MeetingASRSpan(
                    id: "sys-2",
                    source: .system,
                    startSeconds: 2.5,
                    endSeconds: 3.5,
                    recordingUnitID: "unit-1",
                    text: "Second response",
                    timestampPrecision: .modelSegment
                ),
            ]
        )
        let profile = MeetingDiarizationProfileSnapshot(
            profileID: "offline_quality",
            profileRevision: 1,
            engineID: "offline-community-1",
            engineVersion: "1",
            modelRevision: "community-1",
            modelDigest: "model",
            effectiveConfigurationDigest: "config"
        )
        let diarization = MeetingDiarizationRevision(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            meetingID: meetingID,
            runID: runID,
            timelineDigest: "timeline",
            sourceFingerprints: ["system-unit-1"],
            profile: profile,
            activitySegments: [
                MeetingDiarizationActivitySegment(
                    speakerKey: "remote-a",
                    startSeconds: 1,
                    endSeconds: 2.3
                ),
                MeetingDiarizationActivitySegment(
                    speakerKey: "remote-b",
                    startSeconds: 2.4,
                    endSeconds: 3.7
                ),
            ],
            audioDurationSeconds: 4
        )
        let attribution = MeetingAttributionRevision(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            meetingID: meetingID,
            transcriptRevisionID: transcript.id,
            diarizationRevisionID: diarization.id,
            algorithmID: "homan-overlap",
            algorithmRevision: 1,
            assignments: [
                MeetingSpanSpeakerAssignment(
                    asrSpanID: "mic-1",
                    speakerKey: nil,
                    displayLabel: "You",
                    kind: .sourceAuthoritative,
                    coverage: 1
                ),
                MeetingSpanSpeakerAssignment(
                    asrSpanID: "sys-1",
                    speakerKey: "remote-a",
                    displayLabel: "Speaker 1",
                    kind: .exactOverlap,
                    overlapSeconds: 1,
                    coverage: 1
                ),
                MeetingSpanSpeakerAssignment(
                    asrSpanID: "sys-2",
                    speakerKey: "remote-b",
                    displayLabel: "Speaker 2",
                    kind: .exactOverlap,
                    overlapSeconds: 1,
                    coverage: 1
                ),
            ],
            speakerLabelMap: ["remote-a": "Speaker 1", "remote-b": "Speaker 2"],
            quality: MeetingAttributionQuality(
                timedSystemSpanCount: 2,
                assignedSystemSpanCount: 2,
                ambiguousSystemSpanCount: 0,
                assignmentCoverage: 1,
                publicationReason: "two useful remote speakers"
            ),
            separatedEligible: true
        )
        return MeetingTranscriptEvidenceBundle(
            transcriptRevisions: [transcript],
            diarizationRevisions: [diarization],
            attributionRevisions: [attribution],
            presentation: MeetingTranscriptPresentation(
                transcriptRevisionID: transcript.id,
                activeMode: .separated,
                activeAttributionRevisionID: attribution.id
            )
        )
    }

    @Test("generated and Manual views switch without destroying evidence")
    func presentationSwitchingIsReversible() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let meetingID = try store.insertMeeting(
            title: "Evidence",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(10),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        var evidence = makeEvidence(meetingID: meetingID)
        let separated = try MeetingTranscriptProjection.activated(
            evidence,
            mode: .separated,
            meetingStart: start
        )
        evidence = separated.bundle
        try store.publishMeetingTranscriptEvidence(
            meetingID: meetingID,
            evidence: evidence,
            activeTranscript: separated.text
        )
        let generatedSummaryInput = evidence.summaryInputDescriptor(ownerName: "Yahor")
        #expect(try store.meeting(id: meetingID)?.rawTranscript.contains("Speaker 1") == true)
        #expect(try store.meeting(id: meetingID)?.rawTranscript.contains("Speaker 2") == true)

        let collapsed = try store.activateMeetingTranscriptPresentation(
            meetingID: meetingID,
            mode: .collapsed
        )
        #expect(collapsed.contains("Others: First response Second response"))
        #expect(!collapsed.contains("Speaker 1"))

        try store.updateMeetingTranscript(id: meetingID, rawTranscript: "My corrected transcript")
        let manuallyEditedEvidence = try #require(
            try store.meetingTranscriptEvidence(meetingID: meetingID)
        )
        #expect(manuallyEditedEvidence.presentation.activeMode == .manual)
        #expect(manuallyEditedEvidence.summaryIsStale(generatedSummaryInput, ownerName: "Yahor"))
        #expect(manuallyEditedEvidence.transcriptRevisions.map(\.id) == evidence.transcriptRevisions.map(\.id))
        #expect(
            manuallyEditedEvidence.transcriptRevisions.map(\.contentDigest)
                == evidence.transcriptRevisions.map(\.contentDigest)
        )
        #expect(manuallyEditedEvidence.diarizationRevisions.map(\.id) == evidence.diarizationRevisions.map(\.id))
        #expect(
            manuallyEditedEvidence.diarizationRevisions.map(\.artifactDigest)
                == evidence.diarizationRevisions.map(\.artifactDigest)
        )
        #expect(manuallyEditedEvidence.attributionRevisions.map(\.id) == evidence.attributionRevisions.map(\.id))
        #expect(
            manuallyEditedEvidence.attributionRevisions.map(\.contentDigest)
                == evidence.attributionRevisions.map(\.contentDigest)
        )

        _ = try store.activateMeetingTranscriptPresentation(meetingID: meetingID, mode: .separated)
        let restoredManual = try store.activateMeetingTranscriptPresentation(
            meetingID: meetingID,
            mode: .manual
        )
        #expect(restoredManual == "My corrected transcript")
        #expect(try store.meetingTranscriptEvidence(meetingID: meetingID)?.transcriptRevisions.count == 1)
    }

    @Test("source authority prevents system text from becoming You")
    func systemCanNeverRenderAsYou() throws {
        let transcript = MeetingTranscriptRevision(
            meetingID: 1,
            runID: UUID(),
            sourceTimelineDigest: "x",
            backend: "test",
            model: "test",
            displayName: "test",
            purpose: "test",
            spans: [
                MeetingASRSpan(
                    id: "system",
                    source: .system,
                    startSeconds: 0,
                    endSeconds: 1,
                    text: "remote words",
                    timestampPrecision: .modelSegment
                )
            ]
        )
        let attribution = MeetingAttributionRevision(
            meetingID: 1,
            transcriptRevisionID: transcript.id,
            diarizationRevisionID: nil,
            algorithmID: "malformed-test",
            algorithmRevision: 1,
            assignments: [
                MeetingSpanSpeakerAssignment(
                    asrSpanID: "system",
                    speakerKey: "x",
                    displayLabel: "You",
                    kind: .exactOverlap,
                    coverage: 1
                )
            ],
            speakerLabelMap: ["x": "You"],
            quality: MeetingAttributionQuality(
                timedSystemSpanCount: 1,
                assignedSystemSpanCount: 1,
                ambiguousSystemSpanCount: 0,
                assignmentCoverage: 1,
                publicationReason: "test"
            ),
            separatedEligible: true
        )
        let rendered = MeetingTranscriptProjection.render(
            transcript: transcript,
            attribution: attribution,
            separated: true,
            meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(rendered.contains("Others: remote words"))
        #expect(!rendered.contains("You: remote words"))
    }

    @Test("speaker numbers follow first accepted text and mixed audio never fabricates You")
    func speakerNumberingUsesAcceptedTranscriptOrder() {
        let transcript = MeetingTranscriptRevision(
            meetingID: 1,
            runID: UUID(),
            sourceTimelineDigest: "timeline",
            backend: "test",
            model: "test",
            displayName: "test",
            purpose: "test",
            spans: [
                MeetingASRSpan(
                    id: "later-a",
                    source: .legacyMixed,
                    startSeconds: 5,
                    endSeconds: 6,
                    text: "later voice",
                    timestampPrecision: .modelSegment
                ),
                MeetingASRSpan(
                    id: "first-b",
                    source: .legacyMixed,
                    startSeconds: 2,
                    endSeconds: 3,
                    text: "first accepted voice",
                    timestampPrecision: .modelSegment
                ),
            ]
        )
        let diarization = MeetingDiarizationRevision(
            meetingID: 1,
            runID: UUID(),
            timelineDigest: "timeline",
            sourceFingerprints: ["mixed"],
            profile: MeetingDiarizationProfileSnapshot(
                profileID: "test",
                profileRevision: 1,
                engineID: "test",
                engineVersion: "1",
                modelRevision: "1",
                modelDigest: "digest",
                effectiveConfigurationDigest: "config"
            ),
            activitySegments: [
                // Activity for A starts earlier in silence, but B owns the
                // first accepted text and must therefore become Speaker 1.
                MeetingDiarizationActivitySegment(
                    speakerKey: "voice-a",
                    startSeconds: 0,
                    endSeconds: 1
                ),
                MeetingDiarizationActivitySegment(
                    speakerKey: "voice-b",
                    startSeconds: 2,
                    endSeconds: 3
                ),
                MeetingDiarizationActivitySegment(
                    speakerKey: "voice-a",
                    startSeconds: 5,
                    endSeconds: 6
                ),
            ],
            audioDurationSeconds: 6
        )

        let attribution = MeetingSpeakerAttribution.makeRevision(
            meetingID: 1,
            transcript: transcript,
            diarization: diarization
        )
        #expect(attribution.speakerLabelMap["voice-b"] == "Speaker 1")
        #expect(attribution.speakerLabelMap["voice-a"] == "Speaker 2")

        let separated = MeetingTranscriptProjection.render(
            transcript: transcript,
            attribution: attribution,
            separated: true,
            meetingStart: Date(timeIntervalSince1970: 0)
        )
        let collapsed = MeetingTranscriptProjection.render(
            transcript: transcript,
            attribution: attribution,
            separated: false,
            meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(separated.contains("Speaker 1: first accepted voice"))
        #expect(separated.contains("Speaker 2: later voice"))
        #expect(collapsed.contains("Speaker: first accepted voice later voice"))
        #expect(!separated.contains("You:"))
        #expect(!collapsed.contains("You:"))
    }

    @Test("fine timestamp attribution stays ambiguous at an even speaker boundary")
    func fineTimestampBoundaryRequiresDominantSpeaker() throws {
        let transcript = MeetingTranscriptRevision(
            meetingID: 1,
            runID: UUID(),
            sourceTimelineDigest: "timeline",
            backend: "test",
            model: "test",
            displayName: "test",
            purpose: "test",
            spans: [MeetingASRSpan(
                id: "boundary",
                source: .system,
                startSeconds: 1,
                endSeconds: 3,
                text: "shared boundary",
                timestampPrecision: .modelSegment
            )]
        )
        let diarization = MeetingDiarizationRevision(
            meetingID: 1,
            runID: UUID(),
            timelineDigest: "timeline",
            sourceFingerprints: ["system"],
            profile: MeetingDiarizationProfileSnapshot(
                profileID: "test",
                profileRevision: 1,
                engineID: "test",
                engineVersion: "1",
                modelRevision: "1",
                modelDigest: "digest",
                effectiveConfigurationDigest: "config"
            ),
            activitySegments: [
                MeetingDiarizationActivitySegment(
                    speakerKey: "voice-a",
                    startSeconds: 1,
                    endSeconds: 2
                ),
                MeetingDiarizationActivitySegment(
                    speakerKey: "voice-b",
                    startSeconds: 2,
                    endSeconds: 3
                ),
            ],
            audioDurationSeconds: 3
        )

        let attribution = MeetingSpeakerAttribution.makeRevision(
            meetingID: 1,
            transcript: transcript,
            diarization: diarization
        )
        let assignment = try #require(attribution.assignments.first)
        #expect(assignment.kind == .ambiguous)
        #expect(assignment.displayLabel == "Others")
        #expect(assignment.speakerKey == nil)
        #expect(attribution.speakerLabelMap.isEmpty)
        #expect(!attribution.separatedEligible)
    }

    @Test("transcript expiry and meeting deletion remove evidence")
    func retentionAndDeletionOwnEvidence() throws {
        let store = try makeStore()
        let old = Date(timeIntervalSince1970: 1_000)
        let meetingID = try store.insertMeeting(
            title: "Old",
            calendarEventID: nil,
            startTime: old,
            endTime: old.addingTimeInterval(10),
            rawTranscript: "legacy",
            formattedNotes: "summary",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let evidence = MeetingTranscriptEvidenceBundle.legacy(rawTranscript: "legacy")
        try store.publishMeetingTranscriptEvidence(
            meetingID: meetingID,
            evidence: evidence,
            activeTranscript: "legacy"
        )
        #expect(try store.clearExpiredMeetingTranscripts(
            asOf: old.addingTimeInterval(3 * 24 * 60 * 60),
            retentionDays: 1
        ) == 1)
        #expect(try store.meetingTranscriptEvidence(meetingID: meetingID) == nil)

        let currentID = try store.insertMeeting(
            title: "Delete",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date(),
            rawTranscript: "text",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.publishMeetingTranscriptEvidence(
            meetingID: currentID,
            evidence: .legacy(rawTranscript: "text"),
            activeTranscript: "text"
        )
        try store.deleteMeeting(id: currentID)
        #expect(try store.meetingTranscriptEvidence(meetingID: currentID) == nil)
    }

    @Test("evidence publication rejects a mismatched materialized transcript atomically")
    func evidencePublicationValidatesMaterializedTranscript() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let meetingID = try store.insertMeeting(
            title: "Integrity",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(10),
            rawTranscript: "Original",
            formattedNotes: "Summary",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let evidence = MeetingTranscriptEvidenceBundle.legacy(rawTranscript: "Structured")

        #expect(throws: DictationStoreError.invalidTranscriptEvidence) {
            try store.publishMeetingTranscriptEvidence(
                meetingID: meetingID,
                evidence: evidence,
                activeTranscript: "Different"
            )
        }

        #expect(try store.meeting(id: meetingID)?.rawTranscript == "Original")
        #expect(try store.meetingTranscriptEvidence(meetingID: meetingID) == nil)
    }

    @Test("evidence publication rejects duplicate attribution keys before projection")
    func evidencePublicationValidatesInternalReferences() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        let meetingID = try store.insertMeeting(
            title: "Malformed evidence",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(10),
            rawTranscript: "Original",
            formattedNotes: "Summary",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        var evidence = makeEvidence(meetingID: meetingID)
        let original = try #require(evidence.attributionRevisions.first)
        let duplicate = try #require(original.assignments.first)
        evidence.attributionRevisions = [MeetingAttributionRevision(
            id: original.id,
            meetingID: meetingID,
            transcriptRevisionID: original.transcriptRevisionID,
            diarizationRevisionID: original.diarizationRevisionID,
            algorithmID: original.algorithmID,
            algorithmRevision: original.algorithmRevision,
            assignments: [duplicate, duplicate],
            speakerLabelMap: original.speakerLabelMap,
            quality: original.quality,
            separatedEligible: original.separatedEligible
        )]
        let claimedText = "Claimed active text"
        evidence.presentation.activeTextDigest = MeetingTranscriptDigest.text(claimedText)

        #expect(throws: DictationStoreError.invalidTranscriptEvidence) {
            try store.publishMeetingTranscriptEvidence(
                meetingID: meetingID,
                evidence: evidence,
                activeTranscript: claimedText
            )
        }
        #expect(try store.meeting(id: meetingID)?.rawTranscript == "Original")
    }

    @Test("evidence publication rejects active attribution from another transcript revision")
    func evidencePublicationRejectsCrossRevisionAttribution() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_150)
        let meetingID = try store.insertMeeting(
            title: "Cross-revision evidence",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(10),
            rawTranscript: "Original",
            formattedNotes: "Summary",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        var evidence = makeEvidence(meetingID: meetingID)
        let originalTranscript = try #require(evidence.transcriptRevisions.first)
        let originalAttribution = try #require(evidence.attributionRevisions.first)
        let otherTranscript = MeetingTranscriptRevision(
            id: UUID(),
            meetingID: meetingID,
            runID: UUID(),
            createdAt: originalTranscript.createdAt,
            sourceTimelineDigest: originalTranscript.sourceTimelineDigest,
            sourceTimelineMap: originalTranscript.sourceTimelineMap,
            backend: originalTranscript.backend,
            model: originalTranscript.model,
            displayName: originalTranscript.displayName,
            purpose: originalTranscript.purpose,
            spans: originalTranscript.spans,
            status: originalTranscript.status
        )
        let otherAttribution = MeetingAttributionRevision(
            id: UUID(),
            meetingID: meetingID,
            transcriptRevisionID: otherTranscript.id,
            diarizationRevisionID: originalAttribution.diarizationRevisionID,
            algorithmID: originalAttribution.algorithmID,
            algorithmRevision: originalAttribution.algorithmRevision,
            assignments: originalAttribution.assignments,
            speakerLabelMap: originalAttribution.speakerLabelMap,
            quality: originalAttribution.quality,
            separatedEligible: originalAttribution.separatedEligible
        )
        evidence.transcriptRevisions.append(otherTranscript)
        evidence.attributionRevisions.append(otherAttribution)
        evidence.presentation.activeMode = .collapsed
        evidence.presentation.activeAttributionRevisionID = otherAttribution.id
        let materialized = try MeetingTranscriptProjection.render(
            bundle: evidence,
            mode: .collapsed,
            meetingStart: start
        )
        evidence.presentation.activeTextDigest = MeetingTranscriptDigest.text(materialized)

        #expect(throws: DictationStoreError.invalidTranscriptEvidence) {
            try store.publishMeetingTranscriptEvidence(
                meetingID: meetingID,
                evidence: evidence,
                activeTranscript: materialized
            )
        }
        #expect(try store.meetingTranscriptEvidence(meetingID: meetingID) == nil)
    }

    @Test("evidence publication rejects a transcript timeline map with a different digest")
    func evidencePublicationValidatesTranscriptTimelineMap() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_200)
        let meetingID = try store.insertMeeting(
            title: "Timeline integrity",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(10),
            rawTranscript: "Original",
            formattedNotes: "Summary",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        var evidence = makeEvidence(meetingID: meetingID)
        let original = try #require(evidence.transcriptRevisions.first)
        let map = timelineMap(
            unitID: "unit-1",
            fingerprint: "system-unit-1",
            duration: 4
        )
        evidence.transcriptRevisions = [MeetingTranscriptRevision(
            id: original.id,
            meetingID: original.meetingID,
            runID: original.runID,
            createdAt: original.createdAt,
            sourceTimelineDigest: "not-the-map-digest",
            sourceTimelineMap: map,
            backend: original.backend,
            model: original.model,
            displayName: original.displayName,
            purpose: original.purpose,
            spans: original.spans,
            status: original.status
        )]
        let materialized = try MeetingTranscriptProjection.render(
            bundle: evidence,
            mode: evidence.presentation.activeMode,
            meetingStart: start
        )
        evidence.presentation.activeTextDigest = MeetingTranscriptDigest.text(materialized)

        #expect(throws: DictationStoreError.invalidTranscriptEvidence) {
            try store.publishMeetingTranscriptEvidence(
                meetingID: meetingID,
                evidence: evidence,
                activeTranscript: materialized
            )
        }
        #expect(try store.meetingTranscriptEvidence(meetingID: meetingID) == nil)
    }

    @Test("resumed evidence uses the renderer's overlap-compacted timeline")
    func resumedEvidenceCombinesTimelineExactly() throws {
        let meetingID: Int64 = 77
        let meetingStart = Date(timeIntervalSince1970: 1_700_001_000)
        let priorResult = transcriptionResult(
            unitID: "first",
            startedAt: meetingStart,
            text: "first remote turn",
            localStart: 1,
            localEnd: 2,
            map: timelineMap(unitID: "first", fingerprint: "first-audio", duration: 10)
        )
        let prior = try MeetingTranscriptEvidenceFactory.makePublication(
            meetingID: meetingID,
            meetingStart: meetingStart,
            result: priorResult,
            backend: .whisperSmall,
            purpose: .final,
            runID: UUID()
        )

        // The resumed wall-clock start is 6s, inside the first unit's 10s
        // logical extent. The renderer compacts that overlap to start at 10s.
        let resumedStart = meetingStart.addingTimeInterval(6)
        let resumedResult = transcriptionResult(
            unitID: "second",
            startedAt: resumedStart,
            text: "second remote turn",
            localStart: 1,
            localEnd: 2,
            map: timelineMap(unitID: "second", fingerprint: "second-audio", duration: 5)
        )
        let appended = try MeetingTranscriptEvidenceFactory.makeAppendedPublication(
            meetingID: meetingID,
            meetingStart: meetingStart,
            result: resumedResult,
            backend: .whisperSmall,
            purpose: .recovery,
            runID: UUID(),
            priorEvidence: prior.evidence
        )

        let map = try #require(appended.transcriptRevision.sourceTimelineMap)
        #expect(map.entries.count == 2)
        #expect(map.entries[1].globalStartSeconds == 10)
        #expect(map.entries[1].globalEndSeconds == 15)
        #expect(map.entries[1].boundaryKind == .overlapCompacted)
        #expect(appended.transcriptRevision.sourceTimelineDigest == map.digest)
        let resumedSpan = try #require(
            appended.transcriptRevision.spans.first { $0.text == "second remote turn" }
        )
        #expect(resumedSpan.startSeconds == 11)
        #expect(resumedSpan.endSeconds == 12)
    }

    @Test("sync installs compatible evidence and clears stale local evidence")
    func syncEvidenceFollowsRemoteMaterializedText() throws {
        let store = try makeStore()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let transcript = "[10:00:00] Others: Remote text"
        let evidence = MeetingTranscriptEvidenceBundle.legacy(
            rawTranscript: transcript,
            at: created
        )
        let recordID = "meeting-evidence-sync"

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordID,
            kind: .meeting,
            title: "Synced",
            text: transcript,
            speakerTranscript: transcript,
            summaryText: "Summary",
            source: "macOS",
            localSource: MeetingSource.meeting.rawValue,
            meetingStatus: .completed,
            createdAt: created,
            updatedAt: created,
            startedAt: created,
            endedAt: created.addingTimeInterval(30),
            durationSeconds: 30,
            wordCount: 2,
            transcriptEvidence: evidence
        )))

        let meeting = try #require(store.recentMeetings(limit: nil).first)
        #expect(try store.meetingTranscriptEvidence(meetingID: meeting.id) != nil)

        let newer = created.addingTimeInterval(60)
        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordID,
            kind: .meeting,
            title: "Synced",
            text: "Replacement text",
            speakerTranscript: "Replacement text",
            summaryText: "Summary",
            source: "macOS",
            localSource: MeetingSource.meeting.rawValue,
            meetingStatus: .completed,
            createdAt: created,
            updatedAt: newer,
            startedAt: created,
            endedAt: created.addingTimeInterval(30),
            durationSeconds: 30,
            wordCount: 2,
            transcriptEvidence: nil
        )))

        #expect(try store.meetingTranscriptEvidence(meetingID: meeting.id) == nil)
        #expect(try store.meeting(id: meeting.id)?.rawTranscript == "Replacement text")
    }

    @Test("summary provenance becomes stale when owner identity or role contract changes")
    func summaryProvenanceTracksOwnerAndRoleContract() {
        let evidence = MeetingTranscriptEvidenceBundle.legacy(rawTranscript: "Transcript")
        let input = evidence.summaryInputDescriptor(ownerName: "  Yahor Zaleski  ")

        #expect(!evidence.summaryIsStale(input, ownerName: "Yahor Zaleski"))
        #expect(evidence.summaryIsStale(input, ownerName: "Another owner"))

        let priorContract = MeetingSummaryInputDescriptor(
            transcriptRevisionID: input.transcriptRevisionID,
            attributionRevisionID: input.attributionRevisionID,
            presentationMode: input.presentationMode,
            transcriptDigest: input.transcriptDigest,
            ownerName: input.ownerName,
            speakerLegendVersion: 0
        )
        #expect(evidence.summaryIsStale(priorContract, ownerName: "Yahor Zaleski"))
    }

    @Test("source-only attribution does not expose a fake Separated view")
    func separatedViewRequiresAcousticSpeakerEvidence() throws {
        let original = makeEvidence(meetingID: 1)
        let transcript = try #require(original.activeTranscriptRevision)
        let attribution = MeetingSpeakerAttribution.makeRevision(
            meetingID: 1,
            transcript: transcript,
            diarization: nil
        )
        let evidence = MeetingTranscriptEvidenceBundle(
            transcriptRevisions: [transcript],
            diarizationRevisions: [],
            attributionRevisions: [attribution],
            presentation: MeetingTranscriptPresentation(
                transcriptRevisionID: transcript.id,
                activeMode: .collapsed,
                activeAttributionRevisionID: attribution.id
            )
        )

        #expect(evidence.availablePresentationModes == [.collapsed])
    }

    @Test("speaker-analysis revisions do not stale an unchanged Manual summary")
    func manualSummaryIgnoresInactiveAttributionRevision() {
        var evidence = makeEvidence(meetingID: 1)
        evidence.storeManualPresentation("My corrected transcript")
        let summaryInput = evidence.summaryInputDescriptor(ownerName: "Yahor")

        evidence.presentation.activeAttributionRevisionID = UUID()

        #expect(!evidence.summaryIsStale(summaryInput, ownerName: "Yahor"))
    }

    private func timelineMap(
        unitID: String,
        fingerprint: String,
        duration: TimeInterval
    ) -> MeetingSystemTimelineMap {
        MeetingSystemTimelineMap(
            totalDurationSeconds: duration,
            entries: [MeetingSystemTimelineMapEntry(
                unitID: unitID,
                sourceFingerprint: fingerprint,
                unitStartSeconds: 0,
                unitEndSeconds: duration,
                globalStartSeconds: 0,
                globalEndSeconds: duration,
                boundaryKind: .first
            )]
        )
    }

    private func transcriptionResult(
        unitID: String,
        startedAt: Date,
        text: String,
        localStart: TimeInterval,
        localEnd: TimeInterval,
        map: MeetingSystemTimelineMap
    ) -> MeetingTranscriptionResult {
        let recognized = SourceRecognizedSegment(
            id: "system-1",
            source: .system,
            startSeconds: localStart,
            endSeconds: localEnd,
            text: text,
            confidence: nil,
            timestampPrecision: .modelSegment
        )
        let turn = AttributedTurn(
            sourceRole: .others,
            remoteSpeaker: nil,
            startSeconds: localStart,
            endSeconds: localEnd,
            text: text,
            isProvisional: false,
            recordingSessionID: nil
        )
        let unit = MeetingUnitTranscriptionResult(
            unitID: unitID,
            sessionID: nil,
            startedAt: startedAt,
            attributedTurns: [turn],
            formattedTranscript: text,
            degradations: [],
            recognizedSegments: [recognized],
            microphoneSegments: [],
            systemSegments: [],
            diarizationSegments: nil
        )
        return MeetingTranscriptionResult(
            units: [unit],
            attributedTurns: [turn],
            formattedTranscript: text,
            degradations: [],
            systemTimelineMap: map,
            diarizationProfile: nil,
            diarizationTimings: nil,
            reusedDiarizationRevisionID: nil
        )
    }
}
