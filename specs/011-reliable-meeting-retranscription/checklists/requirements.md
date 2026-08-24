# Requirements Checklist: Reliable Meeting Re-transcription

**Purpose**: Verify specification completeness and implementation readiness
**Created**: 2026-08-22
**Feature**: [spec.md](../spec.md)

## Scope and correctness

- [x] CHK001 The production defect and exact metadata combination are stated.
- [x] CHK002 Canonical, separated playback, and legacy source meanings are distinct.
- [x] CHK003 Complete, degraded, invalid, missing, and unsupported bundle behavior is defined.
- [x] CHK004 Schema-1 and schema-2 AEC semantics are distinct.
- [x] CHK005 Imported-file behavior is explicitly separate.
- [x] CHK006 Audio formats, capture, dictation, playback, and retention are out of scope.

## Safety and compatibility

- [x] CHK007 Resolver behavior is read-only.
- [x] CHK008 Existing playback remains a fallback.
- [x] CHK009 Old metadata compatibility requires no migration.
- [x] CHK010 Test isolation from installed Homan data is mandatory.
- [x] CHK011 Rollback requires only reverting feature commits; no data rollback is needed.

## Verification

- [x] CHK012 Production-shaped regression coverage is required.
- [x] CHK013 AEC invocation is verified with an injected processor and reference audio.
- [x] CHK014 Fallback and legacy attribution are independently testable.
- [x] CHK015 Focused and full serial test gates are documented.
- [x] CHK016 Independent review is required before commit.
- [x] CHK017 Normal finalization and re-transcription progress semantics are both specified.
- [x] CHK018 Requested AEC configuration and actual execution evidence are distinct.
- [x] CHK019 Successful, unavailable, zero-frame, no-reference, and degraded display states are testable.
- [x] CHK020 Mic-only and mixed-success multi-unit AEC evidence cannot be reported as full success.
- [x] CHK021 Generic multi-unit and legacy progress transitions are independently testable.
- [x] CHK022 Whole-operation source lifetime begins before filesystem validation and spans every
  asynchronous preload/processing step.
- [x] CHK023 Multi-recording lease acquisition is explicitly atomic and failure-safe.
- [x] CHK024 The accepted channel-AEC result and unaccepted additional speaker-diarization quality
  are not conflated.
- [x] CHK025 Merge hardening cannot change the selected AEC model or its parameters.
