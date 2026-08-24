# Research: CoreAudio Lifecycle Hardening

## Evidence classification

### Proven from the current code

1. `RouteAwareMeetingMicRecorder` runs replacement `prepare/start` work on a concurrent queue.
2. A handoff timeout clears the logical pending candidate and schedules async cancellation, but it
   cannot stop a physical `AudioQueueStart` that is still running.
3. A new route request can then create another recorder instance while the earlier worker remains
   alive.
4. `AudioQueueInputRecorder.start()` holds its recorder lock while calling `AudioQueueStart`; cancel
   of that same recorder waits for the lock, but different recorder instances may block in parallel.
5. Existing tests prove UI-level stop/cancel responsiveness and stale callback rejection, not a bound
   on physical workers or CoreAudio resources.
6. `CoreAudioSystemRecorder` drops tap and aggregate IDs even when destroy reports a failure.
7. Installed Homan maps `stderr` to `/dev/null`, so current lifecycle diagnostics do not survive as
   actionable field evidence.
8. The default-output rebuild listener was added for a device-specific tap. The recorder later moved
   to a global process tap, but the listener remained.
9. Aggregate identity is bounded to two stable UIDs; process tap UUID creation is still per tap.
10. System-audio permission polling can create and destroy an additional test tap every 300 ms.

### Observed on the current machine but not proof of the defect

- A clean recent Homan process had 11 threads and approximately 105 MB resident memory.
- No active Homan private tap or aggregate was visible during the clean snapshot.
- A persistent `AudioTap-F473...` found in CoreAudio logs belonged to `corespeechd`, not Homan.
- The previous Homan process accumulated additional CoreAudio context IDs across microphone use, but
  the logs did not prove those contexts were leaked or responsible for output switching failure.

### Hardware-only questions

- Does the global process tap remain non-zero and correctly formatted across Built-in, AirPods, USB,
  display, and Teams virtual routes without a rebuild?
- Can output callbacks continue while carrying only zero-filled data after a route change?
- Does a process tap format change after a Bluetooth profile or sample-rate transition?
- Are two simultaneous private global taps and two private aggregates supported without duplicate
  or destabilizing behavior?
- Does successful recorder start imply granted TCC permission in not-determined, denied, and granted
  states?
- Which destroy errors mean a graph still exists, and which report an already-removed object?

## Decision: implement the smallest code-proven handoff bound

- **Decision**: Keep the current active/pending make-before-break model, but do not allow a logical
  timeout or route update to create another candidate while the earlier candidate physically remains
  in `prepare/start`.
- **Rationale**: This directly removes the proven unbounded-worker path without changing active
  recorder ownership, raw capture, AEC, initial meeting start, or active stop.
- **Alternatives considered**:
  - Full process-wide graph coordinator: rejected for this slice because it changes initial start,
    stop/finalization, fallback policy, and new-meeting UX without field proof that all are required.
  - Serializing every start and cleanup: rejected because one stuck cleanup can starve healthy
    switching and later meetings.
  - Continue abandoning timed-out workers: rejected because it preserves the accumulation defect.

## Decision: successful physical start is an explicit event

- **Decision**: Every candidate worker reports `startReturned` on success as well as failure.
- **Rationale**: Readiness and physical start completion are different. A superseded candidate whose
  start already returned can be retired immediately, allowing the latest desired route to proceed
  without waiting for signal or timeout.
- **Alternatives considered**:
  - Use first audio callback as start completion: rejected because quiet or zero-filled candidates
    can delay route convergence for the full readiness timeout.

## Decision: use an exclusive replacement-start gate

- **Decision**: Every replacement handoff worker must atomically acquire one exclusive process-local
  start lease before its factory/prepare/start work. The lease remains held whether its owner is
  attached, paused, stopped, or deallocated. A denied owner registers a cancellable latest-desired
  waiter and retries automatically after release.
- **Rationale**: A detached-only guard has races: two owners can acquire before either detaches, and
  pause/resume can replace an attached blocked worker. A single replacement-start gate closes both
  holes without moving initial active-recorder start or all audio graphs into a new coordinator.
- **Alternatives considered**:
  - Count every active/retiring physical graph globally: deferred because a logical fallback bundle
    owns multiple backend objects and the correct user-facing policy at a full budget is unresolved.
    Blocking all new switches behind a stuck cleanup could directly regress Teams-call switching.
  - Ignore cross-session accumulation: rejected because a permanently blocked worker would leak one
    more instance per meeting.

## Decision: preserve active-stop semantics

- **Decision**: Do not promise a universal stop latency or move active recorder finalization off the
  existing synchronous path.
- **Rationale**: Meeting stop consumes finalized files and raw-capture boundaries. A two-phase stop is
  a separate product and data-integrity change.
- **Alternatives considered**:
  - Async active stop: rejected for this scope because it can lose the recording tail or report a
    completed meeting before media finalization finishes.

## Decision: physical start and readiness are independent

- **Decision**: Track physical result, readiness, and disposition independently. Promotion requires
  `returnedSuccess + signalReady + eligible + running`.
- **Late-result policy**: A timeout before return makes the candidate permanently ineligible. A late
  success is cleaned up and, only if the desired generation is unchanged, follows the existing
  bounded retry delay. A superseded candidate instead re-evaluates the latest desired route. Signal
  observed before return is retained only when readiness has not expired.
- **Rationale**: Audio callbacks can race with `start()` return; treating them as a single linear
  phase can promote a recorder whose CoreAudio lifecycle call is still blocked.

## Decision: preserve same-ID behavior in this slice

- **Decision**: Do not add RouteIntent/revision plumbing in the replacement-start patch. Continue to
  treat the existing same-ID notification as a refresh and keep explicit health recovery.
- **Rationale**: The current recorder boundary only receives `AudioObjectID?`. It cannot safely tell
  an accidental duplicate from a Bluetooth profile/reconnect revision. Adding route-source/revision
  metadata is a useful but independent routing feature, not required to bound physical starts.

## Residual lifecycle risk

`stop/cancel/dispose` may also block, and the cleanup queue is concurrent. That is a credible but not
yet field-proven accumulation path. Spec 009 emits cleanup begin/end/error/duration so an incident can
separate it from the proven replacement-start multiplication. It deliberately does not claim a
global live/retiring graph budget. If evidence shows stuck cleanup accumulation, the next design must
bound retiring bundles and test `blocked cleanup + 100 switches`; it must also quantify the latency
cost before changing production ownership.

## Decision: persistent privacy-safe lifecycle logging

- **Decision**: Mirror critical lifecycle and teardown status into unified logging with operation,
  generation, object identity, duration, and status fields.
- **Rationale**: The installed application's stderr is not retained. A future failure must identify
  whether the Homan process or `coreaudiod` owns the degraded state.
- **Privacy boundary**: Never log meeting titles, transcript text, audio samples, filenames containing
  user content, credentials, or full configuration.

## Decision: gate output-listener changes on a dev-lane experiment

- **Decision**: Do not change production output-route behavior until a listener-disabled build passes
  the hardware matrix.
- **Rationale**: Code history strongly suggests the listener is obsolete, but unit tests cannot prove
  that Teams, AirPods, and virtual-device system audio remains non-zero.
- **Alternatives considered**:
  - Remove the listener immediately: rejected because losing the remote side of a recorded call is a
    worse regression than the suspected lifecycle churn.
  - Dual-tap make-before-break: rejected until simultaneous global taps, callback fencing, and
    teardown are proven on hardware.

## Review outcome incorporated

An independent adversarial review rated microphone hardening `REVISE`, system tap
`REVISE / hardware-gated`, and permission cleanup `REVISE`. This specification incorporates the
review by:

- adding explicit successful start completion;
- keeping the active recorder alive through promotion;
- accounting for all replacement-start work across MeetingSession and pause/resume boundaries;
- adding cancellable waiter/wakeup behavior;
- making physical result, readiness, and disposition orthogonal;
- removing the unsupported active-stop latency promise;
- retaining existing same-route refresh and explicit health recovery rather than inventing missing
  HAL revision metadata;
- rejecting dual-tap implementation without experiment;
- avoiding blind retries against stale numeric CoreAudio IDs.

After two revision passes, the independent reviewer approved Slices 1-3. The required next gate is
an adversarial review of the implemented code for lock ordering, callback races, latency, and owner
deallocation behavior.
