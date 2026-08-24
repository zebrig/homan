# Contract: Re-transcription Source Selection

## Inputs

- one `MeetingRecordingUnitRecord`;
- Homan support-directory authority;
- current filesystem state;
- registered source-bundle schema/state metadata;
- optional playback `source_layout`.

## Output order

```text
load supported registered source bundle
        |
        +-- complete ----------------------> source bundle
        |
        +-- degraded + separated usable ---> separated playback
        |
        +-- degraded + no separated audio -> degraded source bundle
        |
        +-- invalid/error/unsupported ------> separated/legacy playback

no registered source bundle ---------------> separated/legacy playback
```

## Playback fallback contract

- With `source_layout`, return `separatedChannels` and preserve its exact role availability.
- Without `source_layout`, return `legacyMixed` and add no fabricated `You` role.
- A usable degraded source-aware bundle wins over legacy mixed playback because it preserves known
  microphone/system identity; legacy mixed remains the last playback fallback.
- File usability is checked without opening or modifying user data; decode errors remain pipeline
  errors under existing behavior.

## AEC contract

- `raw_source_bundle` MUST call the existing AEC factory with the run-scoped selected model.
- `derived_source_bundle`, `separated_playback`, and `legacy_mixed` MUST NOT claim AEC execution.
- An unavailable processor MAY retain existing DTLN fallback/raw pass-through behavior, but
  diagnostics MUST distinguish it from requested-model readiness.

## Safety contract

- Resolver performs no writes, migrations, deletions, compaction, transcoding, or manifest repair.
- Read/deletion leases retain their current ownership rules.
- No fallback may expose paths or audio content in persisted provenance.
