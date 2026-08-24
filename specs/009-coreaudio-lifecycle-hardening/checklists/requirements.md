# Requirements Checklist: CoreAudio Lifecycle Hardening

**Purpose**: Gate implementation and release of the bounded audio-lifecycle change.
**Created**: 2026-08-18
**Feature**: [Spec 009](../spec.md)

## Scope integrity

- [x] CHK001 Initial active-recorder startup is unchanged by the first implementation slice.
- [x] CHK002 Active-recorder stop/finalization remains synchronous and unchanged.
- [x] CHK003 Raw meeting capture, AEC, chunk timing, ASR, and transcript behavior are untouched.
- [x] CHK004 No XPC/helper process or dual system-tap architecture is introduced.
- [x] CHK005 Production output-listener behavior remains unchanged before the hardware gate.

## Bounded lifecycle

- [x] CHK006 A logical timeout does not release or forget a physically starting worker.
- [x] CHK007 At most one physical replacement prepare/start exists process-wide, whether attached or
  detached.
- [x] CHK008 One hundred route updates cannot create a second start while the first is blocked.
- [x] CHK009 The worker strongly retains and releases its lease independently of owner lifetime.
- [x] CHK010 Pause/resume or a second recorder cannot create a second physical worker.
- [x] CHK011 Retries begin only after the previous physical start returned.
- [x] CHK029 A denied latest-desired waiter wakes after release and stop/pause cancels it.
- [x] CHK030 Blocked cleanup is logged and explicitly remains outside the bounded-start claim.

## Switching behavior

- [x] CHK012 The active recorder continues forwarding during replacement start.
- [x] CHK013 A superseded successful start does not wait for readiness timeout.
- [x] CHK014 A zero-only candidate cannot promote.
- [x] CHK015 Late callbacks from obsolete generations are rejected.
- [x] CHK016 A -> B -> A converges to A without promoting obsolete B.
- [x] CHK017 Health recovery can still force a meaningful same-route rebuild.
- [x] CHK018 Existing system-default stabilization remains 0.6 seconds.
- [x] CHK031 Promotion requires returned success, retained real signal, current generation, desired
  route, eligible disposition, and running session.
- [x] CHK032 Signal-before-return and timeout-before-late-success policies are deterministic.

## Diagnostics and privacy

- [x] CHK019 Start, return, timeout, supersede, promotion, cleanup, and detachment are logged.
- [x] CHK020 Every observed non-zero IOProc, aggregate, and tap teardown status is emitted.
- [x] CHK021 Logs contain no samples, transcripts, meeting titles, credentials, or user-content paths.
- [x] CHK022 Operation IDs and durations are sufficient to correlate a blocked worker with later route
  requests.
- [x] CHK033 Logs contain no device name or full hardware UID and explicitly mark OSLog privacy.

## Verification and release gate

- [x] CHK023 The regression test fails before and passes after the implementation.
- [x] CHK024 Focused meeting microphone and route suites pass.
- [x] CHK025 Broader Swift verification is recorded with pre-existing failures separated.
- [x] CHK026 A second adversarial code review finds no unresolved critical deadlock or callback race.
- [ ] CHK027 Hardware results include verified non-zero remote call audio before and after each route.
- [x] CHK028 Production listener removal, if any, is an independent commit and only follows a complete
  hardware pass.
- [x] CHK034 The handoff patch does not claim to bound initial starts or blocked cleanup/finalization.
- [x] CHK035 Owner deallocation after a blocked start still schedules candidate cancel and releases
  the start lease.
- [x] CHK036 Wake-all arbitration re-registers eligible losers and never waits synchronously for a
  lifecycle queue.
- [x] CHK037 Gate wait consumes no attempt and owns no readiness timeout.
- [x] CHK038 Cleanup diagnostics use begin/end correlation; no logical timeout is described as
  physical cancellation.
