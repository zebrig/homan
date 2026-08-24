# Implementation Plan: Unified Model Download Center

**Status**: Implementing

**Specification**: [spec.md](spec.md)

## Summary

Port the stabilized upstream transfer kernel and its regression tests, then place a Homan-specific
asset registry, durable job store, security policy, and package installer around it. Migrate
Parakeet v2/v3 first because it reproduces the current false-ready onboarding defect and exercises
multi-file Core ML packages, resume, runtime validation, selection gating, and all progress
surfaces.

The integration is a new commit chain on top of the existing 0.8.4 candidate. No existing feature
commit is removed or replaced.

## Technical Context

**Language**: Swift 5.9+

**UI**: SwiftUI/AppKit

**Runtime dependencies**: FluidAudio 0.15.2, WhisperKit, existing local model backends

**Persistence**: JSON job records and versioned completion markers below the Homan support/cache
root; filesystem bytes are authoritative during reconciliation

**Testing**: Swift Testing/SwiftPM, injected `URLProtocol`, UUID-scoped model roots, serial
authoritative full suite

**Upstream source reviewed**: `Muesli-HQ/muesli` `d931836b`; downloader chain beginning at
`9a824c87`, ASR integration `69940bdd`, lifecycle hardening `ab67aa7d`, legacy repair `34b49709`,
and later Qwen rollback fixes through `42a70bb3`/`83ebc023`/`77af9a69`.

## Architecture

```text
HomanModelAssetRegistry
  └─ HomanModelAssetDescriptor
       ├─ immutable package manifest
       ├─ owned destination policy
       ├─ license and display metadata
       └─ runtime adapter identifier
                     ↓
HomanModelDownloadCenter (actor, sole mutable source of truth)
  ├─ durable job reconciliation
  ├─ typed AsyncStream subscriptions
  ├─ sharing/cancel/retry/delete coordination
  └─ selection-independent availability snapshots
          ↓                         ↓
ModelDownloadCoordinator      HomanModelPackageInstaller
  upstream-derived kernel       staging/verify/swap/rollback
          ↓                         ↓
no-cookie bounded session     versioned completion marker
                     ↓
HomanModelRuntimeAdapter
  FluidAudio / WhisperKit / diarization / GGUF / LiteRT / bundled
                     ↓
Onboarding · Models · Sidebar · Downloads UI
```

## Design Decisions

### Transfer kernel versus product center

The upstream actor is retained as a low-level byte-transfer engine. It is deliberately not exposed
as application state. It knows manifests, destinations, partials, retries, and subscribers; it does
not know selection, product UI, licenses, runtime loaders, legacy cache migration, or Homan cache
ownership.

### Package-level staging

The upstream coordinator atomically promotes individual files. Homan adds a package installer:

1. resolve the exact revision manifest;
2. download every file into a stable hidden sibling used for Range/ETag resume;
3. validate sizes, hashes, required artifact alternatives, and write the structural marker there;
4. load that exact staging copy through the real runtime adapter;
5. atomically exchange staging and current with Darwin `RENAME_SWAP` (or atomically rename when
   no current package exists);
6. revalidate the promoted marker;
7. remove the swapped-out package only after promotion succeeds; roll back on any promotion error.

### Durable state and observation

The center stores job intent and terminal/error metadata atomically. On launch it enumerates
registered descriptors, completion markers, partials, staging directories, and job records before
publishing state. `AsyncStream<HomanModelAssetSnapshot>` provides typed subscriptions. SwiftUI uses
one MainActor observable projection; `NotificationCenter` strings and view-local task dictionaries
are not sources of truth.

### Process lifetime

The first migration reconstructs paused progress from durable partials after relaunch and resumes
with HTTP Range on the next authorized preparation action; it does not claim that an in-process
transfer continues while Homan is terminated. The app and bundled `homan-cli` serialize the same
package through one filesystem lock and share the same staging/state schema. This distinction is
internal and never creates a second UI state model.

### Cache ownership and legacy adoption

New packages live under the Homan-owned model root. Legacy shared caches are read-only candidates.
The Parakeet adapter may load and validate a legacy package, then copy it through staging into the
owned root and record exact installed bytes. A failed adoption leaves the source untouched. Homan
never deletes shared FluidAudio or Hugging Face caches.

### Rollout

The center and transfer tests land first without behavior changes. Parakeet v2/v3 then migrate as
one vertical slice. Other backends migrate by descriptor/runtime adapter after the center has passed
the fresh/partial/relaunch matrix. Legacy download functions remain only for non-migrated models and
are removed per-model after parity, never in a big-bang cleanup.

### 0.8.4 implementation boundary

The installable 0.8.4 slice completes the reusable transfer kernel, package-level staging and
rollback, Homan-owned root, typed process-wide observation, and Parakeet v2/v3 migration in both
the app and bundled CLI. Parakeet is the proof model: onboarding, Models, Sidebar, runtime loading,
resume, explicit cancellation, and deletion consume the same coordinator snapshots.

This slice deliberately does not claim the follow-on migrations are complete. Existing view-local
task dictionaries remain compatibility plumbing for model families that have not moved yet, and a
general persisted terminal-job catalog/multi-download popover remains open. Transfer bytes, ETags,
manifest fingerprint, package marker, and stable staging directory are durable; in-memory terminal
snapshots are reconstructed when preparation resumes rather than persisted as a second source of
truth. Tasks T033-T036 track per-model migration and legacy downloader removal.

## Risk Controls

- No changes to audio capture, CoreAudio, AEC, meeting storage, or transcription semantics.
- No real network in tests and no UI automation that opens the production floating bar.
- Old working models are not deleted during migration or failed update.
- No mutation of `/Applications/Homan.app` until every required gate passes.
- Owner-signed installer performs the only final application replacement.
- No GitHub/tag/DMG command belongs to this plan.

## Verification Gates

1. Core transfer and manifest unit tests.
2. Homan package installer rollback and marker tests.
3. Partial Parakeet, restart reconciliation, and shared-subscriber tests.
4. Models/Onboarding/Sidebar projection tests.
5. Existing model/runtime/onboarding targeted suites.
6. Serial full `MuesliTests` suite with repository-local scratch path.
7. Release build and owner-signed local install.
8. Manual fresh/partial model observation by the owner before any installer publication.
