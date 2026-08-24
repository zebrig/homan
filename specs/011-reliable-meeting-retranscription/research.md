# Research: Reliable Meeting Re-transcription

**Status**: Code and on-disk audit complete on 2026-08-22

## Decision 1: Prefer canonical sources, not the playback convenience artifact

### Observed behavior

Production recording rows contain both `source_layout` and a schema-2 source-bundle registration.
`MeetingRecordingUnitResolver` checks `source_layout` first, so it returns `.separatedChannels` and
never loads the bundle. `MeetingTranscriptionRequest.aecModel` is therefore present but unused.

### Decision

Attempt bundle validation first. Prefer a complete loaded bundle. This reaches the already-existing
`MeetingRawAudioPostProcessor.renderProcessingView` branch, which aligns raw sources and applies
the requested AEC.

### Rejected alternatives

- Run AEC on M4A: rejected because the M4A is lossy and exists only as playback/fallback while
  better retained sources are already available.
- Modify the database to clear `source_layout`: rejected because it destroys useful fallback
  metadata and changes user data to compensate for a code-ordering bug.
- Rebuild storage as one lossless stereo file: rejected as unrelated and much higher risk.

## Decision 2: Make fallback completeness-aware

### Observed behavior

The bundle loader derives `complete`, `degraded`, or `invalid` from current files rather than trusting
the database source-state field. A degraded bundle may retain useful audio, while playback may be
complete.

### Decision

Use this order:

1. complete canonical bundle;
2. usable role-separated playback fallback;
3. usable degraded canonical bundle;
4. legacy mixed or existing unavailable result.

This favors canonical quality when trustworthy and favors complete role-separated playback when
canonical storage has gaps. When playback is legacy mixed, the degraded canonical bundle wins
because it is the only representation that preserves a known source role.

## Decision 3: Preserve role-aware fallback

When `source_layout` exists, fallback remains `.separatedChannels`; without it, fallback remains
`.legacyMixed`. A failed bundle must not demote a known two-channel recording to legacy mixed.

## Decision 4: Do not duplicate AEC implementation

Both generic and Homan Whisper pipeline paths already call
`MeetingRawAudioPostProcessor.renderProcessingView` for schema-2 `.sourceBundle` input. The defect is
selection, not processing. The implementation changes the resolver and verifies the existing
injection point rather than creating another echo-cancellation path.

## Decision 5: Store requested provenance, log actual runtime processor

### Observed limitation

Current processing metadata stores ASR backend/model but not the audio representation or requested
AEC. `MeetingNeuralAec` may load the selected LocalVQE model, fall back to DTLN, or pass through if
no processor loads.

### Decision

Add optional `audioSource` and `aecModel` fields to transcription run metadata. `aecModel` means the
requested configured model and is present only for schema-2 raw-source processing. Emit the actual
processor name/readiness and processed/reference frame counts to local diagnostics after the pass.

Do not label the requested model as successfully active merely because it was configured.

## Decision 6: Test the production metadata combination

Existing tests separately cover a two-channel playback row and a source-bundle row. The source
fixture does not also set `source_layout`, so it cannot detect the production precedence defect.
The new regression fixture must register both representations on the same recording ID, reopen the
database, and resolve from storage exactly as the controller does.

## No web dependency

All decisions derive from the checked-out Homan 0.8.3 experiment chain, its tests, the local SQLite
schema, and the retained manifest/codecs. No external API or current model-quality claim is needed.

## Decision 7: Separate AEC progress from ASR and persist actual outcome

### Observed behavior

Re-transcription changed the persisted phase to `transcribing` before raw-source rendering and AEC.
Normal finalization already performed AEC before ASR, but represented that work as generic audio
preparation and then stored `derived_source_bundle` without actual AEC evidence. Detailed AEC output
was written only to stderr, which is discarded in the installed launch context.

### Decision

Add one stable `processing_audio` phase between preparation and transcription for normal
finalization, raw recovery, and re-transcription. Carry the existing bounded AEC snapshot beside each
raw-source transcription unit and persist an aggregate containing processor/readiness/frame counters
and a non-sensitive processing-error category. Emit the same summary through unified logging. Do not
persist raw error text, audio, paths, delay histories, or model payloads.

The completed-run UI derives success from actual evidence: a ready processor with non-zero processed
frames, usable reference frames, and no processing error. Unavailable, zero-frame, no-reference, and
errored outcomes remain visibly distinct.

Generic multi-unit processing uses the same prepare-all-then-transcribe boundary as the Homan
Whisper batch path. This keeps every raw AEC pass inside `processing_audio`; legacy input explicitly
crosses to `transcribing` before ASR. Per-unit application counts prevent aggregate frame totals from
hiding a failed or empty resumed session. When no system source exists, the post-processor does not
feed padded zeros into AEC as captured reference.

Prepare-all temporarily holds every prepared source until ASR begins. This is the smallest change
that keeps the displayed phase truthful across multi-unit meetings, but it can increase peak
temporary disk use and delay the first ASR result. Cleanup remains idempotent and lease-scoped. The
separated-channel extractor accepts a default no-op cancellation callback, while re-transcription
supplies `Task.checkCancellation()` and checks it between bounded 16,384-frame blocks; unrelated
callers retain their prior behavior.
