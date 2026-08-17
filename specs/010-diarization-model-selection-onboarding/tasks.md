# Tasks: Diarization Model Selection and Onboarding

**Status**: Planned; all implementation tasks are pending

**Prerequisites**: approval of `spec.md`, `flows-and-ux.md`, `plan.md`, `data-model.md`, and
`contracts/model-selection.md`

**Implementation status**: Milestones A and B (T001–T012) are implemented in
`MeetingDiarizationModelCatalog.swift`, `MeetingDiarizationModelSelection.swift`,
`MeetingDiarizationReconciliation.swift`, and their tests. `MuesliController` owns
reconciliation and calls it after startup, install/update/retry, and remove commits; views only
read the published state. Milestone C and later remain pending.

Tasks are ordered so migration/runtime safety lands before UI cleanup. A task is not complete merely
because the app builds.

## Milestone A - Characterize current behavior

- [x] T001 Add characterization tests proving current `.automatic` global resolution and historical
  evidence validation both map to Offline quality.
- [x] T002 Add characterization tests proving current Live preparation is hard-coded to Stable up
  to 4 and that Live/Final enablement are independent.
- [x] T003 Add catalog/asset fixtures for zero/one/many ready, downloading, setting up,
  update-available, failed, deprecated, unsupported, and interrupted setup states.
- [x] T004 Add onboarding characterization for primary/additional ASR ordering, progress schema 1–4,
  permission-repair resume, and current post-Wizard continuation behavior.
- [ ] T005 Record signed Release smoke baseline for Final, Live, Homan Whisper, Re-transcribe,
  Re-diarize, start-next-meeting, and app quit during processing.

## Milestone B - Capability catalog and pure selection

- [x] T006 Add open `MeetingDiarizationModelID`, capabilities, lifecycle, asset revision, adapter,
  localization, license, onboarding, replacement, and legacy-alias descriptor fields.
- [x] T007 Add a bundled versioned/schema-validated catalog plus last-valid/empty fallback,
  tombstones, unique-ID/alias checks, replacement-cycle checks, and allowlisted adapter validation.
- [x] T008 Implement the pure zero/one/many-ready selection resolver, `choiceRequired`, and
  transition reason without a fallback model constant.
- [x] T009 Cover the full generic truth table, idempotence, malformed/unknown/retired values, and
  synthetic catalogs containing 0, 1, 2, 3, and 10 descriptors.
- [x] T010 Add a serialized controller-owned reconciliation operation with stale-generation
  rejection.
- [x] T011 Invoke reconciliation after startup validation and successful install/update/retry/
  remove/repair/lifecycle commits; prove views do not own selection writes.
- [x] T012 Normalize Live default Off transactionally when a Final-only profile is selected.

## Milestone C - Compatibility and concrete run capture

- [ ] T013 Add a shared semantic config accessor while retaining the existing persisted JSON key.
- [ ] T014 Bridge future global `.automatic` through its historical catalog alias and then the
  generic zero/one/many rules without modifying any meeting/evidence record.
- [ ] T015 Keep historical `.automatic` definition resolution and profile digest checks unchanged;
  add fixtures for legacy manifests and completed evidence.
- [ ] T016 Require a concrete open stable ID/descriptor revision or disabled/unavailable/
  choice-required state for every new meeting/run capture.
- [ ] T017 Verify recovery uses the captured profile even after Settings or installed assets change.
- [ ] T018 Verify old/downgraded builds fail safely rather than crash on unknown future stable IDs,
  while current/legacy IDs and old evidence remain compatible.

## Milestone D - Capability-aware Final and Live runtime

- [ ] T019 Change Live engine preparation to accept an exact captured stable ID/descriptor and use
  its allowlisted adapter.
- [ ] T020 Add typed unsupported-Live, unsupported-adapter, and missing/invalid-asset errors; never
  substitute one model for another.
- [ ] T021 Capture Live profile/capability at meeting start independently of Final On/Off policy.
- [ ] T022 Disable active-meeting Live speaker control for every captured descriptor with
  `supportsLive == false` or unavailable state and show the exact required message.
- [ ] T023 Preserve Live ASR/raw recording on every Live capability/asset/preparation failure.
- [ ] T024 Keep one-time Re-transcribe/Re-diarize choices independent and filter them to ready
  concrete profiles.
- [ ] T025 Prove Homan Whisper Final uses the captured shared profile through the existing local
  diarization stage.

## Milestone E - Models and Settings UX

- [ ] T026 Remove Models `Used by Automatic`, `Active`, `Use for Final`, and configuration-based
  card borders/actions.
- [ ] T027 Render Models by iterating catalog/tombstone descriptors with Download, Setting up,
  Downloaded, Update, Retry, Legacy model, No longer supported, Replace, and Remove states.
- [ ] T028 Implement app-owned staging/resume/validation/quarantine/rollback/orphan cleanup and
  atomic update activation while retaining capture-active mutation guards and last-known-good asset.
- [ ] T029 Add the Models explanatory text for automatic sole-model selection and Settings choice.
- [ ] T030 Add Settings `Speaker separation model` zero/one/many states, `choiceRequired`, and
  `Open Models` navigation.
- [ ] T031 Populate the Settings picker from all ready/selectable descriptors, preserve a valid
  selection after additional installs, and require a choice when several remain without one.
- [ ] T032 Add exact `This model doesn't support Live speaker diarization` copy beside the disabled
  Live Settings control for every descriptor lacking Live capability.
- [ ] T033 Add accessible toast/help for auto-select-after-remove and Live normalization.
- [ ] T034 Verify minimum window width, text wrapping, keyboard navigation, and VoiceOver order.

## Milestone F - Durable onboarding preparation plan

- [ ] T035 Add Codable stable-ID preparation plan/item/phase/error/update types.
- [ ] T036 Build deterministic plans from required ASR, optional ASR, use case, and optional single
  diarization choice.
- [ ] T037 Add one actor-owned executor that reuses existing ASR preload and diarization asset-store
  install/validation paths.
- [ ] T038 Add item-local `n of m` progress without cross-provider byte averaging.
- [ ] T039 Add attempt/plan IDs and awaitable owner transfer so stale callbacks and duplicate
  downloads cannot race.
- [ ] T040 Add optional item Retry/Skip and required-primary gating semantics.
- [ ] T041 Reconcile shared selection only after a diarization item validates ready; never enable
  Final or Live from onboarding.
- [ ] T042 Prove changing to a non-meeting use case removes only an unstarted plan item and never
  deletes an already ready asset.

## Milestone G - Onboarding persistence and UI

- [ ] T043 Bump `OnboardingProgress` to schema 5 with selected diarization intent and plan state;
  preserve schema 1–4 decoding.
- [ ] T044 Update `OnboardingWindowController` resume reconstruction and permission-repair path.
- [ ] T045 Replace the SwiftUI-owned single-backend task with observation/control of the app-owned
  preparation session.
- [ ] T046 Rename the model-step heading and add Transcription/Speaker separation sections only for
  relevant use cases.
- [ ] T047 Add Not now plus catalog-driven onboarding-eligible single-choice cards, recommendation,
  capability/constraint/status copy, and no model-specific view branch or implicit selection.
- [ ] T048 Make Download & Continue construct/persist/start the complete plan before advancing.
- [ ] T049 Transfer the complete remaining plan to controller ownership on Wizard completion rather
  than reconstructing only the primary backend.
- [ ] T050 Add relaunch tests that distrust saved percentage and revalidate authoritative stores.
- [ ] T051 Add product-level optional failure copy and Retry/Continue actions; prohibit raw paths,
  storage terminology, or manual cleanup instructions in every user-visible error.
- [ ] T052 Verify 640×520 and smaller visible-height layout/scroll behavior.

## Milestone H - End-to-end verification and handoff

- [ ] T053 Run selection, profile, asset, Live, capture, onboarding, config migration, and Models
  targeted Swift tests.
- [ ] T054 Run the full `MuesliTests` suite and release build with production dependency paths.
- [ ] T055 Manually test fresh and resumed onboarding for meetings, dictation, voice notes, and
  combined use cases.
- [ ] T056 Manually test multiple installs, explicit choice, remove selected with one/several
  remaining, remove last, interrupted setup, update rollback, deprecation/retirement, and relaunch.
- [ ] T057 Record short meetings using current Live-capable and Final-only catalog descriptors and
  verify captured profile, Homan Whisper parity, generic capability gates, and one-time overrides.
- [ ] T058 Verify no implicit download/network request while recording/finalizing/recovering.
- [ ] T059 Build and install a Developer ID-signed Release app only after all tests pass; verify
  bundle identity, signature, runtime launch, and retained settings.
- [ ] T060 Update user documentation/release notes without claiming quality changes or changing app
  version unless separately requested.

## Dependency order

- Characterization blocks migration changes.
- Capabilities and pure selection block runtime/UI changes.
- Concrete capture and historical compatibility block shared Live selection.
- Durable preparation plan blocks onboarding UI; do not append diarization to the current
  single-backend cancellation flow.
- Tests and signed local installation block any commit/push/release request.

## Explicit non-tasks

- deleting `.automatic` from persisted evidence or the core enum;
- selecting or shipping a new FluidAudio/model revision or changing quality parameters merely to
  exercise the new update architecture;
- downloading every diarization model by default;
- enabling Final or Live merely because a model downloaded;
- adding a separate Live model picker;
- server-side diarization or Homan Whisper protocol changes;
- diarizing microphone audio;
- speaker naming/biometrics;
- changing release version or publishing an installer in this planning task.
