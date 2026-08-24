# Data Model: Reliable Meeting Re-transcription

## MeetingTranscriptionAudioSource

An internal stable diagnostic identity for the representation selected for a recording unit.

| Value | Meaning | Re-runs AEC |
|---|---|---:|
| `raw_source_bundle` | Schema-2 pre-AEC microphone/system epochs | yes |
| `derived_source_bundle` | Schema-1 already-prepared role-separated sources | no |
| `separated_playback` | Left/right playback artifact with recorded source layout | no |
| `legacy_mixed` | One source without reliable microphone/system identity | no |

The value describes actual pipeline input, not what files happen to coexist on disk.

## RecordingUnitResolution

Conceptual resolver result; implementation continues returning `MeetingRecordingUnitInput`.

| Field | Meaning |
|---|---|
| selectedInput | sourceBundle, separatedChannels, or legacyMixed |
| sourceKind | One `MeetingTranscriptionAudioSource` value |
| bundleState | complete, degraded, invalid, unsupported, unavailable, or notRegistered |
| fallbackReason | Optional local diagnostic category; contains no path/audio data |
| usesRequestedAEC | True only for a selected schema-2 raw source bundle |

### Selection invariants

- A complete supported bundle always wins.
- A usable separated playback file wins over a degraded/invalid bundle.
- A usable degraded bundle wins when separated playback is unusable or unavailable, and wins over
  legacy mixed playback to preserve known source roles.
- An invalid bundle is never selected.
- `source_layout` determines whether playback fallback is separated or legacy.
- Resolution is read-only.

## MeetingProcessingRunMetadata additions

| Field | Type | Meaning |
|---|---|---|
| audioSource | optional String | Unique selected kind or deterministic `+`-joined kinds for a resumed multi-unit run |
| aecModel | optional String | Requested configured AEC model only when at least one selected unit is `raw_source_bundle` |
| aecDiagnostics | optional MeetingAecRunDiagnostics | Bounded aggregate of the processor outcome that actually ran |

All fields are optional. Missing keys from Homan 0.8.3 and older decode as `nil`. Summary runs leave
them `nil`.

## MeetingAecRunDiagnostics

| Field | Meaning |
|---|---|
| processor | Actual processor name, or deterministic `+`-joined names for multiple raw units |
| ready | True only when every recorded processor snapshot was ready |
| processedFrames | Total AEC frames attempted |
| fullReferenceFrames | Frames with complete aligned system reference |
| partialReferenceFrames | Frames with partial system reference |
| missingReferenceFrames | Frames without system reference |
| sourceUnitCount | Number of raw source units contributing diagnostics |
| appliedSourceUnitCount | Units with ready processor, non-zero frames, usable reference, and no processing error |
| processingError | Optional stable `processing_failed` category; raw error text is not stored in run metadata |

The UI treats ready + non-zero frames + at least one full/partial reference frame + no processing
error as successful application. Requested configuration remains separate in `aecModel`.
For multi-session runs, success additionally requires `appliedSourceUnitCount == sourceUnitCount`;
otherwise the UI reports partial application. A missing system source contributes missing-reference
frames rather than artificial full-reference silence.

## Runtime AEC diagnostic

The existing `MeetingAecDiagnosticsSnapshot` remains the authority for:

- `ready`;
- actual `processor` name;
- processed frame count;
- full/partial/missing reference-frame counts.

This feature logs and persists a bounded summary after raw post-processing. It does not persist
paths, samples, delay histories, transcript contents, or model binaries.

## MeetingProcessingPhase addition

`processing_audio` is stored in the immutable run plan immediately before `transcribing` for normal
finalization, raw recovery, and re-transcription. It covers rendering/alignment/AEC (or equivalent
source preparation for playback fallback) and prevents that duration from being reported as ASR.
