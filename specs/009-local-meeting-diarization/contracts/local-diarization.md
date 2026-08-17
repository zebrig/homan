# Contract: Local Meeting Diarization

## Source-role contract

1. A source-aware microphone maps to `You` without acoustic inference and represents one local
   app owner.
2. The microphone is never submitted to a diarizer.
3. Diarization receives only a disposable logical system timeline.
4. Every system span remains remote-side: numbered anonymous speaker or `Others`; never `You`.
5. Legacy mixed media is never presented as authoritative source separation.
6. Missing/corrupt system audio cannot invalidate usable microphone transcription.
7. Imported single-track audio may be diarized as anonymous mixed-source speakers, but none is You
   and generic collapse uses `Speaker`, not known-remote `Others`.

## Policy resolution contract

```swift
enum MeetingFinalDiarizationPolicy: String, Codable, Sendable {
    case followSettings
    case enabled
    case disabled
}

enum MeetingDiarizationRunMode: Sendable {
    case meetingDefault
    case reuseCompatible
    case rerun(MeetingDiarizationProfileID)
    case disabled
}
```

Resolution order for Final/recovery/future default Re-transcribe:

1. explicit one-time run mode, if present;
2. persistent meeting On/Off override;
3. for original Final/recovery, the global value captured in the recording manifest; for a later
   Re-transcribe with Follow Settings, current global Settings;
4. safe disabled fallback if the value is unknown.

The exact result/profile/config is copied into an immutable run snapshot. No run or Live action may
write AppConfig or the persistent meeting policy implicitly.

## Profile contract

```swift
enum MeetingDiarizationProfileID: String, Codable, Sendable {
    case automatic
    case offlineQuality
    case stableFourSpeaker
}

struct MeetingDiarizationRunSnapshot: Codable, Sendable {
    let profileID: MeetingDiarizationProfileID
    let profileRevision: Int
    let engineID: String
    let engineVersion: String
    let modelRevision: String
    let modelDigest: String
    let effectiveConfigurationDigest: String
    let capability: DiarizationCapability
}
```

- A resolver returns exactly one engine snapshot or a documented disabled/unavailable result.
- Shape-defining Sortformer configuration and model bundle are validated as one pair.
- `stableFourSpeaker` declares/rejects more than four remote speakers.
- `highContextV2_1` is not a normal public profile until separately approved.
- Automatic is one benchmark-approved revision, not multiple passes.

## Provider contract

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

struct DiarizationActivitySegment: Codable, Sendable, Equatable {
    let id: UUID
    let speakerKey: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let confidence: Float?
}
```

- Times are finite, non-negative, within logical duration, and `end > start`.
- Overlap is preserved. Speaker keys are opaque within a revision and never names.
- Callbacks are monotonic; cancellation is checked between bounded chunks.
- `unload()` occurs only after the owning inference task has returned or thrown.
- Capture callbacks never await the provider or its locks.

## Durable evidence contract

Successful ASR produces an immutable `MeetingTranscriptRevision` of source-aware timed spans before
speaker attribution. Successful diarization produces an immutable system-only
`MeetingDiarizationRevision`. A versioned `MeetingAttributionRevision` joins them.

A diarization revision is reusable only when all correctness inputs match:

1. schema and timeline-render versions;
2. ordered canonical system source fingerprints and logical timeline digest;
3. engine ID/version and model revision/digest;
4. profile revision and complete effective configuration digest.

ASR backend/model is intentionally absent from the diarization key. Attribution algorithm revision
is intentionally present in the attribution key.

Publication stages all new rows under one run, validates references/bounds/digests, and activates
them with the materialized transcript in one SQLite transaction. Cancellation/failure deletes the
staged revision and never partially replaces current output.

## Attribution contract

Every ASR span declares timestamp precision:

```swift
enum ASRTimestampPrecision: String, Codable, Sendable {
    case word
    case modelSegment
    case vadItem
    case none
}
```

- Word/model-segment text may be split only where supported timestamps/text boundaries exist.
- A VAD-item span receives `Speaker N` only when one speaker has dominant overlap under the
  versioned profile; otherwise it remains Others.
- Untimed/ambiguous system text remains Others.
- One text span is never duplicated across simultaneous speakers.
- A bounded nearest-speaker fallback must be versioned and may not cross unit/gap boundaries.
- Numbered labels are deterministic by first accepted appearance across the entire meeting.
- Automatic separated publication requires sufficient timestamp/assignment coverage and at least
  two useful remote speakers; storing an artifact does not force the UI to display it.

## Presentation and manual-edit contract

```swift
enum MeetingTranscriptPresentationMode: String, Codable, Sendable {
    case separated
    case collapsed
    case manual
    case legacyRendered
}
```

- Separated and Collapsed are deterministic projections of the same transcript revision.
- Collapsed maps system to Others and leaves microphone You.
- Switching either direction invokes zero ASR/diarizer calls.
- Manual text is a separate retained presentation. Generated projection changes never mutate it.
- `meetings.raw_transcript` transactionally mirrors the active presentation for existing search,
  export, sync, and old builds.
- Re-transcribe creates a new revision and warns before replacing an active Manual presentation;
  prior Manual text remains recoverable.

## Summary contract

Summary generation accepts an input descriptor containing transcript revision, attribution
revision, presentation mode, transcript digest, owner name, and speaker-legend revision.

The payload semantics are always:

- You = the one local microphone speaker and configured owner name when non-empty;
- Speaker N = anonymous remote system-audio speaker scoped to this meeting revision;
- Others = remote speech not separated, ambiguous, or deliberately collapsed;
- legacy Speaker = source identity unknown.

The LLM must not infer identity from language, content, or a mentioned name. It is not a
diarization-repair stage. Changing active presentation marks a summary whose input digest differs as
stale; only an explicit Re-summarize calls the configured summary provider.

## Homan Whisper response contract

The current item remains valid:

```json
{
  "id": "system-0001",
  "source": "system",
  "start": 10.0,
  "end": 27.0,
  "text": "..."
}
```

It may add a backward-compatible field:

```json
{
  "segments": [
    { "id": "system-0001-00", "start": 10.1, "end": 13.8, "text": "..." }
  ]
}
```

- Inner bounds use the same absolute unit coordinate as the outer item.
- Segments are contained, finite, ordered, source-inheriting, and uniquely identified.
- Absence receives `vadItem` precision; valid presence receives `modelSegment` precision.
- If the normalized inner-segment text does not reproduce the complete outer `text`, the client
  preserves the outer text and discards only the optional fine timestamps, treating the item as
  `vadItem` rather than silently losing or inventing words.
- Malformed optional segments reject only the response under existing validation rules; the client
  does not silently reinterpret coordinates.
- The server returns no speaker labels and receives no new audio/data for local diarization.

## Final/recovery contract

- Effective On: prepare -> ASR -> local diarization -> attribution -> active presentation ->
  title/summary/save under one processing run.
- Effective Off: skip model load and diarization/attribution phases; use You/Others.
- Automatic diarization failure is non-fatal: commit successful ASR as Others, record degradation,
  and offer standalone retry.
- Recovery discards partial revisions and recreates the original captured run plan.
- Final ignores provisional Live labels and reads retained sources.
- Audio import uses the same evidence/provider/attribution contracts. Its one mixed track is the
  diarizer input; Homan Whisper does not suppress the local stage.

## Re-transcribe and Re-diarize contract

- Re-transcribe independently selects ASR and meeting default/reuse/rerun/Off speaker handling.
- Compatible reuse invokes zero diarizer calls.
- Rerun invokes exactly one selected provider; no ensemble/fallback pass is hidden.
- Standalone Re-diarize consumes the active structured ASR revision, invokes zero ASR/title/summary
  providers, and leaves current output unchanged on failure.
- Standalone Re-diarize requires retained source-aware system audio. Audio-expired or flat-text-only
  legacy meetings explain why the action is unavailable.

## Live contract

- Live ASR state and Live diarization state are independent.
- A session override initialized from global Live default is always toggleable while eligible and
  never changes Final/global/meeting settings.
- Only system audio is submitted; microphone stays You.
- Each On transition creates a provisional epoch; no earlier text is backfilled.
- Off makes future system text Others and stops inference at a bounded checkpoint.
- Failure makes future system text Others while Live ASR/recording continue.
- Tentative labels are presentation only. Persisted crash checkpoints contain You/Others.
- Final may produce different labels and is explicitly authoritative.

## Progress and scheduling contract

- A persisted run-specific plan drives phase count, phase order, list/detail, and recovery.
- `.diarizing` and `.applyingSpeakerLabels` occur only when effective.
- `.rediarization` is a normal operation in the same table/channel.
- Model installation is not hidden inside processing.
- Initial heavy inference is sequential. Any later concurrency remains child work in one run.
- Capture always wins; Live inference preempts background Final diarization at bounded checkpoints.

## Retention/sync contract

- Audio expiry deletes audio and temporary renders, not ASR/dia/attribution/presentation revisions.
- Transcript expiry removes the materialized transcript and all structured transcript/speaker/manual
  transcript revisions together.
- Meeting deletion cascades everything.
- Backups and CloudKit keep active materialized text backward-compatible and may add one optional
  versioned evidence payload/asset. Missing evidence means readable legacy text, not fake controls.

## Failure/privacy contract

- Missing assets, no speech, provider failure, timeout, cancellation, invalid output, or database
  failure never corrupt canonical media or a prior committed transcript.
- Logs/telemetry exclude audio, transcript text, prompts, credentials, manual text, and embeddings.
- Local diagnostics may contain revision IDs, engine/model/profile, durations, counts, coverage,
  selected policy, and categorized errors.
- No outbound path is added beyond explicit model download and the already selected remote ASR.
