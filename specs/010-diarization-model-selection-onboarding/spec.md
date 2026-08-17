# Feature Specification: Diarization Model Selection and Onboarding

**Implementation Branch**: `main` (planning only; no application code changed by this specification)

**Created**: 2026-08-17

**Status**: Planned

**Input**: "Make Models a simple download/status screen. If exactly one diarization model is
downloaded, use it automatically; if more than one is downloaded, choose the model in Settings.
Use the same selected model for Final and Live where the model supports that capability. Add an
optional diarization-model download to the onboarding Wizard. When Offline quality is selected,
show beside Live: `This model doesn't support Live speaker diarization`."

**Depends on**: [Local Meeting Diarization](../009-local-meeting-diarization/spec.md)

**Normative UX companion**: [flows-and-ux.md](flows-and-ux.md)

## Scope and supersession

This is a focused follow-up to specification 009. It supersedes only the user-facing profile
selection, asset-management, and onboarding behavior described there:

- `Automatic` is no longer a user-selectable profile or a badge in Models;
- Models manages installation state only;
- one concrete installed model is selected automatically;
- two or more installed models are selected between in Settings;
- Final and Live consult the same concrete selected profile, subject to capability;
- onboarding can explicitly queue one diarization model alongside transcription models.

The following specification-009 contracts remain unchanged:

- microphone is always `You`; only system audio is diarized;
- local diarization remains independent from local or Homan Whisper ASR;
- Final and Live enablement are independent;
- Live output is provisional and Final output is authoritative;
- model download never starts from recording, Final processing, recovery, Re-transcribe, or
  Re-diarize;
- meeting/run policy is captured before work and is not changed by later Settings changes;
- compatible evidence reuse, per-meeting Final override, one-time Re-transcribe/Re-diarize choices,
  reversible `Separated`/`Others`, and manual transcript preservation remain intact.

The internal `.automatic` profile remains decodable for old AppConfig values, captured manifests,
and completed evidence. It continues to resolve according to its historical definition when old
evidence is validated. New user choices and new run captures MUST use a concrete profile ID.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Download models without configuring processing (Priority: P1)

As a user, I want Models to show what can be downloaded, what is downloading, and what is already
downloaded without asking me to understand `Use for Final`, `Final default`, or `Automatic`.

**Why this priority**: The current screen combines file management with global behavior. A model
can simultaneously show `Ready`, `Used by Automatic`, and a `Use for Final` action, even though
Live has a different hard-coded model. Those labels describe implementation history rather than a
clear user decision.

**Independent Test**: Exercise absent, downloading, validating, ready, update-available, deprecated,
unsupported, failed, retry, and remove states across a catalog containing current, future, and
retired model descriptors. Verify that Models contains only asset actions and never changes
Final/Live enablement directly.

**Acceptance Scenarios**:

1. **Given** no local speaker model is installed, **When** the user opens Models, **Then** every
   downloadable catalog card shows `Download` and no default/active/use action.
2. **Given** a model is downloading, **When** progress changes, **Then** its card shows the current
   phase and percentage without implying it is usable before validation succeeds.
3. **Given** a model is ready, **When** the user opens Models, **Then** its status is `Downloaded`
   and its only destructive action is `Remove`.
4. **Given** model setup did not finish, **When** the user opens Models, **Then** the card offers
   `Retry`; Homan owns diagnosis, cleanup, staging, and replacement and never mentions files,
   folders, paths, caches, markers, or manual deletion to the user.
5. **Given** a model reaches ready state, **When** selection reconciliation runs, **Then** Models
   itself does not present or perform a `Use for Final` action.

---

### User Story 2 - Get an obvious model choice from installed assets (Priority: P1)

As a user, I want Homan to select the only downloaded speaker model automatically and ask me to
choose only when there is a real choice.

**Why this priority**: A separate default button is redundant when one usable model exists. When
several exist, hiding the choice in download cards makes the result difficult to predict.

**Independent Test**: Drive the selection resolver through every zero/one/many-ready transition,
including arbitrary catalog size, install, update, deprecation, retirement, retry, remove, relaunch,
legacy `automatic`, and invalid stored preferences.

**Acceptance Scenarios**:

1. **Given** zero models are ready, **When** Settings opens, **Then** it shows `No model downloaded`
   with an `Open Models` action and no fake selected profile.
2. **Given** exactly one model is ready, **When** Settings opens, **Then** Homan selects that
   concrete profile automatically and shows it as the selected model without a picker.
3. **Given** another model becomes ready, **When** Settings opens, **Then** the existing concrete
   selection is preserved and a picker containing every ready selectable model appears.
4. **Given** several models are ready, **When** the user changes the Settings picker, **Then** the
   same concrete selection is used for future Final and eligible Live sessions; Final/Live On/Off
   values do not otherwise change.
5. **Given** the selected model is removed and one ready model remains, **When** removal commits,
   **Then** Homan automatically selects the remaining model.
6. **Given** a model is not validated ready, **When** selection is resolved, **Then** it does not
   count as installed and can never become selected.
7. **Given** several models are ready but no valid preference exists, **When** Settings opens,
   **Then** Homan asks the user to choose instead of silently choosing a model by hard-coded name.

---

### User Story 3 - Understand whether the selected model works for Live (Priority: P1)

As a user, I want Final and Live to refer to one selected speaker model, with an explicit
capability message when that model cannot run Live.

**Why this priority**: The current Final picker and hard-coded Live Sortformer path describe two
different selection systems. Exposing one shared selection without enforcing capabilities would
replace that confusion with runtime failures.

**Independent Test**: Select each concrete profile with Final/Live defaults in every state, start a
recording, toggle Live, change Settings during the recording, and verify capability and snapshot
behavior.

**Acceptance Scenarios**:

1. **Given** the selected catalog descriptor supports Final and Live, **When** Live speaker
   diarization is enabled, **Then** Live prepares that exact concrete profile and Final uses the same
   profile for a newly captured run unless a documented per-meeting or one-time Final override
   applies.
2. **Given** the selected catalog descriptor does not support Live (currently including
   `Offline quality`), **When** Settings shows the Live control, **Then** it
   shows exactly `This model doesn't support Live speaker diarization` beside Live and the Live
   speaker control cannot be enabled.
3. **Given** a Final-only profile was captured for an active recording, **When** the user opens its
   Live card, **Then** the same message is visible and the session cannot start another model behind
   the user's back.
4. **Given** Settings changes after a recording starts, **When** Live or Final later runs for that
   recording, **Then** the captured meeting/session profile remains stable; Settings affects only
   later meetings or explicit one-time actions.
5. **Given** the selected/required asset disappears or fails validation, **When** Live starts,
   **Then** Live fails non-fatally to `Others` while raw recording and Live ASR continue.

---

### User Story 4 - Prepare speaker separation during onboarding (Priority: P1)

As a new meetings user, I want the Wizard to offer a diarization model and download my explicit
choice using the same progress/retry behavior as other selected models.

**Why this priority**: Speaker separation currently appears only after onboarding. Users discover
the feature in Settings and then must navigate to Models before it can work.

**Independent Test**: Run onboarding for every use case against catalogs with zero, one, two, and
more eligible descriptors; include preinstalled assets, interrupted download, relaunch, retry,
skip, descriptor deprecation, and completion while an optional download is still running.

**Acceptance Scenarios**:

1. **Given** an onboarding use case that includes Meetings, **When** the model step opens, **Then**
   it includes an optional `Speaker separation` section populated from onboarding-eligible catalog
   descriptors, with one concrete model choice and a `Not now` path.
2. **Given** a dictation/voice-notes-only use case, **When** the model step opens, **Then** no
   diarization download is proposed.
3. **Given** the user selects a diarization profile, **When** they choose `Download & Continue`,
   **Then** the shared onboarding preparation plan queues it after required transcription assets
   and reports the active item as `item n of m` plus item-local progress.
4. **Given** the selected profile is already ready, **When** onboarding continues, **Then** no
   duplicate download occurs and selection reconciliation uses the ready profile.
5. **Given** a diarization download fails, **When** onboarding continues, **Then** core onboarding
   is not blocked; the user can Retry or Continue without speaker separation, and no incomplete
   asset becomes selected.
6. **Given** Homan relaunches during onboarding, **When** the Wizard resumes, **Then** it restores
   the selected profile and re-queries the authoritative asset store instead of trusting a stale
   percentage.
7. **Given** onboarding completes while optional preparation remains, **When** the Wizard closes,
   **Then** the same plan continues safely under the application controller and does not forget
   the diarization item.

---

### User Story 5 - Upgrade without changing old meetings (Priority: P1)

As an existing user, I want the simpler selection model without changing which engine old meetings
used or invalidating completed diarization evidence.

**Why this priority**: `.automatic` is already persisted in AppConfig, manifests, and provenance.
Reinterpreting it globally as "whichever model is installed" would make recovery and audit depend
on current disk state.

**Independent Test**: Open legacy configs and fixtures with `.automatic`, concrete IDs, malformed
values, captured runs, completed evidence, zero/one/many assets, removed catalog entries, updated
asset revisions, and downgrade/relaunch paths.

**Acceptance Scenarios**:

1. **Given** an old global preference is `.automatic` and exactly one model is ready, **When** the
   app reconciles Settings, **Then** it persists that one concrete profile for future meetings.
2. **Given** an old global preference is `.automatic` and its historical concrete target is still
   ready, **When** the app reconciles Settings, **Then** it materializes that target to preserve the
   former global behavior; this compatibility alias is not a general selection rule.
3. **Given** old completed evidence or a captured run requests `.automatic`, **When** it is
   validated or recovered, **Then** historical resolution remains `Offline quality`; current
   installed-model selection never rewrites the evidence.
4. **Given** no model is ready, **When** legacy Settings loads, **Then** speaker separation is
   unavailable rather than pretending an asset is selected; the next first ready model is selected
   concretely.
5. **Given** a user has an explicit concrete selection that is still ready, **When** the app
   upgrades, **Then** that selection is preserved.

---

### User Story 6 - Evolve the model catalog without exposing storage internals (Priority: P1)

As a user, I want new models and model updates to appear naturally, and obsolete models to remain
understandable/removable, without ever editing application files myself.

**Why this priority**: The two currently shipped profiles are not the final catalog. UI logic tied
to their enum cases or display names would make every future model a cross-cutting code change and
would recreate unsafe recovery instructions when assets evolve.

**Independent Test**: Feed the UI and resolver synthetic catalogs with added, deprecated, replaced,
and unsupported descriptors and multiple asset revisions. Verify that views require no model-ID
branch, updates are staged atomically, and every failure remains a one-click app-owned action.

**Acceptance Scenarios**:

1. **Given** a new descriptor is added to the bundled catalog, **When** Homan opens Models and
   onboarding, **Then** it appears according to descriptor metadata without editing either view.
2. **Given** an installed model has a newer compatible asset revision, **When** the user chooses
   `Update`, **Then** Homan downloads and validates a staged replacement, atomically activates it,
   and keeps the old working revision if update fails.
3. **Given** an installed model is deprecated but still supported, **When** Models opens, **Then** it
   remains usable/removable with a clear `Legacy model` explanation and is not recommended to new
   users.
4. **Given** an installed model is no longer supported by this app build, **When** Models opens,
   **Then** it is not selectable and Homan offers an app-owned replacement/removal action without
   exposing storage locations.
5. **Given** setup is interrupted or leaves orphaned staging data, **When** Homan relaunches, **Then**
   Homan safely resumes, rolls back, quarantines, or cleans its own data; it never instructs the
   user to manipulate files.

## Edge Cases

- Several assets finish validation nearly simultaneously.
- A selected installation fails validation after a successful previous launch.
- The user removes the selected model while no recording is active and one or several models remain.
- The app quits between asset validation and AppConfig persistence.
- Onboarding progress says 100% but the asset marker is missing or invalid.
- A download is cancelled while the Wizard is moving to another step.
- Required ASR is ready but optional diarization is still downloading.
- Optional ASR fails before the queued diarization item.
- Onboarding is resumed only to repair permissions after it was previously completed.
- The user changes onboarding use case from Meetings to a non-meeting use case after selecting a
  diarization model.
- Live default was On in an old config but the selected/migrated profile is Final-only.
- A recording starts while a model install is in progress.
- A meeting-level or one-time Final override selects a different installed model from the global
  shared preference.
- An older build opens AppConfig after a newer build materialized a concrete profile.
- A catalog adds a third or tenth model without any Models/Settings/Onboarding source change.
- A descriptor is renamed for display while its stable ID and old evidence remain unchanged.
- A model revision update fails after download but before activation.
- A removed catalog entry still has an installed legacy asset on disk.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Models MUST be an asset-management screen only for diarization profiles.
- **FR-002**: Diarization cards in Models MUST expose only catalog metadata, capability/license
  information, installation/update phase, progress, and app-owned `Download`/`Update`/`Retry`/
  `Remove` actions as applicable.
- **FR-003**: Models MUST NOT expose `Use for Final`, `Set as Final default`, `Final default`,
  `Active`, or `Used by Automatic` controls/badges.
- **FR-004**: Installation UI MUST distinguish absent, downloading, setting up, ready,
  update-available, failed, deprecated, and unsupported states; ready MUST be labeled `Downloaded`.
- **FR-005**: Download, update, retry, rollback, cleanup, and removal MUST be app-owned. User-facing
  copy MUST NOT mention or require locating/deleting files, folders, paths, caches, markers, model
  packages, or Application Support contents.
- **FR-006**: Only integrity-validated `.ready` concrete profiles count as downloaded/selectable.
- **FR-007**: Available, onboarding-eligible, deprecated, replacement, and selectable profiles MUST
  come from one versioned catalog of stable opaque IDs and descriptors; views MUST NOT contain an
  array/switch over current model IDs or display names. The legacy `.automatic` alias is excluded.
- **FR-008**: Exactly one ready profile MUST resolve to that concrete profile automatically.
- **FR-009**: With two or more ready selectable profiles, a valid existing concrete preference MUST
  be preserved and Settings MUST show a picker populated from all ready selectable descriptors.
- **FR-010**: Installing any additional profile MUST NOT silently switch from the previously
  selected ready profile.
- **FR-011**: Removing the selected profile with one ready profile remaining MUST select the
  remaining profile automatically after removal commits.
- **FR-012**: With zero ready profiles, selection state MUST be unavailable and Settings MUST offer
  an `Open Models` action.
- **FR-013**: Selection reconciliation MUST be a single idempotent domain operation invoked after
  startup asset validation and successful install/remove/repair transitions; views MUST NOT each
  implement their own selection rules.
- **FR-014**: Final and Live MUST consult one shared concrete global selection for new meetings.
- **FR-015**: Final and Live enablement MUST remain separate preferences and session/run policies.
- **FR-016**: A profile definition MUST declare explicit `supportsFinal` and `supportsLive`
  capabilities; UI and runtime MUST use those capabilities rather than raw-ID comparisons.
- **FR-017**: Every catalog descriptor MUST declare Final/Live capabilities and constraints; the
  current Offline-quality descriptor declares Final support and no Live support.
- **FR-018**: The current Stable-up-to-4 descriptor declares Final and Live support plus its existing
  four-remote-speaker limit; future models are governed by their own descriptor capabilities.
- **FR-019**: Whenever the selected model lacks Live support, including current Offline quality,
  Settings MUST show exactly
  `This model doesn't support Live speaker diarization` beside Live.
- **FR-020**: The active-meeting Live control MUST enforce the captured profile capability and MUST
  NOT substitute any other model when a non-Live profile was selected/captured.
- **FR-021**: An unsupported Live default/session override MUST be effectively Off. The UI MUST NOT
  retain a hidden queued-On state that unexpectedly activates after a later model switch.
- **FR-022**: Selecting a Final-only profile MUST normalize the global Live-speaker default to Off
  in the same config transaction and announce the reason accessibly.
- **FR-023**: A recording MUST capture its resolved concrete profile/capability before the session
  can use it. Later Settings/install/remove changes MUST NOT mutate that captured value.
- **FR-024**: Existing per-meeting Final policy and one-time Re-transcribe/Re-diarize profile choices
  MUST remain independent and MUST list ready concrete profiles only.
- **FR-025**: New processing captures MUST NOT persist `.automatic`; they MUST capture a concrete
  profile or disabled/unavailable state.
- **FR-026**: Historical `.automatic` config/run/evidence values MUST remain decodable and MUST keep
  their former Offline-quality resolution for validation/recovery.
- **FR-027**: Legacy global `.automatic` MUST materialize its historical target when that target is
  ready; otherwise it follows the generic zero/one/many rules. This legacy alias MUST NOT become a
  hard-coded fallback for future catalog selection.
- **FR-028**: A valid ready concrete preference MUST survive migration unchanged.
- **FR-029**: Onboarding MUST show diarization choices only when the selected use case includes
  Meetings.
- **FR-030**: Onboarding MUST offer `Not now`; it MUST NOT silently download a diarization asset.
- **FR-031**: Onboarding MUST allow at most one diarization profile to be selected at a time.
- **FR-032**: Onboarding recommendation, ordering, visibility, capability copy, and replacement
  relationships MUST come from catalog metadata. The view MUST NOT name current model IDs in code.
- **FR-033**: Onboarding MUST reuse the production `MeetingDiarizationAssetStore` install,
  validation, retry, digest, and license path; it MUST NOT implement another downloader or marker.
- **FR-034**: The onboarding preparation plan MUST contain stable item IDs and an ordered list of
  required ASR, selected optional ASR, and selected optional diarization items.
- **FR-035**: The onboarding progress UI MUST show the active item name, `n of m`, phase, and
  item-local progress; it MUST NOT average unrelated byte sizes into a misleading aggregate.
- **FR-036**: Optional diarization failure MUST NOT block core onboarding or make an incomplete
  model selectable.
- **FR-037**: Onboarding resume state MUST persist the selected diarization profile and plan intent,
  but authoritative readiness MUST always be re-read from the asset store.
- **FR-038**: Completing onboarding while work remains MUST transfer the complete remaining plan to
  one background owner; cancelling the SwiftUI task MUST NOT lose selected optional items.
- **FR-039**: Selecting/downloading a diarization model in onboarding MUST set the shared concrete
  model preference only after validation succeeds; it MUST NOT silently enable Final or Live.
- **FR-040**: Changing onboarding to a non-meeting use case before completion MUST remove an
  unstarted diarization item from the plan and preserve any already downloaded asset without
  selecting it through the Wizard.
- **FR-041**: No model install, repair, validation replacement, or removal may start while meeting
  capture is active.
- **FR-042**: No additional telemetry, server call, or audio upload may be introduced by this
  feature; only explicit model download uses the network.
- **FR-043**: The catalog MUST separate stable identity, display name, asset revision, runtime
  adapter, capabilities, lifecycle, onboarding eligibility, recommendation metadata, license, and
  optional replacement ID.
- **FR-044**: Changing a display name MUST NOT change persisted selection, asset identity, or old
  evidence; application logic MUST compare stable IDs only.
- **FR-045**: Adding a catalog model MUST NOT require edits to Models, Settings, onboarding, or the
  generic selection resolver. A genuinely new engine may require one registered runtime adapter.
- **FR-046**: Updating an asset MUST use staging, integrity validation, and atomic activation. A
  failed/cancelled update MUST retain the previously ready revision.
- **FR-047**: Deprecated-but-supported models MAY remain selected but MUST NOT be recommended to new
  users. Unsupported models MUST NOT be selectable or runnable.
- **FR-048**: An installed ID missing from the active catalog MUST be represented through a bundled
  tombstone when known, or a synthesized unselectable `Legacy speaker model` descriptor when
  unknown, so the user can remove it safely through Homan.
- **FR-049**: Stale partial downloads, staging directories, and orphaned markers MUST be recovered or
  garbage-collected internally only when no owner/task uses them.
- **FR-050**: User-facing errors MUST be mapped to product actions (`Retry`, `Update`, `Remove`,
  `Continue without speaker separation`, `Try after recording`) and MUST NOT expose raw paths or
  storage-level remediation.
- **FR-051**: Catalog parsing/validation failure MUST fall back to the last bundled valid catalog or
  a safe empty catalog; it MUST NOT delete installed models or crash onboarding/Settings.
- **FR-052**: Model/version retirement MUST NOT rewrite or delete completed meeting evidence; exact
  captured profile revision, model revision, and digest remain historical provenance.
- **FR-053**: With two or more ready profiles and no valid prior/legacy selection, Settings MUST
  require an explicit choice; product logic MUST NOT fall back to a hard-coded model name.

### User-facing vocabulary

- Models status/actions: `Download`, `Downloading n%`, `Setting up`, `Downloaded`, `Update`,
  `Retry`, `Remove`, `Legacy model`, `No longer supported`.
- Settings row: `Speaker separation model`.
- Zero-ready state: `No model downloaded` and `Open Models`.
- One-ready helper: `Selected automatically — only downloaded model`.
- Live incompatibility: `This model doesn't support Live speaker diarization`.
- Do not use `Automatic`, `Final default`, or `Use for Final` as user-facing model-selection terms.

## Success Criteria *(mandatory)*

- **SC-001**: Every zero/one/many ready-state transition resolves deterministically in property and
  unit tests across synthetic catalogs of at least 0, 1, 2, 3, and 10 descriptors, including
  simultaneous readiness and process restart.
- **SC-002**: Models contains zero controls that mutate Final/Live enablement or global profile
  preference directly.
- **SC-003**: With one ready profile, a user can enable supported Final/Live behavior without first
  pressing any default/use button.
- **SC-004**: With multiple ready profiles, the Settings picker contains all and only selectable
  ready descriptors and always matches the concrete profile captured by the next meeting.
- **SC-005**: No descriptor with `supportsLive == false` can start Live inference, and every
  Settings/active-meeting path presents the required incompatibility message.
- **SC-006**: Existing `.automatic` evidence fixtures retain the same engine/config digest and pass
  validation after the migration.
- **SC-007**: A meetings onboarding run can select, download, validate, resume, retry, and complete
  with any onboarding-eligible descriptor without duplicating asset-store or per-model view logic.
- **SC-008**: Interrupted onboarding never promotes an incomplete model and never loses the
  remaining plan when the Wizard closes.
- **SC-009**: The complete targeted Swift test suite and signed Release build pass with no changes
  to source-role, Final evidence, Homan Whisper, recovery, or start-next-meeting behavior.
- **SC-010**: Synthetic add/rename/deprecate/retire/update catalog tests require no edits to the three
  views or generic resolver and never show a manual filesystem instruction.

## Assumptions and non-goals

- Offline quality and Stable up to 4 are current catalog entries and compatibility fixtures, not a
  closed set or names embedded in generic UI/selection logic.
- The catalog and resolver are designed for `N` models from this implementation onward.
- Onboarding selection is optional and does not change opt-in Final/Live rollout defaults.
- This feature does not benchmark diarization quality, add speaker naming, diarize microphone
  audio, add server-side diarization, or make Live labels durable.
- This feature does not remove one-time installed-profile choices from Re-transcribe/Re-diarize.
- This feature does not change application versioning or release packaging.
