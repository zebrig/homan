# Tasks: CoreAudio Lifecycle Hardening

**Input**: Design documents from `specs/009-coreaudio-lifecycle-hardening/`
**Prerequisites**: `spec.md`, `research.md`, `data-model.md`, `plan.md`

## Phase 1: Specification and review

- [x] T001 Create feature specification and measurable non-regression criteria.
- [x] T002 Record code-proven findings separately from hardware-only assumptions.
- [x] T003 Define candidate, lease, lifecycle event, and experiment data models.
- [x] T004 Run an independent adversarial review of the complete Spec 009 package.
- [x] T005 Apply review findings and mark the specification approved for implementation.

## Phase 2: Observability and regression proof

- [x] T006 [P] [US3] Add privacy-safe lifecycle telemetry in
  `native/MuesliNative/Sources/MuesliNativeApp/AudioLifecycleDiagnostics.swift`.
- [x] T007 [US3] Emit mic handoff start/return/timeout/supersede/promotion/detachment events from
  `native/MuesliNative/Sources/MuesliNativeApp/MeetingMicRecording.swift`.
- [x] T008 [US3] Emit tap/aggregate/IOProc teardown results from
  `native/MuesliNative/Sources/MuesliNativeApp/CoreAudioSystemRecorder.swift`.
- [x] T009 [US1] Add a regression test in
  `native/MuesliNative/Tests/MuesliTests/RouteAwareMeetingMicRecorderTests.swift` that blocks one
  start, issues 100 route changes, and proves the current implementation is unbounded.
- [x] T010 Run T009 before the fix and record the expected failure.

## Phase 3: Bounded microphone handoff

- [x] T011 [US1] Add physical start phase and successful `startReturned` handling in
  `native/MuesliNative/Sources/MuesliNativeApp/MeetingMicRecording.swift`.
- [x] T012 [US1] Keep a physically starting candidate attached across logical timeout and newer route
  requests.
- [x] T013 [US2] Implement latest-desired continuation after a superseded start physically returns.
- [x] T014 [US1] Preserve retry bounds but prevent retry before the previous physical start returns.
- [x] T015 [US1] Add an exclusive process-local replacement-start gate plus cancellable
  latest-desired waiter/wakeup across pause/resume and MeetingSession instances.
- [x] T016 [US2] Preserve active recorder forwarding until first accepted candidate signal.
- [x] T017 [US2] Preserve existing same-ID refresh and explicit health recovery behavior without new
  route revision plumbing.
- [x] T018 Update blocked-prepare/start, signal-before-return, rapid-route, timeout/late-return,
  pause/resume, two-recorder gate, stop, discard, deallocation, retry, and stale-work-item tests.
- [x] T032 Verify gate waiting does not consume attempts or start a timeout, owner deallocation
  schedules candidate cancel, and two wake-all waiters eventually acquire across two releases.

## Phase 4: Verification

- [x] T019 Run `RouteAwareMeetingMicRecorderTests` with repository-local SwiftPM scratch path.
- [x] T020 Run audio route controller, meeting microphone recovery, meeting ownership, and
  CoreAudioSystemRecorder focused suites.
- [x] T021 Run the broader Swift suite or repository-approved shards and document pre-existing
  failures separately.
- [x] T022 Verify clean worktree scope contains only Spec 009 and intended audio/test changes.
- [x] T023 Run a second adversarial code review focused on deadlocks, latency, and callback races.

## Phase 5: Hardware-gated global-tap experiment

- [x] T024 [US4] Add a dev-lane-only switch that disables output-triggered global-tap rebuild without
  changing owner Homan behavior.
- [ ] T025 [US4] Build and launch a named dev lane using repository scripts and isolated data.
- [ ] T026 [US4] Execute the Built-in/AirPods/Teams/virtual-device/reconnect matrix from
  `quickstart.md`.
- [ ] T027 [US4] Record callback gap, non-zero signal, format, resource, and audible-switch results.
- [ ] T028 [US4] If every hardware criterion passes, prepare a separate reviewed listener-removal
  change with staged/kill-switch rollout; otherwise revert the experiment switch and retain current
  behavior.

## Dependencies and execution order

- T004-T005 gate all code changes.
- T006-T010 establish observability and the failing proof before T011-T018.
- T011-T018 and T032 must complete before focused verification.
- Hardware tasks T024-T028 are independent of shipping microphone hardening.
- Permission polling cleanup is deferred to a separate specification and is not part of Spec 009
  completion.
- Production output-listener removal is forbidden unless T026-T027 pass completely.

## Verification evidence (2026-08-18)

- Before the fix, the existing 27-test route-aware suite passed. The new blocked-start regression
  then failed as intended: 100 later route updates produced 101 factory calls instead of one.
- After the fix, the final focused route-aware and CoreAudioSystemRecorder run passed 40/40.
- The final adjacent route/recovery/ownership/CoreAudio run passed 40/40; the
  later broad audio shard exercised 155 tests across 14 suites. All touched and lifecycle-adjacent
  suites passed. One unrelated pre-existing/environmental `MeetingRawAudioCapture` ALAC compaction
  test reported four issues because AVFAudio returned `ExtAudioFileOpenURL`/format-conversion OS
  errors; no raw-capture source was modified by Spec 009.
- An attempted all-package run produced no assertion failure but did not terminate after extended
  silence and was interrupted rather than misreported as passing. The bounded focused and broad
  audio shards above are the recorded verification result.
- Hardware tasks T025-T028 remain gated: no named lane was installed/launched, no Teams/AirPods
  matrix was claimed, and production listener behavior remains enabled.
- The independent implementation review found no critical/high defect and approved the mic state
  machine, process-wide gate, teardown diagnostics, and exact A/B/C dev-lane experiment guard. It
  explicitly did not approve production listener removal without the hardware matrix.
