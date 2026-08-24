# Implementation Plan: CoreAudio Lifecycle Hardening

**Branch**: `009-coreaudio-lifecycle-hardening` | **Date**: 2026-08-18 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/009-coreaudio-lifecycle-hardening/spec.md`

## Summary

Remove the code-proven unbounded meeting-microphone handoff path while preserving the current active
recorder, raw meeting pipeline, AEC, initial start, and active stop. Add persistent lifecycle
telemetry and a process-local exclusive replacement-start gate. Treat the historical system-tap output listener
as an experiment-gated follow-up rather than part of the initial production change.

## Technical Context

**Language/Version**: Swift as pinned by the existing Swift package and Xcode project
**Primary Dependencies**: Foundation, CoreAudio, AudioToolbox, AVFoundation, Atomics, os
**Storage**: Unified logging only; no new persisted application data
**Testing**: Swift Testing via repository-local SwiftPM scratch paths
**Target Platform**: macOS versions currently supported by Homan
**Project Type**: Native macOS menu-bar application
**Performance Goals**: No new debounce on healthy explicit switching; superseded successful starts
must not wait for the readiness timeout
**Constraints**: CoreAudio start/stop calls may block; UI stop must not wait for blocked replacement
start; no user audio/content in logs
**Scale/Scope**: Meeting microphone routing and diagnostics, plus an isolated system-tap experiment

## Constitution Check

The cached Spec Kit preview contains only an unfilled constitution template, so repository policy is
derived from `AGENTS.md` and established `specs/` practice.

- PASS: Development remains in the `muesli` fork; product/repository names are not changed.
- PASS: Build/test caches remain below `muesli/.cache/swiftpm`.
- PASS: Production Homan is not replaced for experiments; named dev lanes are used.
- PASS: Owner installation, if later requested, uses only `scripts/install_homan_local.sh`.
- PASS: Slices are independently testable and revertible.
- PASS: Existing raw audio, AEC, meeting ownership, and signing behavior are preserved.
- PASS: Hardware-only claims are explicit gates, not assumed requirements.

## Project Structure

### Documentation

```text
specs/009-coreaudio-lifecycle-hardening/
├── spec.md
├── research.md
├── data-model.md
├── plan.md
├── quickstart.md
├── tasks.md
└── checklists/
    └── requirements.md
```

### Source Code

```text
native/MuesliNative/Sources/MuesliNativeApp/
├── AudioLifecycleDiagnostics.swift          # new privacy-safe lifecycle telemetry
├── MeetingMicRecording.swift                # bounded candidate state machine
├── AudioQueueInputRecorder.swift            # lifecycle event boundaries only if needed
├── AudioRouteController.swift               # preserve stabilization; minimal intent plumbing if needed
├── MeetingSession.swift                     # existing stop/start semantics retained
├── MuesliController.swift                   # existing route delivery retained unless intent metadata required
└── CoreAudioSystemRecorder.swift            # diagnostics; production route rebuild unchanged initially

native/MuesliNative/Tests/MuesliTests/
├── RouteAwareMeetingMicRecorderTests.swift
├── CoreAudioSystemRecorderTests.swift
└── AudioLifecycleDiagnosticsTests.swift      # only if testable surface is introduced
```

**Structure Decision**: Keep changes in the existing native application target. Do not introduce an
audio helper target, XPC service, or new package.

## Implementation Slices

### Slice 0 - Specification and adversarial review

- Approve the bounded scope, hardware gates, non-goals, and measurable acceptance.
- Review specifically for latency regressions, callback races, cross-session worker lifetime, and
  privacy of diagnostics.

### Slice 1 - Observability and regression proof

- Add a small unified-log lifecycle helper.
- Mirror microphone handoff lifecycle and CoreAudio teardown failures into structured logs.
- Add a failing test proving that 100 route changes can currently create multiple physical starts
  while the first remains blocked.
- Do not change production route behavior before the test demonstrates the defect.

### Slice 2 - Bounded latest-wins handoff

- Track physical result, readiness, and disposition independently.
- Keep a physically starting candidate attached after logical timeout or supersession.
- Record only the latest desired generation/route during that interval.
- Post a success completion from the worker and immediately retire a superseded successful start.
- Begin the latest desired handoff after the previous physical start returns.
- Preserve first-real-signal promotion, active recorder continuity, and bounded retry behavior.
- Add one exclusive process-wide replacement-start lease plus cancellable latest-desired waiters so
  pause/resume and a later MeetingSession cannot create another worker.
- Keep same-ID refresh behavior unchanged; do not add route-revision plumbing in this slice.

### Slice 3 - Focused verification

- Run route-aware recorder, audio route controller, meeting recovery, meeting ownership, and system
  recorder tests using repository-local scratch paths.
- Run the broader Swift suite or documented shards required by current repository practice.
- Compare deterministic happy-path scheduling against the pre-change test baseline.

### Slice 4 - Global-tap hardware experiment

- Build an isolated named dev lane with output-triggered restart disabled behind an experimental
  compile/runtime switch that cannot affect owner Homan.
- Exercise Built-in, AirPods, Teams call/virtual audio, reconnect, and rapid switching.
- Record callback continuity, non-zero signal, format, resource counts, and audible route behavior.
- Remove the production listener only in a separate reviewed change if every gate passes.

## Risk Controls

- No changes to active recorder stop or final media ownership.
- No changes to initial active recorder startup in the first implementation.
- No dual system taps or aggregate overlap.
- No blind destroy retry using numeric IDs.
- No automatic `coreaudiod` restart.
- Late callbacks remain generation-gated.
- Every behavior change begins with a failing deterministic test.
- Cleanup/finalization accumulation is logged and declared residual; this slice does not claim a
  global live-graph bound.

## Complexity Tracking

| Added complexity | Why needed | Simpler alternative rejected because |
|---|---|---|
| Successful physical-start completion event | Separates a returned start from readiness | First-buffer readiness can wait indefinitely in silence and delays A -> B -> C |
| Exclusive replacement-start lease and waiter | Closes per-owner, pause/resume, and cross-meeting races | A detached-only or per-recorder guard can be bypassed before detachment |
| Hardware experiment gate | Protects Teams/AirPods system capture | Unit tests cannot establish non-zero global-tap behavior on real routes |
