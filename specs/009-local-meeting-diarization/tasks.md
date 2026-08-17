# Tasks: Local Meeting Diarization

**Status**: Core implementation complete; benchmark corpus, server timestamp extension, and default
rollout gates remain open

**Prerequisites**: owner approval of spec.md, flows-and-ux.md, plan.md, research.md, data-model.md,
and contracts/local-diarization.md

Every phase is independently testable and rollback-safe. No task is complete merely because the
app builds.

## Milestone A0 - Baseline and lifecycle characterization

- [ ] T001 Freeze consented/de-identified RU/PL/EN quality fixtures and reference annotations.
- [ ] T002 Add DER/JER, miss/false-alarm/confusion, speaker-count, attribution, timing, memory, and
  cancellation benchmark harness.
- [ ] T003 Record the exact current legacy `DiarizerManager` behavior/resource baseline.
- [x] T004 Add characterization tests for current Final, recovery, Re-transcribe, Homan Whisper,
  audio import, transcript editing, retention, backup/iCloud, progress, and start-next-meeting flows.
- [x] T005 Add assertions that microphone is always You, system never You, and current Live recovery
  checkpoints contain source-authoritative labels.

## Milestone A1 - Durable evidence and reversible presentation (models still unchanged)

- [x] T006 Add additive SQLite transcript, diarization, attribution, presentation, and run-plan
  schemas with downgrade/unknown-field tolerance.
- [x] T007 Materialize the active presentation into existing `raw_transcript` transactionally.
- [x] T008 Convert transcript editor save into a separate Manual presentation; preserve/restore it
  across generated view switches and new revisions.
- [x] T009 Implement deterministic Separated/Others projections and zero-inference switching.
- [x] T010 Add summary input revision/digest/mode provenance and stale-summary detection.
- [x] T011 Add additive text-backup evidence payload and CloudKit evidence asset; characterize old
  backup/old-client/missing-asset degradation.
- [x] T012 Change audio cleanup to keep text/speaker revisions; change transcript cleanup and
  meeting deletion to remove them atomically.
- [ ] T013 Test four-hour projection latency, manual-edit preservation, word equality, search/export,
  sync/restore, audio expiry, transcript expiry, and database rollback.

## Milestone A2 - Dependency and engine-neutral foundation

- [x] T014 Upgrade FluidAudio from exact 0.15.1 to selected exact 0.15.2.
- [x] T015 Run all existing ASR, VAD, raw audio, AEC, LocalVQE/shutdown, playback, and meeting tests.
- [x] T016 Add provider/result/progress contracts and fake providers without changing selection.
- [x] T017 Add immutable Final profiles and exact model/config compatibility validation.
- [x] T018 Implement Offline Community-1, Sortformer balanced, and legacy adapters behind the
  provider boundary; keep high-context research-only.
- [x] T019 Ensure cancellation/unload cannot race active inference; serialize model ownership.
- [x] T020 Add app-owned asset install/remove/digest/license state; prohibit implicit downloads in
  recording/finalization.

## Milestone A3 - Logical timeline and Homan Whisper timestamp parity

- [x] T021 Build deterministic meeting-global system timeline across all retained units/gaps.
- [x] T022 Render bounded/file-backed disposable system input without changing canonical audio/AEC.
- [x] T023 Persist/validate/fingerprint transcript and diarization revisions atomically.
- [x] T024 Normalize every local ASR result into source-aware spans with timestamp precision.
- [x] T025 Extend the Homan Whisper client with optional inner segments while accepting current
  outer-item-only responses.
- [ ] T026 Extend homan-transcribe-server to return Whisper inner segment timestamps only; do not
  add server-side speaker labels or model choices.
- [ ] T027 Complete server-side contract coverage. Client tests already cover IDs, source, absolute
  bounds, containment, ordering, duplicate/malformed segments, text-preserving coarse fallback,
  old responses, and partial failure.
- [x] T028 Verify changing ASR provider leaves a matching diarization revision reusable.

## Milestone A4 - Attribution and quality publication

- [x] T029 Implement boundary-aware attribution with word/model/VAD/untimed precision rules.
- [x] T030 Preserve overlap evidence, never duplicate text, and keep ambiguous system spans Others.
- [x] T031 Assign deterministic meeting-global Speaker N labels across multiple recording units.
- [x] T032 Add versioned quality publication metrics/reasons and conservative automatic collapse.
- [ ] T033 Add fixtures for 1/2/3/4/5+ speakers, overlap, quiet voices, media playback, coarse Homan
  timestamps, gaps, route changes, and multilingual turns.
- [x] T034 Render a mandatory summary speaker legend with configured owner name and test every
  summary backend/prompt override path.

## Milestone A5 - Unified processing and user controls

- [x] T035 Replace static phase arrays with persisted run-specific plans and add `.diarizing`,
  `.applyingSpeakerLabels`, and `.rediarization`.
- [x] T036 Move diarization out of the hidden ASR-provider condition; remove the late cosmetic
  staging `.diarizing` marker as a UI authority.
- [x] T037 Migrate `AudioFileImportController` from its direct legacy diarizer to the shared
  transcript/dia/attribution revisions, preserving mixed-unknown semantics for local/Homan ASR.
- [x] T038 Implement global Final On/Off/profile and per-meeting Follow Settings/On/Off snapshot.
- [x] T039 Implement Re-transcribe ASR + Meeting default/Keep/Re-run/Off independent options.
- [x] T040 Implement standalone Analyze speakers again without ASR/title/summary.
- [x] T041 Add Transcript `Manual | Separated | Others`, provenance/status, stale-summary banner,
  and explicit Re-summarize.
- [x] T042 Make automatic Final diarization failure non-fatal/visible and standalone Re-diarize
  failure atomic.
- [x] T043 Verify Final, recovery, Re-transcribe, Re-diarize, failure, relaunch, cancellation,
  Needs Attention, and start-next-meeting status from the same progress record.
- [x] T044 Add inference scheduling so recording/capture wins and local heavy work is initially
  sequential; prohibit unload/shared-model races.

## Milestone A6 - Benchmark and Final rollout gate

- [ ] T045 Benchmark exact legacy, Offline Community-1, Sortformer balanced, and experimental
  high-context assets on exact Homan prepared system audio.
- [ ] T046 Record DER components, attribution accuracy, speaker count, RTFx, load time, peak RSS,
  cancellation latency, and start-new-recording impact by Mac memory class.
- [ ] T047 Select/approve one Automatic Final profile revision and measurable publication gates.
- [x] T048 Ship Final/Homan/retry/presentation behavior behind opt-in with rollback to Others/legacy.
- [ ] T049 Enable the new default only after no-regression and field validation.

## Milestone B1 - Independent provisional Live diarization

- [x] T050 Add independent `MeetingLiveDiarizationRuntimeState` and session override initialized
  from a separate global Live default.
- [x] T051 Add a Live-card switch available independent of the Live ASR global default/model.
- [x] T052 Feed only system preview audio to an engine-neutral Live adapter without blocking capture.
- [x] T053 Integrate provisional labels with chunked and streaming Live timestamps; ambiguous text
  stays Others and no earlier text is backfilled.
- [x] T054 Define off/on epoch/reset semantics visibly; never pretend labels are stable after state
  was discarded.
- [x] T055 Keep crash checkpoints You/Others and prove Final ignores every Live label/epoch.
- [x] T056 Make Live diarizer failure/off transitions leave Live ASR and raw recording operational.
- [ ] T057 Benchmark Sortformer balanced versus LS-EEND for latency, quiet speech, false alarms,
  identity stability, 4/5+ speakers, CPU/ANE/RSS, and model-switch interaction.
- [ ] T058 Approve one Automatic Live profile and staged rollout independently from Final.

## Dependency order

- Durable evidence/manual presentation must land before any new model can rewrite labels.
- Exact FluidAudio upgrade and lifecycle regressions block provider integration.
- Logical timeline and timestamp normalization block reliable artifacts and Homan Whisper parity.
- Homan inner timestamps improve accuracy but old coarse responses remain supported conservatively.
- Dynamic progress/scheduling block enabling user-visible Final/Re-diarize.
- Final benchmark approval blocks changing Automatic/defaults.
- Live work starts only after Final evidence/recovery invariants are stable.

## Explicit non-tasks

- diarizing microphone audio;
- cross-meeting biometric identity or automatic speaker naming;
- server-side diarization;
- text-similarity speaker deduplication;
- multi-engine voting/ensembling;
- automatic LLM calls after presentation changes;
- claiming Live labels match Final labels;
- public raw high-context/tensor/FIFO/threshold/compute-unit knobs.
