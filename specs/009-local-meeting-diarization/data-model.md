# Data Model: Local Meeting Diarization

The durable model separates recognized words, acoustic speaker activity, their join, and the text
presentation selected by the user. `meetings.raw_transcript` remains an active materialized snapshot
for backward compatibility; it is no longer the only source of truth.

## GlobalDiarizationSettings

Global defaults only. They never receive one-time or Live-session writes.

| Field | Values / meaning |
|---|---|
| finalEnabledByDefault | Bool; default Final/recovery/future Re-transcribe intent |
| finalProfileID | automatic, offlineQuality, stableFourSpeaker |
| liveEnabledByDefault | Bool; initial state for a new Live preview |

Normal settings do not expose tensor shapes, thresholds, FIFO/cache length, precision, or compute
units. Those values are part of an immutable profile revision.

## MeetingDiarizationPreference

Persistent meeting-scoped policy.

| Field | Meaning |
|---|---|
| meetingID | owning meeting |
| finalPolicy | followSettings, enabled, disabled |
| preferredProfileID | optional meeting profile override; nil follows Settings |
| updatedAt | audit/sync ordering |

The active recording/finalization manifest separately captures the resolved global value/profile so
recovery is deterministic. A later Re-transcribe with Follow Settings resolves current Settings.
Live state never writes this entity.

## MeetingDiarizationRunOptions

Immutable request input, not AppConfig.

| Field | Values / meaning |
|---|---|
| mode | meetingDefault, reuseCompatible, rerun(profileID), disabled |
| requestedBy | automaticFinal, recovery, reTranscribe, reDiarize |
| resolvedEnabled/profileRevision | exact result captured before work starts |
| fallbackBehavior | Final optional fallback or standalone atomic failure behavior |

One-time run options are stored in run provenance but are never copied to global or meeting
preferences.

## LiveDiarizationRuntimeState

Session-only state independent of `MeetingLiveRuntimeState` (Live ASR).

| Field | Meaning |
|---|---|
| enabled | current user override initialized from the global Live default |
| phase | off, loading, running, suspended, stopping, failed |
| epoch | increments for each new on transition |
| profileRevision | exact provisional engine profile |
| message | non-sensitive status/error |

This entity is not Final evidence and is not synced. Crash checkpoints persist only source roles.

## DiarizationProfile

A versioned app-owned mapping from user intent to one exact engine configuration.

| Field | Meaning |
|---|---|
| id | automatic, offlineQuality, stableFourSpeaker, internal legacy/live profiles |
| revision | increments when effective selection or parameters change |
| capability | final/live, hard speaker limit, overlap support, latency class |
| engineID/version | offline-community, sortformer-streaming, ls-eend, or legacy |
| modelAssetID/revision/digest | exact compatible CoreML asset |
| effectiveConfig | immutable values including static tensor shapes |
| license | display name and notice URL |

### Invariants

- One profile revision resolves to one engine and one valid model/config pair.
- Profile revisions are immutable once referenced by completed work.
- Automatic maps to one benchmark-approved profile revision, never an ensemble.
- Sortformer profiles declare a hard maximum of four remote speakers.

## MeetingSystemTimelineMap

Maps retained recording units into one disposable diarization coordinate space.

| Field | Meaning |
|---|---|
| schemaVersion/renderVersion | mapping and prepared-system semantics |
| totalDuration | logical system duration |
| entries | ordered reversible unit mappings |
| sourceFingerprints | ordered canonical system evidence |
| digest | deterministic correctness fingerprint |

### TimelineMapEntry

| Field | Meaning |
|---|---|
| recording/session ID | stable unit identity |
| sourceFingerprint | canonical system source/manifest fingerprint |
| unitStart/unitEnd | valid unit-local range |
| globalStart/globalEnd | corresponding logical range |
| boundaryKind | continuous, pause/resume, recovered unit, explicit gap |

Microphone sources never appear in this map. Gaps remain explicit; later audio is never shifted
across a retained pause or recovered boundary.

## MeetingTranscriptRevision

Durable provider-neutral ASR evidence for one successful recognition run.

| Field | Meaning |
|---|---|
| revisionID / meetingID / runID | immutable identity and owner |
| schemaVersion / createdAt | decoder and audit information |
| sourceTimelineDigest | source/timeline identity used by ASR |
| backend/model/provenance | exact local or Homan Whisper ASR run |
| spans | ordered `TimestampedASRSpan` values |
| status | staged or complete; only complete is selectable |
| contentDigest | integrity and summary/projection identity |

### TimestampedASRSpan

| Field | Meaning |
|---|---|
| id | stable within the transcript revision; Homan item/inner IDs retained |
| source | microphone, system, legacyMixed |
| global start/end | normalized meeting-global bounds when available |
| unit identity/local bounds | reversible provenance |
| text/confidence | recognized text and optional ASR score |
| precision | word, modelSegment, vadItem, none |

Microphone spans always project to You. System spans can project only to remote labels/Others.
Imported `legacyMixed` spans project to anonymous Speaker N or generic Speaker and never to You.

## MeetingDiarizationRevision

Durable engine-neutral acoustic activity for one system timeline.

| Field | Meaning |
|---|---|
| revisionID / meetingID / runID | immutable identity and owner |
| schemaVersion / createdAt / completedAt | lifecycle information |
| timelineMapDigest/sourceFingerprints | exact input identity |
| profile run snapshot | engine/model/config/license provenance |
| activitySegments | overlapping timed speaker activity with opaque speaker keys |
| detectedSpeakerCount/audioDuration | validated result bounds |
| timings/warnings | model load, inference, postprocess and categorized diagnostics |
| artifactDigest/status | integrity; only complete is reusable |

Raw audio and transcript words are absent. Overlap is retained. ASR identity is deliberately absent
from its reuse key.

## MeetingAttributionRevision

The deterministic join of one transcript revision with zero or one diarization revision.

| Field | Meaning |
|---|---|
| revisionID / meetingID | immutable identity and owner |
| transcriptRevisionID | exact recognized words |
| diarizationRevisionID | nil for collapsed/no-analysis attribution |
| algorithmID/revision | versioned alignment and quality rules |
| assignments | span-to-speaker evidence, not only rendered labels |
| speakerLabelMap | opaque keys to deterministic meeting labels |
| quality | precision coverage, ambiguous coverage, publication reason |
| separatedEligible | whether Automatic may show separated labels |
| contentDigest | identity for projections and summary provenance |

### SpanSpeakerAssignment

| Field | Meaning |
|---|---|
| asrSpanID | source text evidence |
| speakerKey/displayLabel | optional remote acoustic key / Speaker N |
| kind | exactOverlap, dominantCoarse, nearestBounded, ambiguous, generic |
| overlap/coverage | measurable attribution evidence |

One text span is never duplicated across overlapping speakers. Ambiguous/untimed system spans stay
Others. No assignment can make system You or microphone remote.

## MeetingTranscriptPresentation

One active selection plus retained alternatives for a transcript revision.

| Field | Meaning |
|---|---|
| meetingID / transcriptRevisionID | owner and evidence revision |
| activeMode | separated, collapsed, manual, legacyRendered |
| activeAttributionRevisionID | optional generated role join |
| manualText / manualCreatedAt | separate user-edited presentation, if any |
| renderedSeparatedDigest/renderedCollapsedDigest | deterministic cache identities |
| activeTextDigest / updatedAt | summary staleness and sync |

Generated text may be rendered on demand or cached, but `meetings.raw_transcript` is transactionally
updated to the active text. Switching modes never deletes Manual or modifies ASR evidence.

## MeetingSummaryInputDescriptor

Extends summary processing metadata.

| Field | Meaning |
|---|---|
| transcriptRevisionID | exact source revision, optional for legacy text |
| attributionRevisionID | exact role join, if any |
| presentationMode | separated, collapsed, manual, legacyRendered |
| transcriptDigest | exact rendered input digest |
| ownerName | configured identity used for You at generation time |
| speakerLegendVersion | semantic prompt contract revision |

Notes are current only when this descriptor matches the active presentation digest. Changing views
marks notes stale without invoking an LLM.

## MeetingProcessingRunPlan

Replaces static operation-wide phase arrays.

| Field | Meaning |
|---|---|
| runID / meetingID / operation | finalization, recovery, retranscription, rediarization, resummarization |
| phases | persisted effective ordered phase identifiers |
| phaseIndex/subprogress | unified list/detail/recovery progress |
| resolved options | ASR/dia/summary snapshots |
| startedAt/updatedAt | timing and crash recovery |

Off, reuse, and rerun plans have different truthful phase lists. Unknown new phases are displayed as
generic processing by older compatible readers rather than blocking startup.

## DiarizationModelAsset

| Field | Meaning |
|---|---|
| assetID/revision/localPath | stable app-owned install identity |
| digest/size | integrity and UI disk usage |
| compatibleProfileRevisions | prevents model/config mismatch |
| installedState | absent, downloading, validating, ready, failed |
| licenseName/URL | required attribution |
| lease/lastErrorCategory | safe removal and non-sensitive diagnostics |

Meeting processing never implicitly changes installed state while recording.

## Retention and deletion ownership

| Event | Audio | Disposable renders | ASR/dia/attribution/presentations | Summary/manual meeting notes |
|---|---|---|---|---|
| audio expiry/manual audio delete | delete | delete | keep | keep |
| transcript retention expiry | current policy | delete | delete with materialized transcript | keep |
| meeting delete | delete | delete | cascade delete | cascade/delete by existing policy |

Text backup and CloudKit use an optional versioned evidence bundle. Old records keep only the active
materialized transcript and become `legacyRendered`; they remain readable but cannot claim local
restore/Re-diarize capabilities without evidence/audio.
