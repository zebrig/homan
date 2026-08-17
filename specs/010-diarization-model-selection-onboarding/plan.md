# Implementation Plan: Diarization Model Selection and Onboarding

**Status**: Planned; implementation has not started

**Specification**: [spec.md](spec.md)

## Summary

Separate three concepts that the current UI conflates:

1. **asset availability** — managed in Models;
2. **one shared concrete model preference** — resolved automatically or selected in Settings;
3. **whether Final or Live analysis runs** — retained as independent controls and overrides.

Add a capability-aware selection domain layer, remove user-facing `Automatic`, route both Final and
Live through the selected concrete profile, and extend onboarding with one optional diarization
item in a durable multi-item preparation plan. Preserve old `.automatic` evidence and run capture
semantics exactly.

## Technical Context

**Language/Version**: Swift 5.9

**UI**: SwiftUI and AppKit onboarding window

**Existing runtime**: FluidAudio 0.15.2 profiles, `MeetingDiarizationAssetStore`,
`MeetingDiarizationRuntime`, ASR-independent Final pipeline, provisional Sortformer Live engine

**Existing persistence**: JSON AppConfig, `onboarding-progress.json`, raw meeting manifest and
SQLite processing/evidence records

**Testing**: Swift Testing/SwiftPM, deterministic fake asset states, onboarding progress fixtures,
runtime/profile capture tests, signed Release smoke test

**Constraints**: no implicit model download from meeting processing; no new network path or
telemetry; old evidence must remain reproducible; capture wins over installation/inference; no app
version change in this feature plan

## Constitution Check

- **Source-role integrity**: PASS. Selection does not change microphone=`You` or system-only
  diarization.
- **Canonical audio integrity**: PASS. No audio format, capture, AEC, retention, or rendering change.
- **ASR independence**: PASS. The selected local profile remains outside all ASR providers,
  including Homan Whisper.
- **Deterministic recovery**: PASS with a hard requirement: every new run captures a concrete
  profile; current disk state is never consulted to reinterpret an existing run.
- **Backward compatibility**: PASS with a hard requirement: `.automatic` remains a historical
  decoder/resolver value and no completed evidence is rewritten.
- **No surprise download**: PASS. Onboarding and Models are explicit install surfaces; processing
  remains download-free.
- **Predictable UI state**: PASS through one selection resolver and one preparation-plan owner.

## Proposed Project Structure

```text
native/MuesliNative/
├── Resources/
│   └── DiarizationModels.json                    # bundled versioned descriptor catalog
├── Sources/MuesliCore/
│   └── MeetingDiarizationPolicy.swift            # keep legacy ID decoding
├── Sources/MuesliNativeApp/
│   ├── MeetingDiarizationProfiles.swift          # runtime/profile compatibility definitions
│   ├── MeetingDiarizationModelCatalog.swift      # open IDs + versioned descriptors/lifecycle
│   ├── MeetingDiarizationModelSelection.swift    # new pure resolver/coordinator
│   ├── MeetingDiarizationRuntime.swift           # existing authoritative assets
│   ├── MeetingLiveDiarizationSession.swift       # prepare captured selected profile
│   ├── MeetingSession.swift                      # capture/use capability
│   ├── MeetingRawAudioCapture.swift              # concrete Final snapshot
│   ├── Models.swift                              # compatible config accessors
│   ├── ModelsView.swift                          # download/status only
│   ├── SettingsView.swift                        # 0/1/N selection + Live message
│   ├── MeetingDetailView.swift                   # ready concrete one-time choices
│   ├── OnboardingModelPreparation.swift          # new durable plan/executor types
│   ├── OnboardingProgress.swift                  # schema 5
│   ├── OnboardingView.swift                      # optional speaker section/progress
│   ├── OnboardingWindowController.swift          # restore selection/plan
│   └── MuesliController.swift                    # ownership transfer/reconciliation
└── Tests/MuesliTests/
    ├── MeetingDiarizationSelectionTests.swift
    ├── MeetingDiarizationCatalogTests.swift
    ├── MeetingDiarizationProfileTests.swift
    ├── MeetingLiveDiarizationTests.swift
    ├── MeetingProcessingCaptureTests.swift
    ├── OnboardingModelPreparationTests.swift
    ├── OnboardingProgressTests.swift
    ├── OnboardingFlowTests.swift
    └── ModelsTests.swift
```

Names may be merged into an existing file when that reduces surface area, but the pure resolver and
durable preparation plan must remain independently testable.

## Design

### 1. Open model identity, versioned catalog, and capabilities

Do not make the UI/catalog depend on the closed legacy enum. Introduce an open stable ID wrapper and
a versioned descriptor:

```swift
struct MeetingDiarizationModelID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

struct MeetingDiarizationModelDescriptor: Codable, Sendable, Equatable {
    let id: MeetingDiarizationModelID
    let display: LocalizedModelDisplay
    let assetRevision: String
    let runtimeAdapterID: String
    let capabilities: MeetingDiarizationCapabilities
    let lifecycle: ModelLifecycle
    let onboarding: OnboardingAvailability
    let license: ModelLicenseDescriptor
    let replacementID: MeetingDiarizationModelID?
    let legacyAliases: [String]
}

struct MeetingDiarizationCapabilities: Codable, Sendable, Equatable {
    let supportsFinal: Bool
    let supportsLive: Bool
    let maximumRemoteSpeakers: Int?
}
```

The catalog is an app-bundled, versioned, schema-validated manifest decoded into domain values.
Executable adapters are selected only from a compile-time allowlisted registry; catalog content may
not load arbitrary code. It contains current entries, tombstones for legacy installed IDs, and
compatibility aliases. `.automatic` is a legacy alias, never a catalog model.

Current Offline quality and Stable up to 4 definitions become seed descriptors. Their names and IDs
are not referenced by Models, Settings, onboarding, or the generic resolver. Adding a model that
uses an existing runtime/asset adapter changes the manifest and descriptor tests, not those views.
A genuinely new engine adds one allowlisted adapter implementation/registration.

The existing `MeetingDiarizationProfileID` enum remains only as a compatibility bridge while old
AppConfig/run/evidence values are decoded. New catalog selection and new captures use the open
stable ID plus exact descriptor/profile revision.

### 2. Pure selection resolver

Implement one pure function from authoritative ready assets plus stored preference to a resolved
state. It returns both the selected concrete profile and why it was chosen.

Resolution order for any catalog size:

1. no ready profiles -> unavailable;
2. exactly one ready profile -> that profile (`soleReady`), regardless of a stale preference;
3. two or more ready profiles + a ready/selectable stored preference -> preserve it
   (`storedPreference`);
4. legacy alias + its historical target still ready -> materialize that target
   (`legacyAliasMigration`);
5. two or more ready profiles + no valid preference/alias target -> `choiceRequired`; do not choose
   by display name, position, capability, or a model-specific hard-code.

The coordinator persists a changed concrete preference in one AppConfig transaction. If the
resolved profile lacks Live capability, that same transaction normalizes the global Live speaker
default to Off. It then updates `AppState` once.

The resolver is idempotent: identical input produces no write and no UI churn.

### 3. Reconciliation ownership and triggers

`MuesliController` owns reconciliation and calls it only after authoritative transitions:

- startup asset validation completes;
- a Models or onboarding install/update reaches validated `.ready`;
- retry internally repairs setup and reaches `.ready`;
- remove commits and runtime/model ownership is released;
- a previously ready asset is found invalid during explicit validation.

SwiftUI views request/observe state but do not persist selection in `.onAppear` or render functions.
Concurrent callbacks are serialized on one actor/MainActor boundary; a generation token prevents an
older install refresh from overwriting a newer remove result.

### 4. Configuration compatibility

For the first patch, keep `meeting_final_diarization_profile` as the persisted JSON key. Introduce a
shared semantic accessor such as `resolvedMeetingDiarizationProfile` and mark the old Final-named
accessor as compatibility-only. This avoids dual-write and downgrade ambiguity.

Migration affects only the future global preference. It does not rewrite:

- raw recording manifests;
- processing run plans;
- profile snapshots/digests;
- diarization/attribution revisions;
- transcript presentation or summaries.

`MeetingDiarizationProfiles.resolve(.automatic)` remains unchanged for historical validation.
Future selection first bridges it to the historical target descriptor when available. Every path
that captures a new run must require either a concrete ready catalog descriptor or disabled state.

### 5. Models becomes an asset manager

Remove `isInUse`, accent borders based on configuration, `Used by Automatic`, and `Use for Final`.
Each card derives only from `MeetingDiarizationAssetStatus` and active install progress:

| Asset/lifecycle state | Card status | Action |
|---|---|---|
| absent | Not downloaded | Download |
| installing/downloading | Downloading n% | none/cancel only if existing model pattern supports it |
| validating/preparing | Setting up | none |
| ready | Downloaded | Remove |
| ready, newer revision exists | Update available | Update / Remove |
| setup failed | Needs attention | Retry / Remove when applicable |
| deprecated but supported | Legacy model | Remove; remains selectable if already selected |
| unsupported tombstone | No longer supported | Replace / Remove |

At section top:

> If one speaker model is downloaded, Homan selects it automatically. When multiple models are
> available, choose one in Settings.

Installation, update, and removal remain disabled during meeting start/recording. The asset store
owns staging, resume, cleanup, rollback, quarantine, atomic activation, and orphan collection. The
UI never mentions files, folders, paths, caches, markers, or manual storage remediation.

### 6. Settings owns model choice

Create a `Speaker separation model` row:

- **0 ready**: `No model downloaded` + `Open Models`; Final and Live controls are unavailable.
- **1 ready**: static concrete name + `Selected automatically — only downloaded model`; no picker.
- **2+ ready**: picker containing every ready/selectable descriptor.
- **2+ ready with no valid selection**: `Choose a model` is required; Final/Live stay unavailable
  until the user chooses.

Keep separate Final and Live enablement rows. Model selection does not toggle Final. A Final-only
model turns Live default Off and disables the Live control with the exact copy:

> This model doesn't support Live speaker diarization

Changing the shared model while no meeting is active affects future meeting captures only.

### 7. Runtime and run capture

Make Live preparation accept the captured profile ID rather than loading Sortformer by constant:

```swift
func prepare(profileID: MeetingDiarizationProfileID) async throws
```

It resolves the captured descriptor through the adapter registry, validates `supportsLive`, then
requires that exact ready asset revision. A missing adapter or unsupported profile fails with a
typed capability/unsupported-model error, never an implicit substitution.

At new-meeting start:

1. reconcile ready assets;
2. resolve concrete shared selection;
3. capture Final policy/profile as already specified in 009;
4. capture the Live-session profile and capability separately from the Final on/off policy;
5. initialize Live session override only when the profile supports Live.

Re-transcribe and Re-diarize menus continue to accept any ready concrete profile as a one-time
override without changing Settings. Existing meetings with a captured legacy Automatic snapshot
continue through the historical resolver.

### 8. Onboarding selection UI

Keep the existing step index and make the model step one scrollable page with two sections:

- `Transcription` — existing Parakeet/optional ASR cards;
- `Speaker separation` — only for a use case including Meetings.

The speaker section is opt-in and single-choice, populated entirely from descriptors whose
`onboarding.visibility == offered`:

- `Not now` (initial state; no surprise download);
- zero or more catalog cards ordered by catalog metadata;
- at most one current descriptor may carry the Recommended badge for this onboarding context;
- capability and speaker-limit copy is derived from descriptor fields.

Already-ready cards show `Downloaded` and enter the plan as a no-op validation/selection item.
Changing the use case to non-meeting removes an unstarted optional diarization item.

### 9. Durable onboarding preparation plan

Replace the single `modelDownloadBackend` ownership model with:

```swift
struct OnboardingModelPreparationPlan: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    var items: [OnboardingModelPreparationItem]
}

enum OnboardingModelPreparationKind: Codable, Equatable {
    case transcription(backend: String, model: String)
    case diarization(profileID: String)
}
```

Each item has a stable ID, required/optional role, phase, retryable error category, and last display
progress. Local paths, API keys, and downloaded bytes are not serialized.

Execution is sequential in deterministic order. The executor skips an item only after its
authoritative store validates readiness. The UI reports:

```text
Downloading <model display name> (2 of 3) · 47%
Setting up <model display name> (2 of 3)
```

The percentage always belongs to the named item. Do not compute a cross-model byte percentage.

### 10. Wizard/background ownership transfer

One task owner exists at a time:

- while Wizard is visible, `OnboardingView` observes an app-owned preparation session;
- when the Wizard closes/completes, `MuesliController` keeps the same plan/session alive or resumes
  from its persisted plan;
- on relaunch, the controller reconstructs the plan and each provider revalidates readiness.

Do not cancel an in-flight task and reconstruct only the primary backend as current code does. A
cancel/transfer handshake must await the old owner before the next starts, preventing duplicate
provider downloads or asset-store races.

Primary transcription failure retains the current dictation-test gate. Optional ASR/diarization
failure is item-scoped: show Retry/Skip and continue core onboarding. A successful diarization item
triggers central selection reconciliation but does not enable Final or Live.

### 11. Onboarding progress schema

Bump `OnboardingProgress.currentSchemaVersion` from 4 to 5 and add optional/defaulted fields:

- selected diarization profile raw value (nil = Not now);
- serialized preparation plan or stable selected-item descriptors;
- current preparation item ID/index and item-local display progress.

Schema 1–4 payloads decode with no diarization selection and are upgraded safely. A permission-
repair onboarding progress generated after completion must not re-offer or schedule models unless
the user returns to the model step explicitly.

### 12. Model revision, deprecation, and retirement lifecycle

Model identity and installed revision are separate. When a newer compatible descriptor revision is
available, Models shows Update. Update downloads into a unique staging location, validates the
complete asset and adapter compatibility, then atomically swaps the active pointer/marker. Until
that commit, the previous ready revision remains runnable; failure removes/quarantines only staging
data and maps to Retry.

Lifecycle values:

- `active`: downloadable/selectable and eligible for recommendation;
- `deprecatedSupported`: existing users may keep/select it, but new onboarding does not recommend
  it and Models explains that a newer option exists;
- `unsupportedTombstone`: cannot run or be selected; remains visible if installed and offers
  descriptor-driven Replace/Remove. If no bundled tombstone exists, Homan synthesizes a generic
  `Legacy speaker model` tombstone from owned asset identity without exposing storage details;
- `withdrawnNotInstalled`: hidden from new download surfaces but retained for decoding evidence and
  recognizing old installed assets.

Removing or retiring a model asset never removes completed diarization/transcript evidence. A
background garbage collector may delete only abandoned staging/partial data that has no live task
owner; it never deletes a validated installed model merely because a new catalog was bundled.

### 13. Accessibility and localization

- Every model card exposes name, capability, size/license, status, and action in a coherent VoiceOver
  order.
- Disabled Live control includes the incompatibility reason in its accessibility help/value.
- Progress changes are throttled; phase/item transitions are announced, not every percentage tick.
- User-facing strings are centralized for future localization. The required Live sentence remains
  exact in English.
- Model display names and capability descriptions come from descriptor localization keys, never
  raw IDs or view-local string switches.

## Testing Strategy

### Pure unit tests

- selection property tests for catalogs with 0, 1, 2, 3, and 10 descriptors;
- idempotence and deterministic simultaneous transition ordering;
- catalog schema/unique-ID/adapter/replacement-cycle/lifecycle validation and exclusion of
  `.automatic`;
- add/rename/deprecate/retire/update synthetic descriptors without changing UI/resolver fixtures;
- preparation plan construction/order, Codable migration, skip/retry, and ownership transfer;
- onboarding schema 1–5 decoding.

### Integration tests

- startup reconciliation with fake asset markers;
- install/update/retry/remove/rollback state plus config/AppState result;
- zero/one/many-model Settings rendering data;
- generic non-Live-capable descriptor refusal and typed error;
- new meeting captures concrete profile;
- legacy `.automatic` manifest/evidence still resolves Offline quality;
- onboarding install reuses `MeetingDiarizationAssetStore` and survives relaunch;
- optional failure does not block onboarding.

### Regression tests

- Final/recovery/Re-transcribe/Re-diarize and Homan Whisper processing;
- active-recording install/remove prohibition;
- Live ASR remains independent from Live speaker analysis;
- start-next-meeting while prior meeting processes;
- Models interrupted-setup retry behavior from commit `acc9169`, with storage detail hidden from UI;
- source roles, speaker collapse, manual transcript, summary staleness.

### Manual signed-build checks

- fresh onboarding with each use case;
- download several current/catalog-fixture profiles from Wizard and Models;
- verify exact Settings/Live copy;
- switch among multiple installed models and record a short meeting;
- remove selected model with one and several alternatives remaining;
- exercise Update success/failure rollback and deprecated/unsupported card states;
- relaunch during each download phase;
- verify no Keychain/network/permission changes.

## Implementation Sequence and Commit Boundaries

1. **Catalog/domain commit**: open IDs, validated descriptor catalog, capabilities/lifecycle, pure
   resolver, migration tests.
2. **Runtime commit**: shared concrete selection capture and capability-aware Live preparation.
3. **Models/Settings commit**: download-only Models and 0/1/N Settings UX.
4. **Onboarding state commit**: durable plan, progress schema 5, ownership transfer.
5. **Onboarding UI commit**: speaker section, item progress, retry/skip.
6. **Regression commit**: integration fixtures, accessibility copy, documentation updates.

Each commit must build and pass its targeted tests. Do not combine durable migration/runtime changes
with the visual cleanup in one unreviewable patch.

## Rollout and Recovery

- Ship behind the existing Final/Live enablement defaults; no new feature flag is required for the
  selection UI.
- Perform one startup reconciliation after asset validation. Log only non-sensitive transition
  reason and profile ID to local diagnostics.
- On reconciliation failure, keep AppConfig unchanged and report unavailable; do not guess.
- On capability-aware Live preparation failure, stop only Live diarization and continue recording
  and Live ASR as Others.
- If onboarding plan decoding fails, discard display progress, rebuild choices from the last valid
  bundled catalog, and re-query stores; never delete valid assets.
- If catalog validation fails, use the last bundled valid catalog or a safe empty catalog. Do not
  crash, delete assets, or expose storage repair steps.
- An older Homan must safely ignore/fall back from an unknown open model ID without crashing. It may
  not run a model introduced by a newer build; old evidence remains readable through stored string
  provenance and compatibility aliases.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Reinterpreting old Automatic | Wrong recovery/evidence reuse | Separate future preference migration from historical resolver |
| View-level race after install/remove | Wrong selected model | One serialized coordinator with generation token |
| Hidden Live substitution | UI and runtime use different models | Capability gate + captured descriptor parameter |
| Wizard closes mid-download | Optional model silently lost | Durable plan and explicit owner transfer |
| Stale 100% resume state | Interrupted setup treated ready | Asset store is authoritative; progress is display-only |
| Optional model blocks first run | User cannot finish onboarding | Item-scoped Retry/Skip; only required ASR gates test |
| One model auto-selection surprises user | Future runs change after download | Explain rule in Models/Settings; never auto-enable Final/Live |
| Selecting a Final-only model leaves latent Live On | Future unexpected activation | Normalize Live default Off from capability metadata |
| New meeting captures unavailable model | Final fails after Stop | Resolve concrete ready profile before snapshot; otherwise capture disabled/unavailable |
| Third/new model needs view changes | Scattered hard-code and regressions | Open stable ID + descriptor catalog; synthetic N-model tests |
| Failed update destroys working model | Feature regression/offline loss | Stage, validate, atomic activate; retain previous revision on failure |
| Retired model becomes an unknown folder | User cannot understand/remove it | Tombstone descriptor + app-owned Replace/Remove |
| Error leaks storage internals | User asked to manipulate files | Product error mapper; prohibit path/manual-remediation copy |

## Approval Gate

This package plans implementation only. Application code, commits, builds, installation, and
release artifacts require a separate execution instruction after owner approval.
