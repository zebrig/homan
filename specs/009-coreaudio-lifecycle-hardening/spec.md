# Feature Specification: CoreAudio Lifecycle Hardening

**Feature Branch**: `009-coreaudio-lifecycle-hardening`
**Created**: 2026-08-18
**Status**: Slices 1-3 implemented and independently approved; hardware matrix pending
**Input**: Long-running Homan sessions can leave macOS audio routing degraded until `coreaudiod` or
the Mac is restarted. Harden the proven recorder-lifecycle accumulation path without redesigning the
meeting audio pipeline or slowing normal device switches.

## User Scenarios & Testing

### User Story 1 - Blocked replacement starts remain bounded (Priority: P1)

As a user who keeps Homan running across many calls and device changes, I need blocked replacement
microphone starts to remain bounded so one stuck CoreAudio call cannot be multiplied by later route
requests, pause/resume, or later replacement handoffs from another meeting.

**Why this priority**: The reported failure affects macOS-wide output switching and currently
requires a disruptive restart to recover.

**Independent Test**: Block a replacement recorder inside `prepare()` or `start()`, issue 100 route
requests across one or two route-aware recorders, and verify that exactly one replacement is
physically executing `prepare/start` process-wide.

**Acceptance Scenarios**:

1. **Given** microphone A is recording and replacement B is blocked in `start()`, **when** route
   requests B, C, and A arrive repeatedly, **then** no additional replacement starts until B returns.
2. **Given** a blocked handoff exists, **when** pause/resume or another MeetingSession requests a
   handoff, **then** it registers latest-desired work but does not create another physical worker.
3. **Given** B eventually returns after being superseded by C, **when** the process-wide start lease
   is released, **then** B is retired and the still-running owner's latest desired route C is
   automatically reconsidered without requiring another OS route notification.
4. **Given** a waiting recorder is stopped before the lease becomes available, **when** the current
   worker returns, **then** the stopped recorder does not create a candidate.

---

### User Story 2 - Normal switching stays fast and continuous (Priority: P1)

As a user recording a Teams call while moving between microphones or headsets, I need an ordinary
device switch to begin immediately and keep the previous microphone alive until the replacement is
actually usable.

**Why this priority**: A safety fix that adds latency or recording gaps to healthy switching would
trade one serious defect for a frequent regression.

**Independent Test**: Use recorders whose `start()` returns normally, perform A -> B -> C, and verify
that C starts without waiting for B's readiness timeout while A continues delivering audio until the
accepted replacement is promoted.

**Acceptance Scenarios**:

1. **Given** A is active, **when** the user explicitly selects B, **then** Homan schedules B without a
   new debounce beyond existing route-resolution work.
2. **Given** B has returned from `start()` but has not produced signal and C becomes desired, **when**
   the completion is processed, **then** B is retired without waiting for its two-second timeout and
   C starts next.
3. **Given** a candidate has not produced real audio, **when** it emits only zero samples, **then** it
   is not promoted over the active recorder.
4. **Given** the start gate is free and an ordinary healthy route request arrives, **then** candidate
   factory/prepare scheduling happens on the next lifecycle-queue turn without a new timer or
   debounce.

---

### User Story 3 - A degraded run is diagnosable (Priority: P2)

As the Homan maintainer, I need persistent lifecycle telemetry so a future incident identifies
whether Homan is blocked in start, cleanup, tap teardown, or whether the failure is external to the
Homan process.

**Why this priority**: Current teardown messages go to `stderr`; the installed app maps it to
`/dev/null`, so the most useful field evidence is lost.

**Independent Test**: Exercise successful, failed, timed-out, superseded, and stopped handoffs and
verify that structured lifecycle events contain generation, route identity, phase, duration, and
status without user content.

**Acceptance Scenarios**:

1. **Given** a handoff start or cleanup begins, **when** it starts or completes, **then** unified-log
   begin/end events record its lifecycle identity, duration, and outcome; a begin without a matching
   end identifies outstanding cleanup without pretending it was cancelled.
2. **Given** tap or aggregate teardown fails, **when** Homan handles the status, **then** the OSStatus,
   app-generated graph identity/role, and graph generation are emitted to diagnostics.
3. **Given** telemetry is collected, **then** it contains no transcript, microphone samples, API
   credentials, meeting title, or other user content.

---

### User Story 4 - Output-route handling is changed only with hardware evidence (Priority: P3)

As a user switching between built-in speakers, AirPods, and Teams audio, I need Homan's system-audio
capture to avoid unnecessary rebuilds without losing the remote side of my call.

**Why this priority**: The output listener predates the move from a device-specific tap to a global
process tap, but real CoreAudio behavior across Bluetooth and virtual devices is not proven by unit
tests.

**Independent Test**: In an isolated dev lane, compare the current build with a listener-disabled
experiment across the hardware matrix and measure callbacks, non-zero capture, format, capture gap,
thread count, and audible output-switch latency.

**Acceptance Scenarios**:

1. **Given** the listener-disabled global tap survives every required route switch, **when** the
   results meet the capture criteria, **then** the obsolete rebuild may be removed in an independent
   change.
2. **Given** any required route produces zero-filled, missing, or incompatible system audio,
   **when** the experiment is evaluated, **then** no listener removal ships from this specification.
3. **Given** dual-tap overlap has not been independently proven safe, **then** make-before-break
   system-tap switching remains out of scope.

### Edge Cases

- A candidate blocks in `prepare()` rather than `start()`.
- `start()` returns successfully after its logical timeout.
- A first audio callback races with a newer desired route.
- A meeting is stopped while a replacement is physically starting.
- The recorder object is released before a detached worker returns.
- Cleanup blocks after a successful promotion. This is diagnosed but not claimed bounded by this
  first slice.
- The user switches A -> B -> A while B is still starting; existing same-ID refresh semantics are
  preserved because the recorder boundary cannot yet distinguish a duplicate from a HAL revision.
- Default-input notification reports the same `AudioObjectID` after an AirPods profile change.
- A selected device disconnects and returns with the same UID but a different object ID.
- The system-audio tap continues callbacks but produces only zeros after an output switch.
- CoreAudio returns a teardown error for an object that has already disappeared.

## Requirements

### Functional Requirements

- **FR-001**: Homan MUST keep at most one replacement microphone recorder physically executing
  `prepare/start` process-wide across all route-aware meeting recorders.
- **FR-002**: A logical timeout MUST NOT be treated as physical cancellation of a blocking CoreAudio
  call.
- **FR-003**: While a replacement physically starts, later route requests MUST update the latest
  desired route without starting another replacement.
- **FR-004**: Every replacement worker MUST report that `start()` physically returned, including the
  successful path.
- **FR-005**: A successfully started but superseded candidate MUST be retired without waiting for its
  readiness timeout.
- **FR-006**: The active microphone MUST remain the recording source until an eligible candidate
  produces accepted non-zero PCM or native signal.
- **FR-007**: A candidate from an obsolete generation MUST NOT be promoted or forward late audio.
- **FR-008**: Existing bounded retries MUST run only after the previous physical start has returned.
- **FR-009**: Meeting stop, cancel, and pause MUST invalidate candidate callbacks without waiting for
  a blocked replacement start.
- **FR-010**: Every still-running replacement worker, attached or detached, MUST hold the exclusive
  process-wide start lease until physical `prepare/start` returns.
- **FR-011**: A denied lease acquisition MUST retain only the latest desired work, wake automatically
  after lease release, and be cancellable by stop/cancel/pause.
- **FR-012**: The initial active-recorder start and active-recorder finalization MUST remain unchanged
  in the first implementation slice.
- **FR-013**: The existing 0.6-second stabilization for system-default input events MUST remain
  unchanged.
- **FR-014**: Explicit same-route health recovery MUST remain available.
- **FR-015**: Existing same-ID route-refresh and health-recovery behavior MUST remain unchanged in
  this slice; route-source/revision deduplication is a separate follow-up.
- **FR-016**: Homan MUST emit structured unified-log events for microphone candidate start,
  timeout, promotion, supersession, cleanup, and detachment.
- **FR-017**: Homan MUST emit teardown results for process tap, aggregate, and IOProc
  resources without recording user content.
- **FR-018**: The current system-audio output listener MUST remain unchanged in production code until
  the hardware gate passes.
- **FR-019**: Any listener-disabled experiment MUST run in an isolated named dev lane and MUST NOT
  replace the installed owner Homan.
- **FR-020**: Permission probing MUST NOT be expanded as part of the microphone handoff slice.
- **FR-021**: Every implementation slice MUST be independently reviewable and revertible.
- **FR-022**: Candidate promotion MUST require all of: physical start returned successfully,
  accepted non-zero signal observed, candidate still desired, and session still running.
- **FR-023**: If readiness expires before physical start returns, a later successful return MUST
  retire that candidate; it MUST NOT reopen readiness or promote it.
- **FR-024**: If accepted signal arrives before physical start returns and readiness has not expired,
  the signal MUST be retained for promotion evaluation after successful return.
- **FR-025**: The worker closure MUST strongly retain and idempotently release its lease even when
  the owning recorder is stopped or deallocated; release MUST NOT depend on lifecycle callback
  delivery.
- **FR-026**: Recorder/global locks MUST NOT be held while invoking factories, recorder lifecycle
  calls, lease wakeups, or user callbacks.
- **FR-027**: If a worker result cannot be delivered to a live, current owner, the worker MUST
  owner-independently schedule `candidate.cancel()` and log cleanup; releasing the start lease alone
  is insufficient.
- **FR-028**: Gate release MUST asynchronously wake all registered waiters without waiting for any
  lifecycle queue. Each waiter MUST atomically retry acquisition, and every loser MUST re-register
  while still eligible.
- **FR-029**: Waiting for the gate MUST NOT create a candidate, increment `handoffAttempt`, or start a
  readiness timeout. Those actions occur only after successful acquisition for a concrete candidate.
- **FR-030**: Pausing an owner MUST cancel its waiter. If its candidate is already physically
  starting, pause makes that candidate permanently ineligible; resume may update desired work but
  MUST wait for the physical return before another attempt.
- **FR-031**: Waiter callbacks MUST capture owners weakly and stale waiter wakeups MUST be harmless.

### Key Entities

- **Desired Route Request**: Latest device ID plus recorder generation and force flag, preserving the
  currently available route information without inventing unavailable HAL revision semantics.
- **Handoff Candidate**: Replacement recorder with lifecycle identity, target route, request
  generation, physical-start state, and readiness state.
- **Handoff Start Lease**: Exclusive process-local accounting object that remains alive until one
  candidate's physical `prepare/start` work returns, regardless of owner lifetime.
- **Handoff Waiter**: Cancellable wake-up registration used when another replacement owns the
  process-wide start lease.
- **Lifecycle Event**: Privacy-safe structured diagnostic record for one audio operation.
- **Tap Experiment Result**: Hardware-route observation containing callback continuity, signal,
  format, resource counts, and capture-gap measurements.

## Success Criteria

### Measurable Outcomes

- **SC-001**: With a fake candidate blocked in `prepare()` or `start()`, 100 route updates, a
  pause/resume, and a second route-aware recorder produce exactly one entered replacement start
  worker, one unfinished lease, and no additional factory call until that call returns.
- **SC-002**: After a superseded successful `start()` returns, the latest route begins without waiting
  for the superseded candidate's readiness timeout.
- **SC-003**: Active microphone samples continue to be accepted throughout an ordinary replacement
  start and are rejected only after successful promotion.
- **SC-004**: Stop and discard return without waiting for a blocked replacement start; no hard latency
  promise is made for stopping the active recorder.
- **SC-005**: An attached or detached handoff lease remains visible process-wide until its worker
  returns; the latest eligible waiter wakes after release and a stopped waiter does not.
- **SC-006**: Existing route-aware meeting mic, health recovery, pause/resume, raw capture, AEC, and
  transition-state tests pass.
- **SC-007**: Lifecycle diagnostics include no user content and emit every observed non-zero teardown
  status; no claim is made that macOS unified logging retains records indefinitely.
- **SC-008**: Production output-listener behavior changes only after the complete hardware matrix
  shows no missing or zero-filled system audio and no worse capture gap.
- **SC-009**: When an owner is deallocated during a blocked start, releasing the worker causes an
  owner-independent candidate cancel attempt and leaves the process-wide start-lease count at zero.
- **SC-010**: With two eligible waiters, wake-all arbitration lets one acquire and makes the loser
  re-register; after the next release the second proceeds without another route event.

## Non-Goals

- Rewriting all Homan audio ownership around a new process-wide graph coordinator.
- Moving audio capture into an XPC/helper process.
- Making active meeting stop or audio-file finalization asynchronous.
- Guaranteeing a sub-200-ms stop for the active recorder.
- Running two global process taps concurrently or implementing dual-tap make-before-break.
- Changing AEC, raw meeting storage, chunk timing, ASR, or transcript behavior.
- Replacing AudioQueue with a different capture backend.
- Persisting raw CoreAudio object IDs between application launches.
- Automatically restarting `coreaudiod`.
- Distinguishing exact duplicate route notifications from reconnect/configuration revisions; the
  current `AudioObjectID?` boundary does not carry enough information.
- Bounding every CoreAudio cleanup/finalization call or every initial meeting start. This slice logs
  those operations so a broader resource budget is evidence-driven rather than assumed.

## Assumptions

- CoreAudio calls may block after a logical timeout and cannot be safely killed inside the process.
- The currently active recorder is usually usable while a replacement route starts; if it is not,
  a recording gap is unavoidable without broader process isolation.
- A unit-test proof of bounded logical work is necessary but insufficient for output-tap behavior.
- Only one Homan meeting is intended to own live meeting capture at a time.
- The current stable and fallback aggregate UID fix remains in place.

## Residual Risks

- Initial active-recorder startup remains synchronous and outside the replacement-start gate. A
  blocked initial start is not fixed by this specification.
- Active-recorder finalization and asynchronous candidate/old-active cleanup can block. This slice
  makes their duration and OSStatus visible but does not serialize all cleanup behind a global graph
  budget, because doing so can add route-switch latency and changes more ownership semantics than the
  code-proven replacement-start defect requires.
- Consequently, success means "no multiplication of unfinished replacement prepare/start calls",
  not "all CoreAudio lifecycle resources in Homan are globally bounded." If incident logs show
  cleanup accumulation, a separate bounded-retirement design and `blocked cleanup + many switches`
  test are required before claiming the broader guarantee.
