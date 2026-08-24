# Tasks: Reliable Meeting Re-transcription

**Input**: Design documents from `specs/011-reliable-meeting-retranscription/`

## Phase 1 - Spec Kit and baseline

- [x] T001 Document production source-selection defect in `research.md`.
- [x] T002 Define source/fallback/AEC contracts in `spec.md`, `data-model.md`, and
  `contracts/source-selection.md`.
- [x] T003 Fix the implementation base at `experiment/homan-0.8.3-upstream-safe` and isolate work in
  `experiment/homan-0.8.3-retranscription-aec`.

## Phase 2 - User Story 1: raw-source re-transcription

- [x] T004 [US1] Add a failing production-shaped resolver test with both `source_layout` and source
  bundle in `MeetingRetranscriptionTests.swift`.
- [x] T005 [US1] Refactor `MeetingRecordingUnitResolver.swift` to prefer a complete canonical bundle.
- [x] T006 [US1] Strengthen raw-pipeline test evidence that the injected AEC processes non-zero
  system reference before ASR.

## Phase 3 - User Story 2: safe fallback

- [x] T007 [US2] Add missing/unsupported/invalid/degraded bundle fallback cases in
  `MeetingRetranscriptionTests.swift`.
- [x] T008 [US2] Preserve separated playback roles and use degraded canonical audio when no usable
  separated playback exists, ahead of legacy mixed playback.

## Phase 4 - User Story 3: provenance

- [x] T009 [US3] Add stable source-kind helpers to `MeetingTranscriptionTypes.swift`.
- [x] T010 [US3] Add optional `audioSource` and `aecModel` fields to
  `MuesliCore/StorageModels.swift` and factory defaults.
- [x] T011 [US3] Persist source provenance for initial final processing, re-transcription, and
  imported-file processing; persist requested AEC only when raw sources are reprocessed.
- [x] T012 [US3] Emit bounded actual AEC processor/readiness/frame diagnostics from
  `MeetingRawAudioPostProcessor.swift`.
- [x] T013 [US3] Add old/new metadata round-trip tests.

## Phase 5 - User Story 4: compatibility and verification

- [x] T014 [US4] Run focused re-transcription and raw-pipeline tests serially.
- [x] T015 [US4] Run compatibility, retention, and test-storage isolation suites serially.
- [x] T016 [US4] Run the complete SwiftPM suite serially in the feature scratch path.
- [x] T017 [US4] Review the diff for forbidden capture/dictation/player/writer/import/retention changes.
- [x] T018 [US4] Perform independent spec/code/test audit and address findings, including moving
  source-bundle validation I/O off `MainActor`.
- [x] T019 [US4] Commit the experiment without push or release.
- [x] T020 [US4] Build and install the experiment only on the owner's Mac with the repository's
  host-first installer; do not create a DMG or publish artifacts.

## Phase 6 - User Story 5: truthful post-call and re-transcription progress

- [x] T021 [US5] Audit normal post-call, recovery, generic re-transcription, and Homan Whisper
  re-transcription phase ordering.
- [x] T022 [US5] Add a distinct `processing_audio` phase before ASR in normal finalization and
  re-transcription plans and controllers.
- [x] T023 [US5] Carry actual AEC snapshots from raw preparation through transcription units and
  persist a bounded aggregate in processing metadata.
- [x] T024 [US5] Correct normal post-call provenance to `raw_source_bundle` and include its requested
  and actual AEC evidence; preserve derived recovery provenance when no raw pass occurs.
- [x] T025 [US5] Display successful, unavailable, not-applied, and degraded AEC outcomes without
  presenting configuration as execution evidence.
- [x] T026 [US5] Add progress-order, raw-pipeline, metadata compatibility/aggregation, and display
  regression tests for both processing paths.
- [x] T026a [US5] Close independent-review findings for microphone-only reference truthfulness,
  partial multi-unit AEC aggregation, legacy/generic multi-unit phase ordering, and bounded
  cancellation during separated-channel extraction.
- [x] T027 [US5] Run the focused and complete serial SwiftPM suites and review the final diff.
- [x] T028 [US5] Commit all User Story 5 changes as one local experimental commit without push,
  release, installer, or application replacement.

## Dependencies

- T005 depends on failing T004.
- T008 depends on T007 and the resolver structure from T005.
- T010-T012 depend on the source-kind contract from T009.
- T014-T019 depend on all implementation and test tasks.
- T027-T028 depend on T021-T026.

## Phase 7 - Merge hardening

- [x] T029 Extend the Spec Kit with the whole-operation source-lifetime race and the explicit
  channel-AEC versus speaker-diarization acceptance boundary.
- [x] T030 Add atomic multi-recording read leases with all-or-nothing and idempotent-release tests.
- [x] T031 Acquire the composite lease before Re-transcribe source validation and hold it through
  all source-dependent processing, then release it before summary generation; verify deletion is
  deferred across an async preload-shaped suspension.
- [x] T032 Add cancellation checkpoints around Homan Whisper multi-unit preparation and verify
  temporary files and nested leases are released.
- [x] T033 Run focused tests, the authoritative serial suite, test-isolation gate, and release build.
- [x] T034 Commit merge hardening on the experiment branch, then merge `main` without discarding its
  CoreAudio lifecycle commit, advance the default development version to 0.8.4, and repeat the
  merge-candidate gates without publishing or installing.

## Phase 8 - Experimental branch reconciliation

- [x] T035 Compare every non-ancestor local branch against `main` by patch identity. Record the four
  patch-equivalent legacy branches as already integrated and explicitly exclude the unproven
  default-off idle-audio-graph invalidation experiment from `main` pending its hardware gate.
