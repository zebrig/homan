# Validation Quickstart: Local Meeting Diarization

Core implementation validation was completed on 2026-08-17. The full SwiftPM run passed 1,739
tests in 187 suites with zero failures. Real-audio DER/JER, RTFx, peak-RSS, and cancellation-latency
results are not claimed yet; Final and Live defaults therefore remain Off.

## Static audit

```bash
rg -n "DiarizerManager|OfflineDiarizerManager|SortformerDiarizer|LSEENDDiarizer" \
  native/MuesliNative/Sources native/MuesliNative/Tests
rg -n "backend != BackendOption.homanWhisper|backend == BackendOption.homanWhisper" \
  native/MuesliNative/Sources/MuesliNativeApp/MeetingTranscriptionPipeline.swift
git diff --check
```

Expected after implementation:

- production meeting pipeline depends on the local provider protocol, not a concrete diarizer;
- Homan Whisper selection does not suppress local diarization;
- old response decoding remains covered;
- microphone is never passed to a diarizer and system is never rendered as You;
- ASR evidence, diarization, attribution, presentation, and summary provenance are separately
  persisted while `raw_transcript` remains the active compatibility snapshot;
- no raw-capture, AEC, playback, or retention implementation was duplicated.

## Automated contract validation

Use a dedicated SwiftPM scratch path inside Homan:

```bash
swift test \
  --package-path native/MuesliNative \
  --scratch-path "$PWD/.cache/swiftpm/local-meeting-diarization/test"
```

Required focused suites:

- model/config profile resolution;
- logical multi-unit timeline mapping;
- transcript/dia/attribution revision atomicity, reuse, invalidation, and retention;
- Separated/Others/Manual switching, manual-edit preservation, and summary staleness;
- timestamp precision and speaker-boundary alignment;
- old/new Homan Whisper response compatibility;
- run-specific progress-plan rehydration, Re-diarize, and cancellation;
- inference scheduler priority and unload safety;
- global/meeting/one-time/Live policy scope and resolution;
- backup/CloudKit additive evidence compatibility;
- source-role and legacy compatibility.

Observed full-suite command:

```bash
swift test --package-path native/MuesliNative
```

Observed result on the development Mac: 1,739 tests in 187 suites, zero failures.

## Emergency legacy-provider rollback

The rollback is internal and mutually exclusive with the selected shipping provider. It uses only
the already-cached FluidAudio `pyannote_segmentation` and `wespeaker_v2` models, performs no hidden
second diarizer pass, and never downloads from the meeting-processing path.
The synchronous legacy engine is driven in its native 10-second chunks so capture and cancellation
are checked between chunks instead of waiting for an entire meeting-sized call.
Completed legacy artifacts are reusable while rollback remains selected, but are never treated as
artifacts from a current Offline/Sortformer profile after rollback is disabled.

Enable persistently for the Homan app domain:

```bash
defaults write com.zebrig.homan HomanMeetingDiarizationForceLegacyProvider -bool true
```

Return to the current provider:

```bash
defaults delete com.zebrig.homan HomanMeetingDiarizationForceLegacyProvider
```

For a development launch, `HOMAN_MEETING_DIARIZATION_PROVIDER=legacy` forces rollback and
`HOMAN_MEETING_DIARIZATION_PROVIDER=current` explicitly disables it. The environment value takes
precedence over the stored flag. A missing legacy cache fails as optional speaker analysis and
degrades to `Others`; it does not fall through to a hidden second engine.

## Manual behavior matrix

For each installed profile, exercise:

1. Final after a normal call.
2. Re-transcribe with local ASR.
3. Re-transcribe with Homan Whisper.
4. Recovery after terminating during diarization.
5. Start a new recording while the prior meeting is diarizing.
6. Start/stop Live while background diarization exists.
7. Toggle Live speaker separation On/Off/On independently of Live ASR.
8. Keep/re-run/disable separation during Re-transcribe.
9. Run standalone Re-diarize and inject provider/database failure.
10. Switch Separated/Others, create a Manual edit, and switch all three views.
11. Remove/miss the model asset.
12. Delete/expire meeting audio, then expire its transcript.
13. Sync/backup/restore with and without the optional evidence payload.

Expected:

- capture and Live remain responsive;
- list/detail show the same `Diarizing` phase;
- failure falls back to `Others` with retry, not a broken meeting;
- matching ASR-only retry reuses the artifact;
- settings remain unchanged after a one-time override;
- collapse/restore performs no inference and manual text remains recoverable;
- Live failure/toggles do not affect Final or recovery checkpoints;
- summary provenance becomes stale after presentation change and no LLM runs automatically;
- audio/source digests remain unchanged;
- audio deletion leaves structured text/speaker revisions but no audio/temp orphan;
- transcript deletion removes structured revisions with the materialized text.

## Quality corpus matrix

Minimum cells:

| Dimension | Required coverage |
|---|---|
| Language | RU, PL, EN, mixed language |
| Remote speakers | 1, 2, 3, 4, 5+ |
| Acoustic condition | clean, noise, quiet/far, presentation/media, overlap |
| Recording shape | one unit, pause/resume, several units, route change |
| ASR timestamps | word, model segment, VAD-only, untimed |
| Provider | at least one local ASR, Homan Whisper outer-only, Homan Whisper inner segments |
| Operation | Final, recovery, Re-transcribe reuse/rerun/off, standalone Re-diarize, Live preview |

Compare current legacy, Offline Community-1, Sortformer balanced v2.1, and experimental high-context
on the exact same prepared system timeline. Record exact dependency/model revisions and device/OS.

Do not approve Automatic from DER alone. Report:

- DER and JER;
- missed speech, false alarm, and speaker confusion separately;
- detected/true speaker count;
- final text-to-speaker attribution accuracy;
- processing duration/RTFx, peak RSS, load time, disk size;
- cancellation latency and capture/Live impact.

## Release gate

The feature may leave opt-in only when:

- all source-role, retention, recovery, and processing regressions pass;
- policy scope, manual-edit, projection, summary-provenance, backup/sync, and Live checkpoint tests
  pass;
- exact shipping assets pass integrity and model/config checks;
- cancellation is bounded on every supported engine;
- no test starts an implicit model download during recording/finalization;
- Automatic's quality/resource thresholds are written here and approved by the owner;
- a rollback to legacy or generic `Others` is verified;
- Final rollout may proceed before Live, but Live cannot ship until its independent state, failure,
  and provisional-label semantics pass their own gate.
