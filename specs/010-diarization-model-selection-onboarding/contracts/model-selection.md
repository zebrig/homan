# Contract: Diarization Model Selection and Onboarding Preparation

This contract is normative. Type names are illustrative; semantics are required.

## 1. Versioned descriptor catalog contract

```swift
struct MeetingDiarizationModelID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

protocol MeetingDiarizationModelCatalogProviding: Sendable {
    func snapshot() throws -> MeetingDiarizationCatalogSnapshot
}

struct MeetingDiarizationCatalogSnapshot: Sendable, Equatable {
    let schemaVersion: Int
    let revision: String
    let descriptors: [MeetingDiarizationModelDescriptor]
}
```

Rules:

- descriptors have unique stable IDs and aliases and deterministic metadata-defined order;
- `.automatic` and rollback-only values are compatibility aliases, not selectable descriptors;
- every active/selectable descriptor has capabilities, license, asset revision, and an allowlisted
  runtime adapter;
- replacement references are present or safely absent and cannot form a cycle;
- raw enum iteration and view-local ID/name arrays are never user-facing catalogs;
- invalid catalog content falls back safely and never deletes installed assets.

## 2. Pure selection resolver contract

```swift
struct MeetingDiarizationSelectionInput: Equatable, Sendable {
    let catalog: MeetingDiarizationCatalogSnapshot
    let readyModelIDs: Set<MeetingDiarizationModelID>
    let storedModelIDOrLegacyAlias: String?
}

enum MeetingDiarizationSelectionResult: Equatable, Sendable {
    case unavailable(readyDescriptors: [MeetingDiarizationModelDescriptor])
    case choiceRequired(readyDescriptors: [MeetingDiarizationModelDescriptor])
    case selected(
        modelID: MeetingDiarizationModelID,
        source: MeetingDiarizationSelectionSource,
        readyDescriptors: [MeetingDiarizationModelDescriptor]
    )
}

func resolveMeetingDiarizationSelection(
    _ input: MeetingDiarizationSelectionInput
) -> MeetingDiarizationSelectionResult
```

Preconditions:

- callers may pass any catalog size, but asset statuses must be reduced to integrity-validated ready
  stable IDs before constructing input;
- duplicate IDs have no effect;
- unsupported/tombstone descriptors are excluded from selectable ready descriptors;
- an unknown installed ID is visible only after the catalog layer synthesizes/loads a safe generic
  `Legacy speaker model` tombstone; it is never silently runnable.

Postconditions:

- a selected result is concrete, catalog-known, selectable, and ready;
- `.automatic` is never returned;
- result ordering follows catalog order;
- the function performs no I/O and is deterministic/idempotent.

Truth table:

```text
R={}                         stored=*                 -> unavailable
R={A}                        stored=*                 -> A, soleReady
|R|>=2 and stored=P in R     stored=P                 -> P, storedPreference
|R|>=2 and alias maps to L   stored=legacy alias      -> L, legacyAliasMigration
|R|>=2 and no valid target   stored=nil/bad/retired   -> choiceRequired
```

The resolver has no fallback model constant. Catalog recommendation metadata affects presentation,
not implicit selection.

## 3. Reconciliation contract

```swift
@MainActor
func reconcileMeetingDiarizationSelection(
    trigger: MeetingDiarizationSelectionTrigger
) async -> MeetingDiarizationSelection
```

Algorithm:

1. load/validate the current catalog snapshot and current asset statuses from actor-owned stores;
2. discard any result older than the latest reconciliation generation;
3. resolve selection with the pure resolver;
4. if a selected model differs, write its stable raw value through one config transaction; if the
   result is `choiceRequired`, do not invent or persist a selection;
5. if selected profile lacks Live support and Live default is On, write Live default Off in the
   same transaction;
6. publish one coherent AppState snapshot;
7. return the resolved state.

No view may duplicate steps 3–5. No selection is persisted before an install/update/remove
transaction has committed.

## 4. Historical compatibility contract

Two resolution modes are distinct:

```text
future-global selection:
    ready assets + AppConfig -> concrete selection

historical run/evidence resolution:
    captured profile snapshot -> original profile definition
```

Historical `.automatic` MUST keep resolving to the exact Offline-quality revision/configuration
captured by specification 009. This named mapping exists only in the compatibility registry. The
future-global resolver MUST NOT use it as a fallback or use current catalog state to validate old
evidence.

## 5. Capture contract

Before a new meeting is committed:

```swift
let selection = await reconcileMeetingDiarizationSelection(trigger: .meetingStart)
let capture = MeetingDiarizationCapture(
    finalPolicy: resolvedExistingFinalPolicy,
    concreteModelID: selection.selectedStableID,
    descriptorRevision: selection.descriptorRevision,
    liveSupported: selection.capabilities?.supportsLive == true,
    ...
)
```

Rules:

- unavailable or choice-required selection -> capture speaker analysis disabled/unavailable;
- no new capture contains `.automatic`;
- the active meeting never re-reads global selection to change its captured profile;
- a one-time Final action creates its own concrete run options and does not mutate the capture or
  AppConfig.

## 6. Live preparation contract

```swift
func prepare(modelID: MeetingDiarizationModelID) async throws
```

Behavior:

1. require the captured catalog descriptor and allowlisted runtime adapter;
2. require `supportsLive == true`, else throw `.unsupportedLiveModel(modelID)`;
3. require the exact captured/compatible asset revision ready;
4. load that exact registered adapter/config;
5. on error, release partial resources and leave recording/Live ASR operational.

The implementation MUST NOT replace any selected/captured non-Live model with another model.

## 7. Models contract

Models may call:

```swift
install(modelID, progress)
update(modelID, progress)
retry(modelID, progress)
replace(modelID, replacementID, progress)
remove(modelID)
statuses()
```

All public operations target stable IDs, never paths. After a successful authoritative transition,
the controller calls reconciliation. Models does not write model preference or Final/Live booleans.

Update/replace contract:

1. create uniquely owned staging state;
2. download/resume and validate complete asset/adapter compatibility;
3. atomically activate the new revision;
4. only after activation release/retire the previous asset when safe;
5. on failure/cancel keep the last known-good revision active and clean/quarantine staging
   internally.

No UI error may contain a path or tell the user to remove application data manually.

## 8. Onboarding preparation contract

```swift
actor OnboardingModelPreparationCoordinator {
    func startOrResume(plan: OnboardingModelPreparationPlan) -> AsyncStream<Update>
    func retry(itemID: String) -> AsyncStream<Update>
    func skip(itemID: String) async
    func transferOwnership(planID: UUID, to owner: Owner) async
    func cancel(planID: UUID) async
}
```

### Plan construction

Inputs:

- selected primary transcription backend;
- selected optional transcription models;
- onboarding use case;
- optional selected diarization profile.

Output order:

1. primary transcription item (`required`);
2. optional transcription items in catalog order;
3. optional diarization item when Meetings is included and a concrete choice exists.

Changing a choice produces a new plan revision. A running item is cancelled/awaited before a
replacement plan starts; callbacks include plan ID and attempt so stale updates are ignored.

### Item execution

Transcription items reuse `TranscriptionCoordinator.preloadRequired`. Diarization items reuse
`MeetingDiarizationAssetStore.install` through the controller. Both first revalidate readiness.

On diarization success:

1. mark item ready;
2. run global selection reconciliation;
3. do not mutate Final/Live enablement.

On optional failure:

- persist a typed failed item;
- expose Retry and Skip;
- allow the next onboarding step/completion;
- never write a selected model from non-ready setup state.

### Progress update

```swift
struct OnboardingModelPreparationUpdate: Sendable, Equatable {
    let planID: UUID
    let itemID: String
    let itemIndex: Int       // zero-based internally
    let itemCount: Int
    let phase: Phase
    let fractionCompleted: Double?
    let displayName: String
    let statusText: String?
}
```

UI renders `itemIndex + 1 of itemCount`. Fraction is item-local and monotonic within a phase, but a
new phase may use nil. Updates from a stale plan/attempt are ignored.

## 9. Resume contract

Onboarding progress is a statement of user intent and last display state. On load:

1. decode schema with backward-compatible defaults;
2. rebuild/validate semantic item IDs;
3. query each authoritative store;
4. replace stale Ready/Downloading/Updating states with actual state;
5. resume the first non-ready, non-skipped item;
6. never delete a ready asset because progress/catalog decoding failed.

## 10. Catalog evolution contract

- Adding an active descriptor that uses an existing adapter changes no view or resolver code.
- Renaming display metadata changes no persisted identity or evidence.
- Deprecating a descriptor prevents new recommendation but preserves supported installed use.
- An unsupported/withdrawn installed ID receives a tombstone view model and is not selectable.
- Replacement is descriptor-driven; views never switch on old/new model names.
- Removing a descriptor never removes completed evidence or a validated installed asset silently.
- Catalog/adapter mismatch fails closed and maps to app-owned Retry/Update/Remove actions.

## 11. Capture/install exclusion contract

Before install, update, retry, replacement, or remove:

- reject when meeting capture/start is active using the existing capture-active guard;
- do not unload a model owned by Live or Final inference;
- serialize runtime unload with asset mutation;
- surface a user-actionable retry-after-recording message.

This feature does not weaken the existing inference scheduler or capture priority.
