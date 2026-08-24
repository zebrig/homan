# Data Model: CoreAudio Lifecycle Hardening

## DesiredRouteRequest

Represents the information already available at the meeting-recorder boundary.

| Field | Meaning |
|---|---|
| deviceID | Current-process CoreAudio object ID |
| generation | Monotonic request order used for latest-wins behavior |
| force | Preserves existing same-ID refresh or explicit health-recovery behavior |

Route UID/source/revision metadata is intentionally deferred. An `AudioObjectID?` alone cannot safely
distinguish duplicate delivery from a meaningful same-ID HAL change.

## HandoffCandidate

One replacement recorder created for a specific desired route and request generation.

| Field | Meaning |
|---|---|
| id | Unique candidate identity |
| generation | Meeting-recorder generation at creation |
| route | Target device identity |
| recorder | Existing `MeetingMicRecording` bundle |
| physical | starting, returnedSuccess, or returnedFailure |
| readiness | none, signalReady(first payload), or expired |
| disposition | eligible, superseded, paused, or stopped |
| workerLease | Lifetime accounting for physical prepare/start work |

### State transitions

```text
physical:    starting -> returnedSuccess | returnedFailure
readiness:   none -> signalReady | expired
disposition: eligible -> superseded | paused | stopped

promote iff returnedSuccess + signalReady + eligible + sessionRunning + stillDesired
```

A logical timeout changes readiness to `expired`; it does not end the start lease. A later success is
retired and never reopens readiness. Signal arriving before return is retained only if readiness has
not expired.

## ActiveRecorder

The only microphone recorder whose samples are forwarded as the active meeting source. It remains
active while a candidate starts and until an eligible candidate produces accepted signal.

## HandoffStartGate and HandoffStartLease

A process-local exclusive gate and lease owned by one physical replacement candidate
`prepare/start` execution.

| Field | Meaning |
|---|---|
| id | Lease identity |
| startedAt | Monotonic operation start |
| finished | Whether physical work returned |
| ownerDisposition | Attached, paused, stopped, or deallocated for diagnostics only |
| waiterID | Cancellable registration when acquisition is denied |

### Invariants

- At most one lease exists process-wide, including attached workers.
- The worker closure strongly captures the lease and releases it in `defer` when physical work
  returns; release does not depend on the owner or lifecycle callback.
- A logical timeout never finishes the lease.
- Finish/detach races and repeated release are atomic and idempotent.
- A denied acquisition keeps one latest-desired waiter per owner.
- Release snapshots/removes all waiters under the gate lock, then asynchronously invokes weak-owner
  wakeups with no lock held and without synchronously waiting for a lifecycle queue.
- Woken waiters atomically compete to acquire. Every eligible loser re-registers, so two waiters
  eventually proceed across two releases; stopped/deallocated owners do not re-register.
- Stop/cancel/pause unregisters its waiter; a stale wakeup must re-check generation and lifecycle.
- Gate waiting does not create a candidate, increment an attempt, or schedule a readiness deadline.
- If owner delivery is impossible after physical return, the worker independently schedules
  candidate cancellation before releasing its last strong candidate reference.

## MeetingMicHandoffState

| Field | Meaning |
|---|---|
| lifecycleState | idle, prepared, running, paused, failed, or stopping |
| active | Current forwarded recorder |
| pending | At most one handoff candidate |
| preferredRoute | Latest desired route |
| generation | Invalidates obsolete candidates and callbacks |
| handoffAttempt | Retry number for the current desired route |
| transitionPhase | stable, switching, retrying, or failed |
| startWaiterID | Optional registration awaiting the process-wide gate |

### Invariants

- There is at most one `pending` candidate.
- A pending candidate in physical `starting` phase is not removed solely because of timeout or a
  newer route request.
- A newer desired route supersedes pending promotion eligibility but does not create another worker.
- A candidate cannot promote unless physical, readiness, disposition, generation, route, and
  lifecycle gates all pass.
- Factories, CoreAudio lifecycle calls, gate wakeups, and user callbacks run with no state/gate lock
  held.
- Pause makes a physically starting candidate ineligible. Resume can retain new desired work but
  cannot create a worker until the old physical start returns.

## AudioLifecycleEvent

Privacy-safe unified-log record.

| Field | Meaning |
|---|---|
| subsystem/category | Homan audio lifecycle category |
| operation | handoffStart, handoffTimeout, promote, supersede, cleanup, tapDestroy, etc. |
| operationID | Candidate/lease/graph identity |
| generation | Recorder or tap generation |
| routeRole / ephemeral object ID | Non-content route identity; no device name or full hardware UID |
| durationMilliseconds | Monotonic elapsed time |
| status | success, error, timeout, detached, quarantined |
| osStatus | Numeric/fourCC CoreAudio result when present |

Success events use debug/info, timeout/detach use notice, and lifecycle/teardown errors use error.
Repeated waiting-state events are coalesced or rate-limited; audio callbacks are never logged.

## TapExperimentObservation

One route transition measured in a named dev lane.

| Field | Meaning |
|---|---|
| sourceRoute / destinationRoute | Built-in, AirPods, USB/display, or virtual-device identities |
| listenerEnabled | Baseline or listener-disabled experiment |
| callbackGap | Longest interval without tap callback |
| nonZeroBefore / nonZeroAfter | Whether real signal was captured around transition |
| sourceFormatBefore / sourceFormatAfter | Sample rate, channels, and format flags |
| thread/context deltas | Homan and CoreAudio resource changes |
| audibleSwitchResult | Whether macOS delivered output on the selected device |

No production decision is based on an observation that lacks non-zero call audio on both sides of
the route transition.
