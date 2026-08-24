# Tasks: Unified Model Download Center

**Status**: Implementing

## Milestone A - Lineage and characterization

- [x] T001 Confirm the implementation branch starts at the tested 0.8.4 candidate `402e27d8`.
- [x] T002 Re-fetch and review current upstream downloader lineage through `d931836b`.
- [x] T003 Characterize the current partial-Parakeet false-ready path across Models, onboarding,
  Sidebar, and runtime warmup.
- [ ] T004 Add failing tests for a partial Parakeet directory, stale selected backend, relaunch,
  and contradictory surface state.

## Milestone B - Upstream-derived transfer kernel

- [x] T005 Port `ModelDownloadCoordinator`, `HuggingFaceModelManifestResolver`, and focused upstream
  tests with Homan attribution notes.
- [x] T006 Replace the default session with an injected no-cookie/no-credential/no-shared-cache
  configuration and explicit bounded redirect policy.
- [x] T007 Pin manifest identity to immutable revision material and support exact SHA-256 metadata.
- [x] T008 Preserve shared transfer, subscriber cancellation, Range/ETag resume, retry, disk-space,
  containment, content-length, checksum, and partial-retention behavior.

## Milestone C - Homan asset registry and installer

- [ ] T009 Add generic single-file/multi-file asset descriptors, license metadata, destination
  policy, required-artifact alternatives, and runtime adapter identity.
- [x] T010 Add one Homan-owned model-root resolver with injected test roots.
- [x] T011 Add package staging, verification, versioned marker, atomic promotion, rollback, orphan
  reconciliation, and last-known-good preservation.
- [ ] T012 Add generic package removal serialized against transfer, validation, loading, and use.

## Milestone D - Durable center and UI projection

- [ ] T013 Add actor-owned durable jobs and typed asset/job snapshots.
- [ ] T014 Add subscription sharing, retry/pause/resume/delete APIs, and launch reconciliation.
- [x] T015 Add one MainActor observable projection for SwiftUI.
- [ ] T016 Replace authoritative onboarding scalar progress, Models dictionaries, and Sidebar
  single-slot state with the projection while retaining compatibility decoding only.
- [ ] T017 Add one compact download status surface capable of showing multiple concurrent jobs.

## Milestone E - Parakeet vertical migration

- [x] T018 Register Parakeet v2/v3 exact package descriptors in the Homan-owned cache.
- [x] T019 Adapt FluidAudio loading to verified local folders and remove direct
  `AsrModels.downloadAndLoad` for Parakeet.
- [x] T020 Implement validation-first, non-destructive legacy FluidAudio cache adoption.
- [ ] T021 Gate `Active`, dictation test, preload, and warmup on center `.ready` state.
- [x] T022 Route onboarding, Models, Sidebar, deletion, and runtime progress through the same job.

## Milestone F - Regression and migration coverage

- [ ] T023 Cover fresh, partial, complete, corrupt, wrong-size/hash, ETag change, Range ignored,
  416, retry exhaustion, cancel, pause, relaunch, duplicate observer, and delete races.
- [x] T024 Prove a failed update/promotion preserves a seeded working package byte-for-byte.
- [ ] T025 Prove tests use isolated roots and make zero access to the installed Homan profile and
  shared FluidAudio/Hugging Face caches.
- [x] T026 Run existing onboarding, Models, runtime, diarization, meeting, and test-isolation suites.

## Milestone G - 0.8.4 handoff

- [x] T027 Perform focused code review against the spec and upstream later-fix lineage.
- [x] T028 Run the authoritative serial full suite and release build in repository-local caches.
- [x] T029 Commit the reviewed implementation as additive commit(s) above `402e27d8` without
  rewriting current 0.8.4 history.
- [x] T030 Install via `./scripts/install_homan_local.sh`, verify signature/version/commit/runtime,
  and launch only after the installer confirms no recording or processing is active.
- [x] T031 Record local manual-test instructions and observed result.
  - Observed 2026-08-24: owner-signed Homan 0.8.4 installed from implementation commit
    `2d670cbc`; host verification confirmed Developer ID authority, team `YH3W46ABZY`, hardened
    runtime, and the launched `/Applications/Homan.app` process.
  - Existing FluidAudio Parakeet v2/v3 packages were copied without modifying the legacy source,
    runtime-validated, atomically adopted under Homan's managed root, and recorded at the pinned
    revisions. The bundled CLI transcribed the same temporary synthetic speech fixture with both
    versions (exit 0); no user meeting was saved and no model download was required.
- [x] T032 Do not create/publish DMG, tag, push, public branch, or GitHub Release without a new
  explicit owner command.

## Follow-on migrations using the same center

- [ ] T033 Migrate WhisperKit and live-caption assets.
- [ ] T034 Migrate SenseVoice, Qwen, Nemotron, Cohere, and Indic ASR packages.
- [ ] T035 Migrate post-processors, Gemma summary/LiteRT, LocalVQE fallback, and diarization assets.
- [ ] T036 Remove each legacy downloader only after its model-specific parity and rollback tests
  pass; no big-bang deletion.
