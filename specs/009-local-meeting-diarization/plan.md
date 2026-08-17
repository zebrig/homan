# Implementation Plan: Local Meeting Diarization

**Status**: Core implementation complete; real-audio quality/resource benchmarks and default
rollout approval remain open

**Specification**: [spec.md](spec.md)

## Summary

Refactor meeting diarization from a concrete helper hidden inside `TranscriptionCoordinator` into
an ASR-independent, run-scoped local stage. Build one logical system timeline across all retained
source-aware units, persist provider-neutral ASR evidence and one selected local diarization
revision, then derive reversible Separated/Others/Manual transcript presentations. Preserve
microphone=`You`, keep Final authoritative, support an independent provisional Live toggle, keep
failure optional, and reuse matching artifacts across ASR-only retries and standalone Re-diarize.

The rollout has two gates before behavior changes: upgrade FluidAudio from exact 0.15.1 to a tested
exact release containing cancellation/config validation/offline fixes, then benchmark the actual
Community-1 and Sortformer assets on Homan-like RU/PL/EN recordings. Automatic ships as one
versioned profile only after that comparison.

## Technical Context

**Language/Version**: Swift 5.9

**Primary Dependencies**: SwiftUI, AppKit, AVFoundation, CoreAudio, FluidAudio, existing raw-audio
renderer/AEC, existing local and remote ASR adapters

**Storage**: SQLite for transcript/diarization/attribution revisions, presentation state, summary
input provenance, and processing plans; disposable rendered audio remains file-backed; canonical
audio remains unchanged; optional additive backup/CloudKit evidence asset

**Testing**: Swift Testing/SwiftPM, deterministic audio/timeline fixtures, a separately versioned
quality corpus with reference RTTM/turn annotations, performance runs on supported Apple Silicon

**Target Platform**: macOS 14.2+, Apple Silicon

**Performance Goals**: bounded memory for multi-hour meetings; cancellable work; no capture loss;
remote-ASR/local-diarization overlap where safe; no duplicate diarizer run for ASR-only retry

**Constraints**: exact dependency/model pinning, offline-first, no new telemetry, no server-side
diarization, Sortformer maximum four speakers, backward-compatible remote response, no legacy media
migration, microphone never diarized, Live labels provisional and independent from Final

## Constitution Check

### Pre-design gate

- **Local privacy**: PASS. Diarization remains on Mac; server receives no additional audio beyond
  explicitly selected remote ASR.
- **Canonical audio integrity**: PASS. Only disposable system views and small metadata artifacts are
  added; raw sources remain immutable.
- **One meeting pipeline**: PASS. All ASR providers feed one attribution/reconciliation path.
- **Backward-compatible durable state**: PASS with implementation requirement. `raw_transcript`
  remains the active materialized snapshot; new revisions and optional server/sync fields are
  additive; old responses, backups, and recordings remain valid.
- **Recoverable failure**: PASS. Artifact commit is atomic and diarization is optional.
- **Predictable performance**: PASS only after dependency upgrade, cancellation tests, and resource
  benchmarks; these are hard rollout gates.

## Proposed Project Structure

```text
native/MuesliNative/
├── Sources/MuesliNativeApp/
│   ├── MeetingDiarizationProvider.swift
│   ├── MeetingDiarizationProfiles.swift
│   ├── MeetingDiarizationArtifact.swift
│   ├── MeetingDiarizationArtifactStore.swift
│   ├── MeetingSystemTimeline.swift
│   ├── MeetingSpeakerAttributor.swift
│   ├── MeetingTranscriptRevision.swift
│   ├── MeetingTranscriptPresentation.swift
│   ├── MeetingSummaryInputDescriptor.swift
│   ├── MeetingLiveDiarizationSession.swift
│   ├── MeetingInferenceScheduler.swift
│   ├── TranscriptionRuntime.swift
│   ├── MeetingTranscriptionPipeline.swift
│   ├── TranscriptFormatter.swift
│   ├── HomanWhisperBatchClient.swift
│   ├── Models.swift
│   └── SettingsView.swift
├── Sources/MuesliCore/
│   ├── MeetingProcessingProgress.swift
│   └── DictationStore.swift
└── Tests/MuesliTests/
    ├── MeetingDiarizationProfileTests.swift
    ├── MeetingDiarizationArtifactTests.swift
    ├── MeetingSystemTimelineTests.swift
    ├── MeetingSpeakerAttributorTests.swift
    ├── MeetingDiarizationSchedulingTests.swift
    ├── MeetingTranscriptionPipelineTests.swift
    ├── HomanNativeBatchEndpointTests.swift
    ├── MeetingProcessingProgressTests.swift
    └── MeetingDiarizationQualityHarnessTests.swift
```

## Design

### 1. Provider boundary

Introduce one actor-safe provider protocol whose output is independent of FluidAudio types:

```swift
protocol LocalMeetingDiarizationProviding: Sendable {
    var descriptor: DiarizationEngineDescriptor { get }
    func prepare(progress: @Sendable (ModelPreparationProgress) -> Void) async throws
    func diarize(
        timeline: MeetingSystemTimelineInput,
        progress: @Sendable (DiarizationProgress) -> Void
    ) async throws -> DiarizationTimelineResult
    func unload() async
}
```

Adapters:

- `OfflineCommunityDiarizationProvider` wraps `OfflineDiarizerManager.process(fileURL)`;
- `SortformerDiarizationProvider` wraps one validated config/model pair and processes the logical
  meeting as one continuous stateful stream;
- `LegacyDiarizationProvider` wraps `DiarizerManager` only for fallback/rollback.

No ASR provider owns or selects this provider.

### 2. Profile resolution

Persist user intent, then resolve it once per processing run:

```text
Off                       -> no provider
Automatic + Auto/<=4/>4   -> one benchmark-approved offline profile
Offline quality           -> Community-1/VBx profile
Stable up to 4            -> Sortformer balancedV2_1 profile
```

Automatic does not inspect preliminary model output and does not run an ensemble. Profile IDs and
revisions are stable; their internal parameters may change only by adding a new revision.

`highContextV2_1` is represented only in internal experiments/diagnostics until it passes a
Homan-specific quality and resource gate. It is not the meaning of "Offline quality".

### 3. Logical system timeline

Before ASR/diarization, build a lightweight map over every source-aware recording unit:

- deterministic chronological unit order;
- meeting-global start/end offsets;
- original unit-local offsets;
- explicit silence for retained gaps and boundaries;
- prepared system source fingerprint, including raw source digest and preparation version.

The renderer writes one disposable system-only file suitable for the chosen provider without
changing canonical media. Community-1 uses the disk-backed file API. Sortformer is fed sequentially
from the same logical view so its cache is not reset per unit.

### 4. Structured evidence and processing graph

```text
validate/lease raw units
        |
render prepared mic + logical system timeline
        |
        +--------------------+
        |                    |
ASR mic/system          local diarization (when effective)
        |                    |
        +------ join --------+
                |
persist transcript + diarization revisions
                |
timestamp normalization + speaker attribution revision
                |
active presentation -> title/summary -> atomic database commit
```

The first implementation runs heavy inference sequentially so the existing linear progress and
resource guarantees remain truthful. Remote ASR/local diarization concurrency is a measured later
optimization under the same parent run, not a second workflow. A new recording can coexist with
remote work, while local post inference yields to capture and Live.

`TimestampedASRSpan` is durable text evidence. `DiarizationArtifact` is durable acoustic activity.
`AttributionRevision` joins them. None is replaced by a formatted string.

`AudioFileImportController` must feed the same graph instead of keeping its direct legacy-diarizer
branch. Its single mixed source is diarized as anonymous speakers with no authoritative You role.

### 5. Revision and artifact lifecycle

Compute the artifact key before model execution from:

- ordered canonical system source digests and timeline map digest;
- AEC/preparation pipeline version affecting the system view (normally raw-system render version);
- provider ID and model asset revision/digest;
- Homan profile revision and complete effective config;
- artifact schema version.

Read a matching complete revision if present. Otherwise stage it under the processing run, validate
segments and bounds, and commit the transcript/diarization/attribution revisions and active
presentation in one SQLite transaction. File-backed disposable renders are closed before the
transaction. Never reuse `.running`, `.failed`, partial, unknown-schema, or fingerprint-mismatched
data.

Audio expiry does not delete these text/metadata revisions. Transcript-retention cleanup does.
Meeting deletion cascades all revisions. This preserves collapse/restore after the default audio
retention period without retaining audio longer than requested.

### 6. Timestamp-aware attribution

Normalize every ASR result to meeting-global timed spans with a precision class:

- token/word;
- inner model segment;
- VAD item only;
- untimed.

Split text at diarization boundaries only when timestamps support the split. For a coarse span,
choose a speaker only if one has sufficiently dominant overlap; otherwise leave it `Others`.
Overlapping diarization activity remains in the artifact. The first implementation must not
duplicate one ASR text span into two speakers.

Homan Whisper response v1 remains valid and gains optional per-item `segments` with relative or
absolute bounds defined unambiguously in the endpoint contract. The client validates containment,
finite values, ordering, IDs, and source role before accepting them.

Publication is conservative. A usable acoustic artifact may remain stored while the active
presentation is Others when ASR timestamps are coarse, only one remote speaker has useful text, or
ambiguity exceeds a versioned gate.

### 7. Settings and override resolution

There are three scopes and they never write through one another:

1. global Final On/Off + Final quality profile + Live-by-default On/Off;
2. persistent meeting Final policy: Follow Settings / On / Off;
3. one active Live boolean and one-time Re-transcribe/Re-diarize run options.

The recording manifest snapshots the resolved global Final default for deterministic original
Final/recovery. A later Re-transcribe using Follow Settings resolves the then-current global value.
Every run resolves provider/model/config exactly once. Live never changes Final.

Re-transcribe independently selects ASR and speaker handling: meeting default, reuse compatible,
rerun an installed profile, or Off. Standalone Re-diarize consumes the existing ASR revision and
does not call ASR, title, or summary.

### 8. Reversible presentation and manual edits

One transcript revision can have generated Separated and Others projections. A user edit creates a
separate Manual presentation instead of mutating the ASR evidence. `meetings.raw_transcript` remains
the active materialized snapshot for existing search/export/sync code.

Switching presentations is a small atomic local transaction and performs no inference. Manual text
is never deleted by switching. Re-transcribe archives the prior presentation set and warns before
making a new generated revision active when Manual was active.

Summary metadata stores the exact transcript revision, attribution revision, presentation mode,
and digest used. Changing presentation marks notes stale and offers Re-summarize; it does not
silently call any LLM. The summary payload always carries the owner/remote speaker legend.

### 9. Live contract

Add an independent `MeetingLiveDiarizationRuntimeState` rather than overloading the current Live ASR
phase. It consumes system audio only, never blocks capture callbacks, and emits provisional labels
for display. The global default initializes a session-only switch that remains user-toggleable
while Live is active.

Each on transition creates a provisional epoch. Off stops future labeling; failure falls back to
Others while Live ASR and recording continue. Recovery checkpoints stay You/Others, and Final
ignores every Live epoch. Sortformer balanced and LS-EEND remain candidate Live adapters; the
shipping choice requires separate Live latency/quality benchmarks.

### 10. Progress and cancellation

Replace the operation-wide static phase list with a persisted run-specific plan. Add `.diarizing`,
`.applyingSpeakerLabels`, and operation `.rediarization`. Off/reuse/rerun paths therefore show the
correct phase count instead of fake work. Model download is not part of finalization. Model
load/compile and audio progress are subprogress inside the same state record.

Cancellation rules:

- check before model preparation and each inference chunk;
- never call `cleanup`/`unload` until the processing task has returned;
- discard temp artifact and keep prior complete output;
- persist retryable operation state;
- capture callbacks never wait on diarization locks.

### 11. Resource policy

`MeetingInferenceScheduler` owns permits for model preparation/inference, not audio capture.

Priority order:

1. recording/capture (never gated);
2. Live inference;
3. user-initiated foreground retry;
4. automatic final local ASR/diarization;
5. background recovery/preload.

Start with conservative policies:

- initial release: all heavy ASR/Final-diarization inference is sequential and cancellable;
- later remote ASR + local diarization: concurrent only after the single-run progress UI and
  cancellation tests cover it;
- local ASR + offline Community-1/Sortformer: sequential unless a device benchmark explicitly
  approves overlap;
- starting Live cancels or yields background diarization at its next bounded checkpoint;
- model installation/compilation is forbidden while recording.

### 12. Model management

Upgrade FluidAudio in a dedicated commit, exact pin only. Use an app-specific model directory under
Homan Application Support, explicit Install/Remove actions, digest validation, and license metadata.
Do not rely on whichever model happens to exist in a shared FluidAudio cache.

The settings screen shows profile-level assets. Advanced diagnostics may reveal implementation
model filename, precision, compute units, and static config, but users do not edit shape parameters.

### 13. Compatibility, sync, and rollback

- Existing meetings need no migration.
- Existing transcript text stays valid if no artifact exists.
- Legacy/imported mixed media remains source-unknown; a newly structured import may show anonymous
  Speaker N labels but never You/known-remote claims.
- Old Homan Whisper response is accepted with coarse attribution.
- Old text backups and CloudKit records remain readable. A new optional versioned evidence payload
  carries source spans, diarization, attribution, presentation, and manual text. Without it, the
  receiving Mac shows the active transcript but does not claim reversible controls.
- Old builds continue reading the active `raw_transcript` materialization.
- A feature flag permits rollback to the current legacy provider during staged rollout.
- Unknown artifact schema is ignored, never deleted as corrupt audio.
- A downgrade must ignore unknown progress/artifact rows rather than blocking app startup.

## Benchmark and acceptance gate

Create an opt-in local corpus with consented/de-identified reference annotations covering:

- RU, PL, EN and language switching;
- 1, 2, 3, 4, and 5+ remote speakers;
- near/far voices, quiet speech, noise, music/presentations, and overlap;
- multiple recording units and device switches;
- exact Homan raw-system render and real Homan Whisper/local-ASR timestamp shapes.

Compare exact shipping configurations:

1. current legacy `DiarizerManager`;
2. Offline Community-1 default and one validated meeting profile;
3. Sortformer `balancedV2_1` fp16;
4. Sortformer `highContextV2_1` only as research;
5. LS-EEND only as future-Live reference.

Metrics: DER, JER, missed speech, false alarm, speaker confusion, speaker-count error, attribution
accuracy after ASR alignment, processing time, peak RSS, CPU/ANE utilization, cancellation latency,
model load time, and disk size. Results and corpus revision are checked into the spec, not inferred
from one anecdotal call.

Automatic ships only if it improves median speaker confusion and overall DER over current Homan
without violating the missed-speech, capture-start, cancellation, or memory gates agreed after the
baseline run.

## Commit and rollout sequence

1. Spec/benchmark harness only; no behavior change.
2. Durable transcript/diarization/attribution revisions, reversible presentations, manual-edit
   preservation, retention/sync/backup contracts; still no model behavior change.
3. Exact FluidAudio upgrade plus full existing ASR/VAD/AEC regression suite.
4. Engine-neutral provider, profiles, and fake-provider contract tests; still disabled.
5. Logical system timeline and atomic artifact store.
6. Timestamp-aware attribution and backward-compatible Homan Whisper inner-segment support.
7. Dynamic unified progress, scheduling, cancellation, Final/recovery/Re-transcribe/Re-diarize.
8. Global/per-meeting/one-time settings and transcript presentation/summary-staleness UI.
9. Benchmark results, Automatic decision, and opt-in Final rollout.
10. Independent provisional Live state/toggle/adapters and Live-specific benchmark gate.
11. Default rollout only after field validation and rollback verification.

Every commit is independently testable and rollback-safe. The provider integration commit must not
also change AEC, raw capture, playback, retention, summary generation, or application branding.

## Complexity Tracking

| Added complexity | Why it is required | Simpler alternative rejected because |
|---|---|---|
| Engine-neutral provider | ASR/backend independence and safe evaluation | Replacing one class preserves Homan Whisper coupling and no provenance |
| Meeting-global timeline | stable labels across units and global clustering | Per-unit runs relabel the same person unpredictably |
| Persistent artifact | ASR-only reuse, audit, retry, and atomic failure | Baking labels into text loses model evidence and repeats work |
| Resource scheduler | protects recording/Live and makes cancellation bounded | Uncoordinated CoreML tasks can contend or unload active models |
| Optional remote inner timestamps | correct speaker-boundary attribution | VAD-item bounds can span multiple speakers |
| Versioned profiles | safe static model/config pairing | Raw knobs allow invalid tensor shapes and irreproducible results |
| Durable transcript/attribution revisions | instant reversible collapse, Re-diarize, manual-edit safety | A single flat string loses both evidence and user changes |
| Run-specific phase plan | honest progress for Off/reuse/rerun and recovery | Static phase arrays show work that did not run |
| Independent Live state | Live toggle cannot mutate Final/ASR policy | One combined state creates impossible transitions and hidden coupling |
