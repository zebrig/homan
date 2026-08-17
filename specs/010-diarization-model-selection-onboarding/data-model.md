# Data Model: Diarization Model Selection and Onboarding

## MeetingDiarizationModelID

An open stable string identity, not a closed UI enum and not a display name.

| Property | Rule |
|---|---|
| rawValue | Namespaced, immutable, non-empty string |
| persistence | AppConfig, onboarding intent, and new run capture use this value |
| display | Never shown directly; descriptor localization supplies the name |
| compatibility | Current enum raw values and legacy aliases bridge into this type |

Changing a model's display name, asset revision, recommendation, or lifecycle does not change its
stable ID. A materially different behavioral profile may receive a new ID/revision according to
the evidence contract.

## MeetingDiarizationModelCatalog

One bundled, versioned, schema-validated set of descriptors. Views and the generic selection
resolver consume this catalog; they do not switch over known IDs.

| Field | Meaning |
|---|---|
| schemaVersion/catalogRevision | Decoder and deterministic ordering/version identity |
| descriptors | Unique stable-ID descriptors, including active entries and legacy tombstones |
| digest | Integrity/debug identity of the bundled catalog |

### MeetingDiarizationModelDescriptor

| Field | Meaning |
|---|---|
| id | Stable open model ID |
| displayNameKey/detailKey | Localized product copy; never identity |
| assetRevision | Currently offered install/update revision |
| runtimeAdapterID | Allowlisted app adapter capable of installing/loading this descriptor |
| capabilities | Final/Live/speaker-limit/latency declarations |
| lifecycle | active, deprecatedSupported, unsupportedTombstone, withdrawnNotInstalled |
| onboarding | hidden/offered plus optional context recommendation/order metadata |
| license | Display name and notice URL |
| replacementID | Optional catalog-driven successor |
| legacyAliases | Old config/profile identifiers that map to this stable ID |

Catalog validation rejects duplicate IDs/aliases, unknown adapters, replacement cycles, invalid
capability combinations, or missing licenses. Validation failure uses the last bundled valid
catalog or a safe empty catalog and never deletes installed data.

## MeetingDiarizationCapabilities

Immutable descriptor metadata.

| Field | Meaning |
|---|---|
| supportsFinal | Profile can produce authoritative post-recording evidence |
| supportsLive | Profile can process provisional Live system audio with bounded latency |
| maximumRemoteSpeakers | Hard supported maximum or nil when no product-level maximum is promised |
| latencyClass | finalOnly or liveCapable; display/scheduling aid, not a free-form runtime knob |

Current seed descriptors (examples, not a closed catalog):

| Current descriptor | Final | Live | Maximum remote speakers |
|---|---:|---:|---:|
| Offline quality | yes | no | nil |
| Stable up to 4 | yes | yes | 4 |

`Automatic` is not a descriptor. It is a historical alias resolved only by compatibility code.

## MeetingDiarizationModelLifecycle

| Value | Download | Select/run | Onboarding | Installed presentation |
|---|---:|---:|---:|---|
| active | yes | yes | descriptor-controlled | normal |
| deprecatedSupported | no new recommendation; policy-controlled | yes while compatible | not recommended/usually hidden | Legacy model + successor info |
| unsupportedTombstone | no | no | hidden | No longer supported + Replace/Remove; synthesize `Legacy speaker model` when unknown |
| withdrawnNotInstalled | no | only historical evidence | hidden | shown only if an owned asset exists |

## MeetingDiarizationAssetAvailability

Derived only from authoritative `MeetingDiarizationAssetStore` status for concrete installable
profiles.

| Field | Meaning |
|---|---|
| readyProfiles | Ordered set of descriptors whose owned asset, digest, revision, adapter, and layout validate |
| nonReadyStatuses | absent/downloading/settingUp/updateAvailable/failed/unsupported display states |
| generation | Monotonic refresh generation used to reject stale async results |

Only `readyProfiles` participates in selection.

## MeetingDiarizationSelection

Resolved global selection for future meetings.

| Field | Meaning |
|---|---|
| state | unavailable, selected, or choiceRequired |
| profileID | Concrete stable ID when selected; never Automatic or a display name |
| source | Why the resolver chose it |
| readyAlternatives | Ordered ready/selectable descriptors for Settings |
| capabilities | Capabilities of selected profile |

### SelectionSource

| Value | Meaning |
|---|---|
| soleReady | Exactly one validated model exists; selected without a picker |
| storedPreference | Several models exist and stored concrete choice is still ready/selectable |
| legacyAliasMigration | Legacy value's historical target is still ready/selectable |
| explicitUserChoice | User selected from several ready descriptors in Settings/onboarding |

`choiceRequired` has no source/profile and prevents Final/Live from pretending a model is selected.

`source` is diagnostic/UX state, not durable meeting evidence.

## Persisted global fields

Existing fields remain the durable source to minimize migration risk:

| Existing AppConfig field | New semantic use |
|---|---|
| meetingFinalDiarizationProfile | Shared stable speaker-separation model ID for future Final and Live; legacy key name retained temporarily |
| meetingFinalDiarizationEnabledByDefault | Independent Final enablement default |
| meetingLiveDiarizationEnabledByDefault | Independent Live enablement default; normalized Off for a Final-only selection |

The JSON key for the profile remains unchanged in this iteration. Code should add a shared semantic
accessor and stop exposing the old Final-only name to new UI/domain logic.

## Generic selection transition table

Let `R` be the set of ready/selectable descriptors, `P` the stored stable preference, and `L(x)` a
legacy alias target when one exists.

| Condition | Resolved state | Persisted change |
|---|---|---|
| `R` empty | unavailable | none until a model becomes ready |
| `R = {A}` | selected A / soleReady | persist A if different |
| `|R| >= 2` and `P ∈ R` | selected P / storedPreference | none |
| `|R| >= 2`, `P` legacy, and `L(P) ∈ R` | selected L(P) / legacyAliasMigration | persist target |
| `|R| >= 2` and no valid preference/alias | choiceRequired | clear invalid future selection; require user choice |

Install, update, deprecate, retirement, and remove are ordinary applications after the
authoritative asset/catalog transition commits. Non-ready and unsupported assets are absent from
`R`. Installing an additional model preserves a valid selection. Removing the selected model
auto-selects only when exactly one selectable model remains; with several, it requires a choice.

## CapturedMeetingDiarizationSelection

Immutable session/run input derived from global selection plus existing meeting policy.

| Field | Meaning |
|---|---|
| profileID | Concrete stable model ID or nil when unavailable/choice-required/disabled |
| profileRevision | Exact profile revision |
| capabilities | Capability snapshot relevant to session UI |
| assetSnapshot | Existing model revision/digest/configuration snapshot when required by Final evidence |
| capturedAt | Time Settings stopped influencing this meeting |

This does not replace existing `MeetingDiarizationRunOptions` or evidence profile snapshots. It
provides a concrete input to them. Historical captured `.automatic` values remain valid legacy
inputs and are not converted in place.

## OnboardingDiarizationChoice

Wizard intent only.

| Field | Values / meaning |
|---|---|
| selectedProfileID | nil (`Not now`) or any onboarding-offered catalog stable ID |
| userExplicitlySelected | Distinguishes default display recommendation from consent to download |

The initial value is nil. A descriptor's Recommended badge does not select or download it.

## OnboardingModelPreparationPlan

Codable intent and resumable ordering; not an asset database.

| Field | Meaning |
|---|---|
| schemaVersion | Plan decoder version |
| planID | Stable UUID for ownership transfer and stale callback rejection |
| createdAt/updatedAt | Resume/diagnostic ordering |
| items | Deterministic ordered preparation items |
| currentItemID | Optional current item for display/resume |

### OnboardingModelPreparationItem

| Field | Meaning |
|---|---|
| id | Stable semantic ID (`asr:<backend>:<model>` or `diarization:<profile>`) |
| kind | transcription or diarization |
| requirement | required or optional |
| phase | pending, checking, downloading, settingUp, updating, ready, failed, skipped |
| attempt | Monotonic retry attempt number |
| progress | Optional item-local 0...1 display value |
| statusText | Non-sensitive resumable display hint |
| errorCategory | Optional typed retryable/non-retryable category; no raw storage path or secret |

### Invariants

- IDs are unique within a plan.
- Required primary ASR precedes optional ASR; diarization is last.
- A ready phase is display state until the underlying store revalidates it on resume.
- A percentage belongs only to its item and phase.
- Local file paths, model bytes, API keys, bearer tokens, and transcript/audio data are absent.
- One executor owns a plan ID at a time.

## MeetingDiarizationAssetRevisionState

| Field | Meaning |
|---|---|
| modelID | Stable catalog identity |
| activeRevision | Validated revision currently runnable, if any |
| offeredRevision | Revision in the current descriptor |
| stagedRevision | Temporary update candidate, never selectable until validation/activation |
| phase | absent, downloading, settingUp, ready, updating, failed, unsupported |
| digest/size | Internal integrity/storage metadata, not user remediation copy |
| lastKnownGood | Previous ready revision retained until atomic update succeeds |

Update transaction:

```text
ready(old) -> stage(new) -> validate(new) -> atomically activate(new) -> retire old staging/asset
                         -> failure/cancel -> keep ready(old), clean/quarantine stage internally
```

No user operation targets a local path. All public operations target the stable model ID.

## OnboardingProgress schema 5

Add optional fields with safe defaults:

| Field | Default for schema 1–4 |
|---|---|
| selectedDiarizationProfileKey | nil |
| modelPreparationPlan | reconstructed from primary ASR selection when needed |
| currentPreparationItemID | nil |
| currentPreparationItemProgress | legacy modelDownloadProgress only for display |
| currentPreparationStatus | legacy modelDownloadStatus only for display |

Existing `modelDownloadProgress` and `modelDownloadStatus` may remain for one release as decoder
aliases. New writes use plan fields. Loading a schema-5 plan immediately reconciles every item with
its authoritative store.

## Runtime/UI view state

Views receive one immutable snapshot:

```text
asset statuses
+ selection state
+ Final enabled preference
+ Live enabled/effective capability
+ active install/preparation progress
```

No SwiftUI view writes selection merely because it rendered a state. Actions call controller
operations; the controller commits asset/config changes, then publishes one new snapshot.

## Lifecycle and deletion

- Removing an asset deletes only app-owned model storage after runtime ownership is safe.
- Selection reconciliation follows successful removal; it never precedes deletion.
- Removing every model does not delete historical diarization evidence or change old run snapshots.
- Deprecating/withdrawing a descriptor never deletes a validated installed asset automatically.
- Unsupported installed IDs remain represented by tombstone descriptors and can be removed through
  the app.
- Orphan collection touches only unowned staging/partial state after proving no task/runtime owner;
  it never turns a valid selected model into absent.
- Onboarding progress is cleared on completion as today, but a transferred background preparation
  plan must live under controller ownership until ready/failed/skipped.
- Resetting onboarding display progress never removes a valid downloaded model.
