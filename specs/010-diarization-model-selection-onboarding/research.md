# Research: Current Selection and Onboarding Behavior

**Status**: Code audit complete on 2026-08-17

## Decision 1: Treat `.automatic` as legacy compatibility, not installed-model automation

### Observed behavior

`MeetingDiarizationProfiles.resolve(.automatic)` currently resolves unconditionally to
`offlineQuality`. It does not inspect installed assets. Models nevertheless labels Offline quality
as `Used by Automatic`, while Settings lists Automatic, Offline quality, and Stable up to 4 as if
they were three independent choices.

### Decision

Remove `.automatic` from all new user-facing lists and new captures. Keep its decoder and historical
resolver untouched so completed evidence and recovery remain reproducible. Materialize a concrete
global selection from ready assets for future meetings.

### Rejected alternatives

- Redefine `.automatic` dynamically as any installed asset: rejected because old evidence would
  change meaning as files are installed or removed.
- Delete `.automatic` from the enum: rejected because AppConfig, manifests, and evidence already
  persist it.

## Decision 2: Use one shared model preference with capability checks

### Observed behavior

Final reads `meetingFinalDiarizationProfile`. Live ignores it:
`MeetingLiveDiarizationEngine.prepare()` always loads `.stableFourSpeaker`, and the Live UI describes
that hard-coded behavior.

### Decision

Keep the existing persisted config field for backward compatibility, but treat its concrete value
as the shared speaker-separation model preference. Add explicit profile capabilities. Both Final
and Live resolve through the same selection service; Live refuses a profile without Live support.

The stored property/key may retain its current `Final`-oriented internal name in the first patch to
avoid a risky config migration. New accessors and UI use `MeetingDiarizationSelection` and
`Speaker separation model` terminology.

### Rejected alternatives

- Separate Final and Live model pickers: rejected by the requested UX and because only one profile
  currently supports Live.
- Silently substitute Sortformer when Offline is selected: rejected because the displayed model
  would not match the model that runs.

## Decision 3: Centralize selection reconciliation

### Observed behavior

Models determines `isInUse` by comparing AppConfig and special-casing Automatic. Settings builds
its profile menu from `MeetingDiarizationProfileID.allCases`. Meeting detail builds another list
from the same enum. Install/remove currently refreshes asset status but does not own a single
selection transition.

### Decision

Introduce one pure resolver plus one app-owned reconciliation coordinator. The resolver consumes
ready concrete descriptors and a stored preference and returns a concrete selection plus its
reason for catalogs of any size. With several ready models and no valid prior selection, it asks for
a choice rather than choosing a current model name in code. The coordinator is invoked after
authoritative asset validation at startup and after install, update, retry, remove, or repair
commits. Views consume the result and never reproduce the rules.

## Decision 4: Put diarization in the existing model step, not a new Wizard step

### Observed behavior

The Wizard model step is already scrollable and queues a mandatory Parakeet model plus selected
additional ASR models. The step exists for every onboarding use case. Meeting-specific summary and
calendar steps are added conditionally.

### Decision

Rename the heading to `Choose your models` and add a `Speaker separation` section only when the use
case includes Meetings. The section is optional (`Not now`) and single-choice. This avoids changing
step numbering, permission-resume logic, progress dots, or completion routing.

Cards, order, recommendations, and capability copy come from the versioned model catalog. The
current catalog may recommend Stable up to 4 because it supports both Final and Live and describe
Offline quality as Final-only, but the Wizard contains neither name nor ID in its own branching
logic. No model is silently downloaded merely because Meetings was selected.

## Decision 5: Replace the single-backend task with a durable preparation plan

### Observed behavior

`ensureModelDownloadStarted()` constructs an in-memory array of one primary and selected additional
ASR backends. `OnboardingProgress` schema 4 stores only the primary backend plus one progress/status
pair. When onboarding completes during preparation,
`continueModelPreparationAfterOnboarding()` receives only the primary backend. Optional items can
therefore be forgotten after task cancellation, and the current structure cannot safely append a
diarization asset.

### Decision

Represent onboarding preparation as an ordered, Codable plan with stable item IDs. The Wizard and
post-onboarding controller transfer ownership of the same plan. Persist choice/intent, not local
file truth; readiness is always revalidated by the corresponding store.

Order:

1. required primary transcription model;
2. selected optional transcription models in deterministic catalog order;
3. selected optional diarization model.

Progress is item-local with `n of m`; byte totals from different providers are not averaged.

## Decision 6: Optional diarization does not change rollout defaults

### Observed behavior

Specification 009 intentionally ships Final and Live behind independent opt-in defaults. A model
being present does not prove the user wants analysis enabled for every meeting.

### Decision

Onboarding installation chooses the shared concrete model after it reaches ready state, but does
not silently enable Final or Live. This request changes preparation and selection, not consent or
quality rollout policy.

## Decision 7: Normalize unsupported Live state rather than queue hidden intent

### Decision

When a Final-only profile becomes selected, set the global Live-speaker default to Off in the same
config transaction. The Settings and active-meeting UI show
`This model doesn't support Live speaker diarization`. This prevents an invisible stored On value
from unexpectedly activating after a later model switch.

An already active recording uses its captured profile and session state; Settings normalization
does not mutate the recording.

## Decision 8: Introduce a versioned descriptor catalog, not another two-model switch

### Observed risk

The first draft listed `[.offlineQuality, .stableFourSpeaker]` and designed explicit two-model
truth tables. That would force changes in Models, Settings, onboarding, tests, and fallback logic
when a third model arrives or one current model is retired.

### Decision

Use one app-bundled, versioned, validated catalog of descriptors with stable opaque IDs. A
descriptor owns display metadata, asset revision, runtime adapter ID, capabilities, lifecycle,
onboarding visibility/recommendation, license, and optional replacement. The catalog may be a
bundled manifest decoded into domain values plus a compile-time adapter registry; arbitrary remote
catalog data may not select executable code or untrusted download locations.

Generic screens iterate descriptor view models. A genuinely new inference engine still requires a
registered adapter, but adding a model that uses an existing adapter/config family does not require
view or selection-resolver changes.

Current model names remain only in seed descriptors, compatibility aliases, and integration tests.
They are examples of catalog data, not control flow.

## Decision 9: Make every storage recovery operation application-owned

### Observed risk

Even technically accurate text such as "remove incomplete files" leaks implementation detail and
requires a user to know Application Support layout. It becomes worse when asset formats/revisions
change.

### Decision

The UI never names files, directories, paths, caches, markers, or packages as remediation. It says
only what the user can do: Retry, Update, Remove, Continue without speaker separation, or Try after
recording. Internally, the asset store owns staging, resume, validation, quarantine, rollback,
orphan cleanup, and atomic activation.

An update never destroys a working revision before the replacement validates. A deprecated model
can remain supported and removable; an unsupported installed model is represented by a bundled
tombstone descriptor so it remains visible and safely removable. Retirement never deletes meeting
evidence.

## Authoritative code locations

- `ModelsView.swift`: current speaker cards mix installation and configuration.
- `SettingsView.swift`: current Final profile picker and independent Live toggle.
- `MeetingDiarizationProfiles.swift`: legacy Automatic resolution and concrete definitions.
- `MeetingLiveDiarizationSession.swift`: hard-coded Sortformer Live preparation.
- `OnboardingView.swift`: model cards, in-memory sequential task, progress UI.
- `OnboardingProgress.swift`: schema-4 resume payload.
- `OnboardingWindowController.swift`: resume reconstruction.
- `MuesliController.swift`: post-onboarding single-backend continuation and completion.
- `MeetingRawAudioCapture.swift` / `MeetingProcessingCapture.swift`: immutable Final policy capture.

## No web dependency

This design is based on current Homan code and the already selected/implemented FluidAudio
profiles. It makes no new claim about external model quality or version currency.
