# Feature Specification: Unified Model Download Center

**Implementation Branch**: `feature/0.8.4-unified-model-downloads`

**Base**: Homan 0.8.4 candidate `402e27d8`

**Created**: 2026-08-24

**Status**: Implementing

**Input**: "Adapt the stabilized upstream downloader into Homan and provide one durable,
standardized download center, one progress tracker, and one notification surface for every model.
Ship it additively in the existing 0.8.4 candidate; install only on this Mac and publish no
installer without separate owner approval."

**Related requirements**:

- [Homan product network and model ownership](../003-homan-product-rebrand/tasks.md) (`T121`)
- [Diarization model selection and onboarding](../010-diarization-model-selection-onboarding/spec.md)
- [Deferred upstream downloader decision](../008-post-081-upstream-hardening/spec.md)

## Scope

Homan currently has independent download implementations and independent UI state for ASR,
post-processing, summarization, AEC, live-caption, and speaker-separation assets. A path existing on
disk is often treated as a completed installation. Onboarding, Models, and Sidebar can therefore
show mutually inconsistent states after interruption or relaunch.

This feature introduces one Homan-owned model asset registry, one authoritative actor-owned job
center, one resumable transfer kernel, one atomic package installer, and one observable progress
stream. Runtime-specific loaders remain adapters: downloading a model and preparing it for Core ML,
llama.cpp, LiteRT, FluidAudio, WhisperKit, or a diarization engine are distinct typed phases of one
job, not separate UI implementations.

The implementation is additive to the current 0.8.4 candidate. It MUST NOT rewrite, squash, replace,
or silently discard any existing 0.8.4 commit. It MUST NOT create or publish a DMG, GitHub tag,
release, or public branch without a later explicit owner command.

## User Scenarios & Testing

### User Story 1 - Truthful progress everywhere (Priority: P1)

As a user, I want onboarding, Models, Sidebar, and any download popover to show the same current
state so that a partially downloaded model is never presented as ready or active.

**Acceptance Scenarios**:

1. **Given** Parakeet has only a partial directory, **When** Homan launches, **Then** every surface
   reports an incomplete/resumable download and no surface reports `Active` or `Downloaded`.
2. **Given** one job is observed by onboarding and Models, **When** bytes arrive, **Then** both
   surfaces receive snapshots from the same job and no duplicate transfer starts.
3. **Given** a selected model is not ready, **When** its card renders, **Then** selection and
   installation are shown as separate facts and dictation remains gated.
4. **Given** a job changes from download to verification, installation, preparation, or ready,
   **When** any surface renders, **Then** it uses the typed phase rather than parsing status text.

### User Story 2 - Resume after interruption or relaunch (Priority: P1)

As a user, I want a model download to continue from verified partial bytes after network failure,
cancel, onboarding navigation, or application relaunch.

**Acceptance Scenarios**:

1. **Given** 22 MB of a 450 MB model are present, **When** Homan relaunches, **Then** the center
   reconciles the persisted job, displays the recovered byte count, and resumes with HTTP Range.
2. **Given** the server ignores Range, changes ETag, or returns 416, **When** resume is attempted,
   **Then** Homan safely restarts only the affected file and never certifies stale bytes.
3. **Given** one observer goes away, **When** another observer still needs the job, **Then** the
   shared transfer continues.
4. **Given** the user explicitly pauses a job, **When** Homan relaunches, **Then** it remains paused
   until an explicit or previously authorized automatic-resume policy starts it.

### User Story 3 - Atomic and validated installation (Priority: P1)

As a user, I want a failed download or update to leave the last working model usable.

**Acceptance Scenarios**:

1. **Given** a valid installed package, **When** an update fails during download, verification,
   staging, or final promotion, **Then** the previous package and completion marker remain valid.
2. **Given** a file has the wrong size or SHA-256, **When** verification runs, **Then** the job fails
   and no ready marker is published.
3. **Given** the manifest contains traversal, symlink escape, mutable destination conflict, or an
   unapproved redirect, **When** download starts, **Then** Homan fails closed before promotion.
4. **Given** all files and runtime validation succeed, **When** promotion commits, **Then** a single
   versioned completion marker makes the package ready atomically.

### User Story 4 - Add models through one descriptor contract (Priority: P1)

As a developer, I want a new model to use existing transfer, progress, retry, persistence, install,
and deletion behavior by registering one descriptor rather than creating another downloader.

**Acceptance Scenarios**:

1. **Given** a single-file model descriptor containing stable ID, immutable version, URL, size,
   SHA-256, license, destination, and validator, **When** it is registered, **Then** the center can
   download, observe, resume, verify, install, and remove it without model-specific network code.
2. **Given** a multi-file descriptor, **When** registered, **Then** all files participate in one
   package-level job and readiness is published only after every requirement succeeds.
3. **Given** a runtime needs compilation or warmup, **When** transfer finishes, **Then** its adapter
   reports `preparing` without inventing a second download state.
4. **Given** a bundled or cloud-managed model, **When** registered, **Then** the same catalog can
   report `.bundled` or `.remote` availability without starting a transfer.

### User Story 5 - Safe migration of existing caches (Priority: P1)

As an existing user, I want the 0.8.4 upgrade to preserve working models and settings while no
partial legacy cache is trusted.

**Acceptance Scenarios**:

1. **Given** a legacy model loads successfully and has no partial state, **When** reconciliation
   runs, **Then** Homan may adopt it only after runtime validation and records a managed marker.
2. **Given** a legacy cache is partial or fails runtime validation, **When** reconciliation runs,
   **Then** it is not ready and the center offers repair/resume without deleting unrelated data.
3. **Given** Homan migrates to its owned cache, **When** migration fails, **Then** the legacy cache
   remains untouched and no shared FluidAudio or Hugging Face directory is deleted.
4. **Given** the user removes a managed model, **When** deletion commits, **Then** only the exact
   Homan-owned package and its job state are removed.

## Functional Requirements

- **FR-001**: `HomanModelDownloadCenter` MUST be the sole authoritative owner of mutable download
  jobs and typed progress snapshots.
- **FR-002**: A stable asset ID and manifest fingerprint MUST key sharing, persistence, resume,
  cancellation, and deletion; display names and selected-backend values MUST NOT be keys.
- **FR-003**: The center MUST persist enough state to reconcile partial files and last terminal
  state after application relaunch. Persisted percentages are hints only; bytes and markers on disk
  are revalidated.
- **FR-004**: The transfer kernel MUST support bounded concurrency, retry with backoff, Range/ETag
  resume, HTTP validation, disk-space checks, size validation, optional SHA-256, path containment,
  and cancellation that preserves resumable partials.
- **FR-005**: A package MUST be downloaded into an owned staging revision, verified there, and
  atomically promoted with rollback. Files MUST NOT be progressively mixed into a ready package.
- **FR-006**: `selected`, `installed`, `ready`, `loading`, and `active in memory` MUST remain
  separate state dimensions. Only validated `ready` assets may be activated or warmed.
- **FR-007**: Onboarding, Models, Sidebar, Settings badges, and the future Downloads popover MUST
  observe the same typed snapshots; view-local dictionaries or persisted scalar percentages MUST
  not be authoritative.
- **FR-008**: The initial production migration MUST cover Parakeet v2/v3 end-to-end and remove all
  direct `AsrModels.downloadAndLoad` use from those paths.
- **FR-009**: The generic contract MUST support ASR, post-processing, summary LLM, AEC,
  live-caption, and diarization packages without importing runtime frameworks into the transport
  layer.
- **FR-010**: Existing model-specific runtime loading, inference gates, capture-active guards, and
  unload behavior MUST remain intact behind adapters.
- **FR-011**: Homan MUST use an owned cache root. New managed code MUST NOT read, write, or delete
  shared FluidAudio, WhisperKit, or Hugging Face caches except through an explicit, read-only,
  validation-first legacy migration adapter.
- **FR-012**: Release manifests MUST identify an immutable revision and exact allowed files, sizes,
  hashes, and license metadata. A raw mutable URL alone is insufficient for a ready installation.
- **FR-013**: The model session MUST not use ambient cookie, URLCredential, shared cache, proxy,
  token, or Hugging Face home configuration. Redirects MUST be explicitly bounded and credentials
  MUST never be forwarded across origins.
- **FR-014**: Starting recording, Final processing, recovery, Re-transcribe, or Re-diarize MUST NOT
  implicitly download a missing model. Only explicit model preparation surfaces may authorize it.
- **FR-015**: Tests MUST use injected sessions and isolated directories and MUST NOT download real
  models, open floating bars, mutate the installed Homan profile, or touch shared model caches.
- **FR-016**: Owner-signed local installation MUST occur only after targeted and serial full-suite
  gates pass. Publication remains a separate explicit action.

## Non-Goals

- changing ASR, AEC, diarization, or transcription quality;
- changing recording, audio routing, CoreAudio, or meeting-processing architecture;
- automatically downloading every available model;
- deleting legacy shared caches during 0.8.4 migration;
- publishing a DMG, tag, branch, release, or installer;
- changing the 0.8.4 marketing version.

## Success Criteria

- **SC-001**: A deterministic interrupted-Parakeet fixture reproduces the 0.8.3/0.8.4 failure and
  passes with truthful non-ready state, recovered bytes, and resume.
- **SC-002**: One simulated transfer observed from at least three UI consumers results in one
  network job and identical snapshots.
- **SC-003**: Every injected failure point before atomic promotion preserves a seeded last-known-
  good package byte-for-byte.
- **SC-004**: No new model downloader or view-owned progress loop is needed for a synthetic
  single-file or multi-file model descriptor.
- **SC-005**: Targeted tests, serial full suite, release build, signature verification, and local
  owner-signed installation succeed without modifying the user's Homan data or authorization.
