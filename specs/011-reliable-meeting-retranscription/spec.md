# Feature Specification: Reliable Meeting Re-transcription

**Feature Branch**: `experiment/homan-0.8.3-retranscription-aec`
**Created**: 2026-08-22
**Status**: Complete
**Input**: Re-transcribe Homan-recorded meetings from their retained pre-AEC microphone and system
sources so the currently selected echo canceller actually runs again. Preserve the compact
channel-separated playback file as a safe fallback. Do not change capture, dictation, playback, or
the retained audio formats.

## Scope

This feature repairs source selection for recordings that contain both:

- a schema-version-2 source bundle with retained pre-AEC microphone/system epochs; and
- a channel-separated playback recording identified by `source_layout`.

Homan currently selects the playback file first, bypassing the source-bundle branch that re-runs
AEC. The feature repairs re-transcription resolution and makes progress/provenance truthful in both
re-transcription and the existing normal post-call path. It does not redesign the raw meeting-audio
pipeline or change the audio algorithm used by normal finalization.

## User Scenarios & Testing

### User Story 1 - Re-run echo cancellation from retained sources (Priority: P1)

As a user who is dissatisfied with echo duplication in a completed meeting, I want Re-transcribe
to start from the retained pre-AEC microphone and system sources and apply my currently selected
AEC model before ASR.

**Why this priority**: This is the purpose of retaining the source bundle. Selecting the lossy
playback file first makes the storage cost useless for the most important recovery workflow.

**Independent Test**: Create one production-shaped recording row containing both a complete raw
source bundle and `stereo_mic_left_system_right`; resolve it after reopening the database and verify
that the pipeline selects the bundle and invokes the injected AEC processor.

**Acceptance Scenarios**:

1. **Given** a complete supported schema-2 source bundle and a separated playback file, **When**
   Re-transcribe resolves the recording, **Then** it selects the source bundle.
2. **Given** that source bundle, **When** the pipeline prepares audio, **Then** it renders aligned
   microphone/system views and invokes the selected AEC before ASR.
3. **Given** any local or Homan Whisper meeting ASR backend, **When** it prepares a raw source
   bundle, **Then** both backend paths consume the post-AEC microphone view and the independent
   system view.

---

### User Story 2 - Fall back without losing a recording (Priority: P1)

As a user, I want Re-transcribe to keep working from the saved playback recording when the retained
source bundle cannot be trusted.

**Why this priority**: Preferring raw sources must not turn a recoverable source-bundle problem into
a failed re-transcription.

**Independent Test**: Resolve production-shaped units with a missing manifest, unsupported schema,
invalid payloads, and a degraded bundle while a valid separated playback file exists. Verify that
the separated file is selected and its roles are retained.

**Acceptance Scenarios**:

1. **Given** a missing, malformed, unsupported, or fully invalid source bundle and a usable
   channel-separated playback file, **When** Re-transcribe starts, **Then** it uses the separated
   playback file.
2. **Given** a degraded source bundle and a usable separated playback file, **When** the recording
   resolves, **Then** it uses the complete playback file rather than silently accepting gaps.
3. **Given** a degraded source bundle but no usable playback file, **When** at least one canonical
   source remains usable, **Then** Homan uses the degraded bundle rather than discarding all audio.
4. **Given** neither usable canonical sources nor a usable playback file, **When** Re-transcribe
   starts, **Then** the existing recording-unavailable behavior remains unchanged.

---

### User Story 3 - Know which path actually ran (Priority: P2)

As a user or maintainer diagnosing poor results, I want the completed processing metadata and local
diagnostics to distinguish raw-source/AEC processing from playback fallback.

**Why this priority**: The previous defect was difficult to see because configuration showed an AEC
model even when the selected source path could never invoke it.

**Independent Test**: Run metadata construction for raw, separated, and legacy inputs and verify
that the stored source kind is exact, the requested AEC model is stored only when raw pre-AEC input
is used, and old metadata without the new optional fields still decodes.

**Acceptance Scenarios**:

1. **Given** a raw schema-2 source run, **When** processing completes, **Then** transcription
   metadata identifies `raw_source_bundle` and the requested AEC model.
2. **Given** a separated playback or legacy run, **When** processing completes, **Then** metadata
   identifies that source and does not claim AEC was applied.
3. **Given** AEC preload or processing, **When** the post-processing pass runs, **Then** local
   diagnostics state the active processor and whether it was ready; a pass-through cannot be
   mistaken for successful requested-model execution.
4. **Given** metadata produced by Homan 0.8.3 or older, **When** the updated app decodes it, **Then**
   absent provenance fields resolve to `nil` without migration.

---

### User Story 4 - Preserve unrelated workflows (Priority: P1)

As a user, I want this repair to leave live recording, dictation latency, playback, imported files,
and existing retention behavior unchanged.

**Independent Test**: Run the focused re-transcription, compatibility, storage-isolation, and
processing-metadata suites. Review the source diff to confirm there are no capture, Core Audio,
hotkey, playback encoding, retention, or import conversion changes.

**Acceptance Scenarios**:

1. **Given** an imported mono file, **When** it is re-transcribed, **Then** it remains a legacy mixed
   source and never fabricates mic/system separation or AEC.
2. **Given** a playback-only two-channel meeting, **When** it is re-transcribed, **Then** its left
   and right roles remain `You` and `Others`.
3. **Given** normal dictation or live meeting capture, **When** this feature is installed, **Then**
   capture/device/dictation audio behavior and latency remain unchanged; only post-capture progress
   and provenance may differ.

---

### User Story 5 - See audio processing before transcription (Priority: P1)

As a user diagnosing echo duplication, I want both Re-transcribe and normal post-call finalization
to show audio processing as its own phase and to retain evidence of the processor that actually ran.

**Why this priority**: Reporting `Transcribing` while AEC is still running hides where time is spent,
and storing only the configured model cannot distinguish LocalVQE success, DTLN fallback, processing
errors, or complete pass-through.

**Independent Test**: Run schema-2 raw audio through an injected AEC and verify ordered
`processingAudio` then `transcribing` events plus persisted processor/readiness/frame evidence. Verify
the normal finalization plan contains the same phase before transcription and its metadata identifies
the raw-source post-AEC pass.

**Acceptance Scenarios**:

1. **Given** normal post-call finalization, **When** raw microphone/system audio is rendered through
   AEC, **Then** progress shows `Processing audio` before `Transcribing`.
2. **Given** Re-transcribe from a schema-2 raw bundle, **When** AEC preparation runs, **Then** progress
   shows `Processing audio` before `Transcribing` instead of counting AEC time as ASR time.
3. **Given** a completed raw-source run, **When** processing metadata is displayed, **Then** it shows
   the actual processor only when it was ready, processed frames with a system reference, and had no
   processing error.
4. **Given** unavailable AEC, zero processed frames, no system reference, or a processing error,
   **When** metadata is displayed, **Then** the UI says unavailable, not applied, no reference, or
   degraded rather than claiming success.
5. **Given** old processing metadata, **When** the updated app reads it, **Then** missing AEC evidence
   remains valid and no migration is required.
6. **Given** microphone-only raw audio or a multi-session run where only some sessions applied AEC,
   **When** metadata is displayed, **Then** synthetic silence is not counted as system reference and
   the run is shown as no-reference or partially applied rather than successful.

## Edge Cases

- A database source-state value is stale but the on-disk bundle validates differently.
- A complete bundle becomes degraded between database registration and re-transcription.
- The playback file exists but is a directory or cannot be decoded.
- A raw bundle contains only one valid role after validation.
- A meeting contains multiple recording units from resumed sessions with different available
  source kinds.
- Schema version 1 contains already-derived role-separated WAV sources and must not run raw AEC.
- The requested LocalVQE model fails to load and the existing DTLN fallback or raw pass-through is
  used.
- Retention is attempting deletion while re-transcription holds a read lease.
- Retention or manual deletion starts after the database rows are read but while source-bundle
  validation, diarization resolution, or ASR-model preload is still suspended.
- A multi-session meeting cannot acquire every source lease because one recording is already being
  deleted; the operation must not leave partial readers behind.

## Requirements

### Functional Requirements

- **FR-001**: The resolver MUST evaluate a registered supported source bundle before accepting a
  recording's `source_layout` playback path.
- **FR-002**: A complete on-disk source bundle MUST be preferred over every playback representation.
- **FR-003**: A schema-2 raw source bundle MUST be rendered through the existing selected-AEC path
  before ASR for both generic and Homan Whisper meeting processing.
- **FR-004**: Schema-1 derived source bundles MUST remain source-aware and MUST NOT be treated as
  pre-AEC raw input.
- **FR-005**: A missing, malformed, unsupported, invalid, or degraded source bundle MUST fall back
  to a usable separated playback file when one exists.
- **FR-006**: A degraded bundle with usable canonical audio MAY be used when no usable
  role-separated playback fallback exists, and MUST win over legacy mixed playback so known source
  identity is not discarded.
- **FR-007**: A playback fallback with `source_layout` MUST preserve microphone/system roles.
- **FR-008**: A playback fallback without `source_layout` MUST remain legacy mixed and MUST NOT
  fabricate `You` attribution.
- **FR-009**: Existing audio payloads, manifests, playback files, database recording rows, and
  retention dates MUST NOT be rewritten by source resolution.
- **FR-010**: Transcription metadata MUST optionally record the resolved audio-source kind.
- **FR-011**: Transcription metadata MUST record the requested AEC model only for a run that
  actually selects pre-AEC raw input.
- **FR-012**: Runtime diagnostics MUST expose the active AEC processor/readiness for post-capture
  raw processing.
- **FR-013**: Metadata written before this feature MUST decode without migration.
- **FR-014**: Audio behavior for imported files, playback, live capture, dictation, Core Audio
  lifecycle, audio formats, and retention policy MUST remain unchanged; metadata-only provenance at
  existing final/import call sites is allowed.
- **FR-015**: Potentially long source-bundle validation MUST NOT execute on `MainActor` during
  Re-transcribe.
- **FR-016**: Tests MUST use injected temporary support directories and MUST NOT read or mutate the
  installed Homan profile.
- **FR-017**: Normal finalization and Re-transcribe MUST expose a distinct `processing_audio` phase
  before `transcribing` whenever their audio-preparation step runs.
- **FR-018**: Completed raw-source transcription metadata MUST persist bounded actual AEC evidence:
  processor name, readiness, processed frames, full/partial/missing reference-frame counts, and the
  presence of a processing error using a non-sensitive stable category.
- **FR-019**: Normal post-call finalization MUST identify its actual input as `raw_source_bundle`
  because it derives transcription audio from the just-finalized pre-AEC capture.
- **FR-020**: The UI MUST NOT label a requested AEC model as successfully applied when the processor
  was unavailable, processed zero frames, had no system reference, or reported a processing error.
- **FR-021**: Generic multi-unit re-transcription MUST finish audio preparation/AEC for every
  canonical unit before advancing the run to `transcribing`; legacy ASR MUST also advance to
  `transcribing` before inference begins.
- **FR-022**: AEC aggregation MUST retain total and successfully-applied source-unit counts so one
  successful session cannot hide another zero-frame, no-reference, unavailable, or errored session.
- **FR-023**: Missing system capture MUST remain missing reference evidence; post-processing MUST NOT
  feed synthetic zero samples as if they were captured system reference.
- **FR-024**: Re-transcription MUST acquire one atomic read-lease set for every persisted recording
  unit before source-bundle validation starts and MUST retain it through diarization resolution,
  model preload, audio preparation, ASR, and any speaker analysis performed by the audio pipeline.
  It MUST release the set promptly once the pipeline returns because evidence construction,
  summarization, and result commit no longer read retained audio.
- **FR-025**: If any recording in that set is already being deleted, lease acquisition MUST fail as
  one operation, MUST leave no partial read state, and Re-transcription MUST preserve the existing
  meeting result under its recording-unavailable policy.
- **FR-026**: Re-transcription cancellation MUST be observed between multi-unit preparation steps
  on both generic and Homan Whisper paths; temporary audio and nested read leases MUST still be
  released on cancellation.

### Key Entities

- **Recording unit**: One retained meeting session linking a playback recording and optionally a
  canonical source bundle.
- **Canonical source bundle**: Validated schema-1 derived sources or schema-2 pre-AEC epochs.
- **Playback fallback**: A channel-separated or legacy recording used only when canonical sources
  are unavailable or less complete.
- **Transcription provenance**: Optional processing metadata describing the resolved input kind and
  requested AEC model.

## Success Criteria

### Measurable Outcomes

- **SC-001**: 100% of production-shaped complete schema-2 fixtures with both metadata forms resolve
  to the source-bundle path.
- **SC-002**: The raw fixture's injected AEC processor receives at least one frame with non-zero
  system reference before ASR.
- **SC-003**: 100% of tested missing, malformed, unsupported, invalid, and degraded bundle cases
  retain successful separated-playback fallback when that file is usable.
- **SC-004**: All existing re-transcription, compatibility, raw-pipeline, retention, and test-storage
  isolation tests pass serially.
- **SC-005**: Existing metadata fixtures without provenance fields decode unchanged.
- **SC-006**: The final application source diff contains no capture-device, hotkey/dictation,
  playback writer, import converter, or audio-retention behavior change.
- **SC-007**: Focused progress, pipeline, metadata, and metadata-display tests pass for both normal
  and re-transcription semantics, including fallback/degraded outcomes.
- **SC-008**: A read-lease-set test proves that deletion of every protected recording remains
  deferred across an async suspension and succeeds after release.
- **SC-009**: A failed atomic multi-recording lease acquisition leaves otherwise available
  recordings immediately deletable.

## Assumptions

- Source bundles and playback files remain under Homan-managed Application Support storage.
- The existing bundle loader remains the authority for path, schema, digest, frame, channel, and
  sample-rate validation.
- AEC quality/model selection itself is outside scope; this feature guarantees execution of the
  configured path, not a particular acoustic score.
- The owner has accepted the current LocalVQE v1.2 result for the channel-separated microphone and
  system workflow on real meeting audio. This is the accepted merge baseline and MUST NOT be tuned
  as part of merge hardening.
- Additional speaker diarization quality has not been accepted on real meeting audio. Its presence
  and compatibility may merge, but this feature does not claim an acoustic-quality result for it.
- Storage optimization of 48-kHz stereo system sources is a separate future experiment.
