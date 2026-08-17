# Processing Flows and UX: Local Meeting Diarization

> **Planned follow-up**: [Specification 010](../010-diarization-model-selection-onboarding/spec.md)
> replaces the user-facing Automatic/profile-install selection in this document once implemented.
> Final/Live policy scope and all evidence/presentation flows below remain authoritative.

This document is the product/flow contract for speaker separation. It complements the engine
research. The central rule is that ASR text, acoustic speaker activity, attribution, and the text
currently shown to the user are different objects with different lifecycles.

## Non-negotiable source roles

- The canonical microphone source is exactly one local person and is always rendered as `You`.
- The configured app-owner name is the identity of `You` for summary prompting.
- The microphone is never diarized. A diarizer cannot move microphone text to a remote speaker.
- Only canonical system audio is eligible for remote-participant diarization.
- System audio is always remote-side: `Speaker 1`, `Speaker 2`, … when attribution is usable, or
  `Others` when it is disabled, ambiguous, unavailable, or collapsed by the user.
- Numbered speakers are anonymous acoustic streams scoped to one meeting revision. They are not
  names, invitees, biometric identities, or people remembered across meetings.
- Live labels are provisional presentation only. They never become final/recovery evidence.

These rules deliberately use source identity before acoustic inference. Echo removal remains a
separate audio-preparation concern; the diarizer must not be asked to decide which side is `You`.

## Three independent controls

### 1. Global defaults in Settings > Meetings > Speaker separation

Normal settings expose intent, not FluidAudio class names or tensor parameters:

| Setting | Values | Recommended default | Meaning |
|---|---|---|---|
| Final speaker separation | On / Off | On for migrations that previously diarized local Final; On for new installs once the approved asset is available | Default for Final, recovery, and future Re-transcribe runs |
| Final quality profile | Automatic / Offline quality / Stable up to 4 | Automatic | Selects one versioned provider profile; never an ensemble |
| Live speaker separation by default | On / Off | Off | Initial state of a newly started Live preview only |

The existing Live ASR default and Live ASR model remain separate settings. Turning Live speaker
separation on does not start Live ASR and does not select a transcription model.

If an asset is missing, Settings shows Install/Remove and license state. Recording/finalization
never starts a surprise model download. `Automatic` resolves to exactly one benchmark-approved
Final profile revision.

### 2. Per-meeting Final policy

Each source-aware meeting stores:

```text
Follow Settings | On | Off
```

- An active recording snapshots the resolved global default in its recovery/finalization manifest.
- The user may change the meeting override until Final processing is committed.
- Changing this value does not change global Settings.
- Live speaker separation never changes this value.
- After completion, On/Off remains explicit; Follow Settings resolves the current global value for
  a new Re-transcribe run. Recovery of the original Final uses its captured manifest instead.

The recording UI shows a compact `Final speakers: On/Off` menu outside the Live card. This avoids
implying that the Live toggle controls the final transcript.

### 3. Active Live override

The Live card always exposes `Separate remote speakers` when a meeting is recording, regardless of
the global default. It is a session-only boolean initialized from `Live speaker separation by
default`.

- It can be switched on or off while Live ASR is loading, running, lagging, or paused.
- It affects only system-audio labels produced after the state transition.
- Turning it off stops diarizer inference and future system turns become `Others`.
- Turning it on starts a new provisional diarization epoch. The UI shows `Starting` until the model
  has enough context; it does not backfill earlier Live text.
- If the Live diarizer fails, Live ASR continues as `You`/`Others`; Final processing is unaffected.
- Checkpoints used for crash recovery persist source-authoritative `You`/`Others`, never tentative
  Live `Speaker N` labels.
- Stopping/restarting Live ASR and toggling Live diarization are independent operations.

If preserving speaker numbers across an off/on gap cannot be proven, the preview marks that labels
were restarted rather than pretending `Speaker 1` still denotes the same person. Final processing
always starts from raw retained sources and replaces provisional labels.

## Final processing

### Resolved run plan

At Stop, Homan creates one immutable processing snapshot containing:

- source recording/timeline identity;
- selected ASR provider (local or Homan Whisper);
- effective per-meeting diarization policy and exact profile revision;
- summary provider/template;
- resource/cancellation policy.

Settings changes after this point do not mutate the active run. The run uses the existing single
meeting-processing state; diarization does not create a second independent job/status system.

### Final with speaker separation On

```text
lease/validate raw sources
  -> render disposable microphone/system processing views
  -> ASR microphone + system
  -> diarize logical system timeline locally on the Mac
  -> persist ASR and diarization revisions atomically
  -> attribute system text to anonymous remote speakers
  -> choose separated or conservative Others presentation
  -> title + summary from that exact active presentation
  -> save recording/output and finish the same processing run
```

The first implementation executes heavy local ASR and Final diarization sequentially. Homan
Whisper and local diarization may later overlap under the same parent run after progress and
cancellation tests; concurrency is an optimization, not a correctness dependency.

### Final with speaker separation Off

No diarizer asset is loaded. The same ASR evidence is stored, microphone is `You`, system is
`Others`, and title/summary continue normally. The operation does not show a fake Diarizing phase.

### Failure rules

- ASR failure retains existing Final/recovery semantics.
- Diarization missing/failed/cancelled is non-fatal during automatic Final: commit ASR as
  `You`/`Others`, record a visible degradation, and offer `Analyze speakers again`.
- Attribution uncertainty is not a processing failure. Ambiguous spans stay `Others`.
- No partial diarization revision or half-rendered transcript becomes active.
- Starting a new meeting never waits on or shares a model object being unloaded by the prior run.

## Homan Whisper compatibility

Homan Whisper remains ASR-only. It never selects, runs, or returns a diarizer model.

1. Homan builds the same microphone/system VAD batch as today.
2. The remote endpoint returns text and timestamps.
3. Homan runs local diarization over the retained system timeline according to the meeting policy.
4. Both products are joined locally through provider-neutral time spans.

The existing response, whose timestamps are only the outer VAD-item bounds, remains accepted. A
backward-compatible optional `segments` array supplies inner Whisper segment bounds. Without inner
segments, a VAD item receives a numbered speaker only when one remote speaker has clearly dominant
overlap; otherwise it remains `Others`. Homan must prefer honest coarse output over assigning an
entire 30-second item to the wrong person.

Changing between Homan Whisper and a local ASR never invalidates a matching diarization revision.
Changing the source timeline, preparation contract, diarizer profile/model, or attribution
algorithm does invalidate it.

## Imported mixed audio

`AudioFileImportController` currently bypasses the common meeting pipeline, invokes the legacy
diarizer directly, and also skips diarization for Homan Whisper. It must be migrated to the same
evidence/provider/attribution contracts rather than left as a second permanent implementation.

An imported one-track file has different source truth from a recorded call:

- it has `legacyMixed`/`mixedUnknown` evidence, not microphone/system evidence;
- no imported speaker is authoritatively `You`;
- when enabled, the complete imported file may be diarized into anonymous `Speaker N` labels;
- when disabled/ambiguous/collapsed, use generic `Speaker` (source unknown), not `Others` (known
  remote side) and not `You`;
- Homan Whisper remains ASR-only and local Mac diarization applies identically;
- Re-transcribe, Re-diarize, presentations, summary provenance, retention, and progress reuse the
  same revision model.

Old imported flat transcripts remain `legacyRendered` and do not gain reversible controls until a
new structured Re-transcribe is completed. Note-only meetings expose no diarization controls.

## Re-transcribe and Re-diarize

### Re-transcribe UI

The existing split button becomes a run-options sheet/menu with two independent choices:

```text
Transcription
  <default or one-time ASR provider>

Remote speakers
  Use meeting setting
  Keep current speaker analysis          (only when compatible)
  Analyze again — <installed profile>
  Off — label remote audio as Others
```

- A one-time ASR or diarizer selection does not modify global Settings.
- `Keep current` is the default when a compatible artifact exists and only ASR changes.
- `Use meeting setting` resolves the meeting's `Follow Settings/On/Off` policy.
- A successful Re-transcribe publishes a new transcript revision atomically.
- If automatic optional diarization fails, the new ASR may still commit as `Others` with a retry
  warning. Existing audio and earlier revisions are not destroyed.
- If a manually edited transcript is active, Homan warns before making the new generated revision
  active; the manual revision remains recoverable.

### Standalone Re-diarize

`Analyze speakers again…` is a separate operation. It reuses the stored ASR revision and never
calls ASR, title generation, or summary unless the user explicitly requests a later re-summary.

```text
prepare retained system audio
  -> diarize
  -> attribute stored ASR spans
  -> atomically publish new speaker/attribution revision
  -> mark existing summary stale
```

- It requires retained source-aware system audio and structured ASR spans.
- If audio has expired, it is disabled with `Original audio is no longer available`.
- Old flat-text-only meetings must be Re-transcribed once before standalone Re-diarize is possible.
- Failure leaves the currently visible transcript and summary unchanged.
- It has its own `.rediarization` operation in the same persisted progress mechanism.

## Instant collapse and restoration

Above the Transcript content, show a compact control:

```text
Remote labels:  Separated | Others
```

- `Others` does not rerun ASR or the diarizer. It projects every system span to `Others` and merges
  only adjacent compatible turns; microphone remains `You`.
- Switching back to `Separated` reuses the committed attribution revision immediately.
- The diarization revision remains cached, so collapse is reversible.
- If only one remote speaker was detected, or timestamp coverage is too coarse, `Others` is the
  conservative automatic presentation even though the acoustic artifact may be retained.
- The control is unavailable for legacy mixed audio where source identity is unknown.

### Manual transcript edits

The existing full-transcript editor makes a single mutable `raw_transcript` unsafe. Saving an edit
therefore creates a `Manual` presentation instead of mutating ASR evidence.

The presentation selector can contain:

```text
Manual | Separated | Others
```

- Switching away from Manual never deletes the user's text.
- Re-diarization regenerates only Separated/Others and never rewrites Manual.
- Search, export, and the detail view use the active presentation.
- `raw_transcript` remains a backward-compatible materialized snapshot of that active presentation.
- A new Re-transcribe creates a new generated revision; an older manual presentation is archived
  with its source revision and can be restored.

## Summary role contract

Summary generation receives a typed input descriptor, not an arbitrary transcript string:

```text
transcript revision ID
attribution revision ID (optional)
active presentation: separated / collapsed / manual
owner name from Settings
rendered transcript digest
speaker legend
```

The rendered summary payload always explains:

- `You` is the single local microphone speaker and, when configured, is `<owner name>`;
- `Speaker N` labels are anonymous remote system-audio speakers scoped to this meeting;
- `Others` is remote speech not separated or deliberately collapsed;
- the model must not invent names from language, content, or a mentioned person's name.

The LLM does not repair diarization. It summarizes the active deterministic projection. If a
speaker says “I will do it” and no identity is stated, the note may attribute it only to that
anonymous label, not to an inferred person.

Every completed summary stores the transcript revision, presentation mode, and input digest used.
Switching Separated/Other/Manual is immediate and marks prior notes `Based on a different transcript
view`; it does not silently spend tokens or overwrite notes. The UI offers `Re-summarize` and that
action always uses the currently active presentation.

## Progress model

The current static phase list cannot correctly represent optional diarization. Introduce a
persisted run-specific phase plan. Examples:

| Operation | Effective phases |
|---|---|
| Final, separation On | Prepare audio -> Transcribe -> Diarize -> Apply speaker labels -> Title -> Summarize -> Encode -> Save |
| Final, separation Off | Prepare audio -> Transcribe -> Title -> Summarize -> Encode -> Save |
| Re-transcribe, reuse artifact | Prepare -> Transcribe -> Apply speaker labels -> Summarize -> Save |
| Re-transcribe, rerun | Prepare -> Transcribe -> Diarize -> Apply speaker labels -> Summarize -> Save |
| Re-diarize | Prepare -> Diarize -> Apply speaker labels -> Save |
| Collapse/restore | atomic local projection update; no background run |

List view, detail view, restart recovery, and `N of M` all read this one record. The current staging
marker that says `diarizing` after the pipeline has already returned is removed as a UI authority.

## Retention, backup, and sync

- Raw audio deletion removes only audio and disposable renders. It does not remove structured ASR,
  diarization activity, projections, or manual text; otherwise role collapse/restore would break as
  soon as the default seven-day audio retention runs.
- Transcript-retention cleanup removes the materialized transcript and its structured ASR,
  diarization, attribution, and manual transcript revisions together. Summary/manual meeting notes
  keep their current retention behavior.
- Meeting deletion cascades all revisions and temporary files.
- Text backup gains an optional versioned transcript-evidence bundle. Old backups remain valid.
- iCloud continues syncing the active materialized transcript for old clients and adds an optional
  versioned evidence asset for full reversible behavior on another Mac. Unknown fields are ignored
  by old builds. Until an evidence asset is present on a receiving Mac, the text remains readable
  but Homan must not pretend local Re-diarize/restore is available.

## Quality publication gate

A diarization revision can exist without being selected as the separated presentation. Automatic
publication considers only measurable evidence quality:

- source is system and timeline mapping is valid;
- ASR timestamp precision/coverage supports attribution;
- at least two remote speakers receive useful, non-ambiguous text coverage;
- ambiguous/untimed spans remain `Others` rather than being forced;
- the profile did not exceed a hard speaker limit.

Raw model confidence is not treated as a calibrated truth score. The UI may say `Speaker analysis
was too uncertain; showing Others` and still allow an explicit preview of separated labels under an
Advanced action.

## Deliberate non-features

- no diarization of microphone audio;
- no automatic speaker naming or cross-meeting voice identity;
- no server-side diarization authority;
- no text-similarity deduplication of speakers;
- no multi-model voting in Automatic;
- no automatic re-summary when the user changes transcript presentation;
- no promise that Live provisional labels match Final labels.
