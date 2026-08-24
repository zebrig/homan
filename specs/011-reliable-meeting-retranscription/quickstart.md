# Quickstart: Validate Reliable Meeting Re-transcription

## Preconditions

- Work in `experiment/homan-0.8.3-retranscription-aec`.
- Do not launch or replace `/Applications/Homan.app`.
- Do not use the installed Homan support directory in tests.
- Use a worktree-specific SwiftPM scratch path and serial execution.

## Focused verification

```bash
swift test \
  --package-path native/MuesliNative \
  --scratch-path .cache/swiftpm/worktrees/retranscription-aec/test \
  --no-parallel \
  --filter MeetingRetranscriptionTests

swift test \
  --package-path native/MuesliNative \
  --scratch-path .cache/swiftpm/worktrees/retranscription-aec/test \
  --no-parallel \
  --filter MeetingTranscriptionPipelineTests

swift test \
  --package-path native/MuesliNative \
  --scratch-path .cache/swiftpm/worktrees/retranscription-aec/test \
  --no-parallel \
  --filter 'MeetingProcessingProgressTests|MeetingProcessingMetadataTests|MeetingProcessingMetadataDisplayTests'
```

## Compatibility verification

```bash
swift test \
  --package-path native/MuesliNative \
  --scratch-path .cache/swiftpm/worktrees/retranscription-aec/test \
  --no-parallel \
  --filter DictationStoreTests

swift test \
  --package-path native/MuesliNative \
  --scratch-path .cache/swiftpm/worktrees/retranscription-aec/test \
  --no-parallel \
  --filter 'MeetingCompatibilityTests|MeetingRecordingBundleTests|MeetingRawAudioPostProcessorTests|TestStorageIsolationTests'
```

## Authoritative gate

```bash
swift test \
  --package-path native/MuesliNative \
  --scratch-path .cache/swiftpm/worktrees/retranscription-aec/test \
  --no-parallel
```

## Owner-only local deployment

After every test and review gate passes, use the repository's host-first local installer. This may
replace and relaunch `/Applications/Homan.app`, but MUST NOT create a DMG, push the branch, or publish
a release.

```bash
./scripts/install_homan_local.sh
```

## Review assertions

- A production-shaped row with both `source_layout` and schema-2 bundle resolves to
  `raw_source_bundle`.
- The injected AEC processor receives system reference frames.
- Missing/degraded/unsupported bundle fixtures fall back without source-role loss.
- Old processing metadata JSON decodes with nil provenance.
- Normal finalization and Re-transcribe place `Processing audio` before `Transcribing`.
- Completed raw-source runs display actual AEC success, unavailable, not-applied, no-reference, or
  degraded state.
- No audio-behavior diff exists in capture/device, dictation/hotkey, writer/player, import, or
  retention code; import/final call sites may add progress/provenance wiring only.
