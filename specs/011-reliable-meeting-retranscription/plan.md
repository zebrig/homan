# Implementation Plan: Reliable Meeting Re-transcription

**Branch**: `experiment/homan-0.8.3-retranscription-aec`
**Date**: 2026-08-22
**Spec**: [spec.md](spec.md)

## Summary

Repair the ordering defect in `MeetingRecordingUnitResolver`: validate and prefer a complete
canonical source bundle before considering the channel-separated playback file. Preserve separated
playback as a safe fallback and use a degraded canonical bundle when separated playback is
unavailable; prefer it over legacy mixed playback to retain known roles. Reuse the
existing schema-2 raw rendering/AEC pipeline without changing capture or storage. Add optional
processing provenance, a truthful audio-processing phase for both post-call and re-transcription,
actual AEC outcome metadata, and focused regression tests.

## Technical Context

**Language/Version**: Swift 5.9
**Primary Dependencies**: Foundation, AVFoundation, MuesliCore, existing LocalVQE/DTLN AEC adapters
**Storage**: Existing SQLite recording/source-bundle rows, JSON processing metadata, ALAC/CAF source
epochs, channel-separated WAV/M4A playback
**Testing**: Swift Testing via SwiftPM, serial authoritative execution, UUID-scoped temporary support
directories
**Target Platform**: macOS 14+ arm64
**Project Type**: Native macOS menu-bar/desktop application
**Performance Goals**: No change to recording or dictation latency; additional AEC work is permitted
only after an explicit Re-transcribe action
**Constraints**: No user-data migration, no source mutation, no GUI test side effects, no release or
push; local installation is a post-validation deployment step explicitly requested by the owner
**Scale/Scope**: One resolver, narrow progress/provenance fields, focused tests; no audio-format redesign

## Constitution Check

- **Canonical audio integrity**: PASS. Resolution opens canonical payloads read-only and delegates
  validation to `MeetingRecordingBundle.load`.
- **Source-role integrity**: PASS. Schema-2 processing retains microphone/system identity; fallback
  uses recorded `source_layout` or legacy unknown.
- **Backward compatibility**: PASS. Schema 1, playback-only, legacy mixed, imported files, and old
  optional metadata remain supported.
- **Safe degradation**: PASS. Complete bundle → complete separated playback → usable degraded bundle is an
  explicit order; no audio is deleted or rewritten.
- **Test isolation**: PASS. All new fixtures inject temporary support/database roots.
- **Minimal runtime surface**: PASS. No capture, device switching, dictation, player, persistence
  writer, or retention changes. The existing read-only channel extractor gains only a bounded
  cancellation checkpoint used by re-transcription.
- **Observability**: PASS. Stored provenance distinguishes the chosen input; post-AEC diagnostics
  expose and persist actual processor readiness, frame use, and errors.
- **Whole-operation source lifetime**: PASS after merge hardening. Re-transcription acquires an
  atomic recording-ID read-lease set before detached source validation and retains it across every
  source-dependent suspension until the audio pipeline returns or fails. It then releases the set
  before summary generation; pipeline-local leases remain as defense in depth for direct callers.
- **Acoustic acceptance boundary**: PASS. The owner accepted the current channel-separated LocalVQE
  v1.2 behavior. No AEC parameter or model change is included. Additional speaker diarization stays
  explicitly unqualified by real-audio acceptance.
- **Release identity**: PASS after merge hardening. Public Homan 0.8.3 already exists, so the merged
  development line defaults to 0.8.4. This does not create a tag, installer, release, or publication.

Generic multi-unit processing prepares every source before changing the visible phase to ASR. That
truthful phase boundary can temporarily retain all prepared per-source WAVs at once and therefore
slightly increases peak temporary disk use and time to the first ASR result for multi-unit meetings.
The files remain lease-scoped, are removed on success/error/cancellation, and extraction checks for
cancellation between bounded 16,384-frame blocks.

Before merging, add an atomic multi-key read operation to the lease registry and acquire that set in
the controller before `MeetingRecordingUnitResolver` performs filesystem I/O. This closes the gap
where retention could delete a source during resolver, diarization-reuse validation, or model
preload. Add cancellation checkpoints around every Homan Whisper unit preparation; do not redesign
the processing phases or alter the accepted AEC implementation.

## Project Structure

```text
specs/011-reliable-meeting-retranscription/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── tasks.md
├── contracts/
│   └── source-selection.md
└── checklists/
    └── requirements.md

native/MuesliNative/
├── Sources/MuesliCore/
│   └── StorageModels.swift
├── Sources/MuesliNativeApp/
│   ├── MeetingProcessingMetadataFactory.swift
│   ├── MeetingRawAudioPostProcessor.swift
│   ├── MeetingRecordingUnitResolver.swift
│   ├── MeetingSession.swift
│   ├── MeetingTranscriptionTypes.swift
│   └── MuesliController.swift
└── Tests/MuesliTests/
    ├── DictationStoreTests.swift
    ├── MeetingRetranscriptionTests.swift
    └── MeetingTranscriptionPipelineTests.swift
```

**Structure Decision**: Extend the existing recording-unit resolver and provenance types. Do not
introduce a new service or duplicate bundle validation/AEC logic.

## Implementation Phases

### Phase 0 - Baseline and research

Confirm the production database shape (`source_layout` and source bundle on one row), the current
resolver ordering, the existing schema-2 AEC path, and the missing integrated test.

### Phase 1 - Contract and data model

Define deterministic source preference, fallback conditions, audio-source provenance values, and
optional metadata compatibility.

### Phase 2 - Resolver repair

Refactor resolution into:

1. construct the best playback fallback;
2. validate registered bundle metadata/version;
3. load and inspect current on-disk bundle state;
4. choose complete bundle;
5. otherwise choose usable role-separated playback;
6. otherwise retain a usable degraded bundle;
7. otherwise return the existing unavailable fallback.

The controller reads the small database row set on `MainActor`, then performs bundle validation and
digest I/O in a detached user-initiated task before returning to UI-owned processing state.

### Phase 3 - Provenance

Expose the resolved source kind from `MeetingRecordingUnitInput`. Store the source-kind summary and
requested AEC model in transcription processing metadata. Emit post-AEC processor/readiness/frame
diagnostics without paths or audio contents.

### Phase 4 - Regression tests

Add the exact production combination, degraded/missing/unsupported fallback, raw AEC invocation,
and old-metadata decode tests. Reuse existing fixtures and AEC injection points.

### Phase 5 - Verification and review

Run focused tests first, then the authoritative serial suite using a worktree-specific repository
scratch path. Review the diff for scope violations. Perform a separate independent code/spec audit
before committing.

### Phase 6 - Truthful progress and actual AEC evidence

Audit normal finalization and recovery alongside both re-transcription backend paths. Insert a
distinct post-capture audio-processing phase before ASR, pass the existing AEC snapshot through raw
pipeline results, persist a bounded aggregate, and render failure/zero-frame states without claiming
that the configured model succeeded. This phase changes observability only; it does not add an AEC
pass or change audio output.

### Phase 7 - Merge hardening

1. acquire all recording-ID read leases atomically before detached source validation;
2. retain the composite lease until source-dependent processing completes, then release it before
   summary generation;
3. keep pipeline-local leases for non-controller callers;
4. add Homan Whisper multi-unit cancellation checkpoints;
5. verify atomicity, async lease lifetime, cancellation cleanup, the complete serial suite, a release
   build, and a real merge with `main` that preserves its CoreAudio lifecycle commit.
6. advance the default development build identity from the already-published 0.8.3 to 0.8.4 without
   publishing or installing it.

### Phase 8 - Experimental branch reconciliation

Reconcile every local branch that is not a graph ancestor of `main` before treating the integration
as complete. Patch-equivalence confirms that `feature/window-close-behavior`,
`fix/all-meetings-record-action`, `fix/meeting-detail-header-layout`, and
`fix/whisper-source-language-detection` are already represented in `main` and must not be merged a
second time.

The `experiment/post-v0.8.2-coreaudio` branch contains one intentionally excluded patch:
`15d5ca76` (`Experiment with idle audio graph invalidation`). It is a default-off route-switching
hypothesis with an explicit flag-off/flag-on hardware acceptance gate that has not been completed.
The accepted channel-separated LocalVQE result does not validate this unrelated dictation graph
lifecycle treatment. Keep the experiment outside `main` until its route-cycle and first-dictation
latency gates are measured; do not mistake the branch's non-ancestor status for lost production
functionality.

## Complexity Tracking

No constitutional violations. Optional provenance fields avoid a database migration; the resolver
reuses existing validation and processing types.
