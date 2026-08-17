# Validation Quickstart: Diarization Model Selection and Onboarding

Use this after implementation. It is not an instruction to change the current app during the
planning phase.

## 1. Static checks

Verify that:

- `.automatic` still decodes and historical resolution remains Offline quality;
- a bundled catalog decodes into unique open stable IDs with valid adapters, lifecycle,
  capabilities, licenses, and non-cyclic replacements;
- current Offline and Stable descriptors retain their expected capability fixtures, without either
  name appearing in generic view/resolver branches;
- Models/Settings/MeetingDetail no longer use `MeetingDiarizationProfileID.allCases` for choices;
- new captures cannot persist `.automatic`.

Suggested searches:

```bash
rg -n 'Used by Automatic|Use for Final|Final default|Set as Final default' \
  native/MuesliNative/Sources/MuesliNativeApp

rg -n 'MeetingDiarizationProfileID\.allCases' \
  native/MuesliNative/Sources/MuesliNativeApp

rg -n 'offlineQuality|stableFourSpeaker|Offline quality|Stable up to 4' \
  native/MuesliNative/Sources/MuesliNativeApp/{ModelsView,SettingsView,OnboardingView}.swift
```

Expected: no forbidden user-facing term/action and no raw enum-driven choice list. Compatibility
definitions/tests may still contain current/legacy names.

## 2. Selection truth table

Run unit tests for:

| Ready/selectable set | Stored | Expected |
|---|---|---|
| none | any | unavailable |
| `{A}` | any | A, soleReady |
| `{A,B,…}` | valid B | B, storedPreference |
| `{A,B,…}` | legacy alias whose target is A | A, legacyAliasMigration |
| `{A,B,…}` | bad/nil/retired | choiceRequired |

Run this for synthetic catalogs of 0, 1, 2, 3, and 10 descriptors. Repeat each input twice and
assert the second reconciliation produces no config write.

## 3. Models state matrix

For every generated descriptor/lifecycle fixture:

1. absent -> Download;
2. downloading -> name + item-local percentage;
3. setting up -> no premature Downloaded state;
4. ready -> Downloaded + Remove;
5. newer revision -> Update; failed update retains current ready revision;
6. interrupted setup -> Needs attention + Retry;
7. deprecated supported -> Legacy model, not onboarding-recommended;
8. unsupported tombstone -> No longer supported + descriptor-driven replacement/remove;
9. Retry/Update/Remove -> app owns all storage recovery and shows no path/cleanup instruction;
10. capture active -> install/update/remove disabled with clear reason.

Confirm there is no Active/default/use action in any state.

## 4. Settings state matrix

1. No ready models: show No model downloaded + Open Models.
2. Install one Live-capable descriptor: static selection and sole-model helper; Live available.
3. Install two additional descriptors: retain selection and show all three in the picker.
4. Select any Final-only descriptor: Live turns Off/disabled and exact sentence appears.
5. Select any Live-capable descriptor: Live becomes available but remains Off until explicitly set.
6. Remove selected while exactly one remains: remaining model auto-selects.
7. Remove selected while several remain and no preference is valid: show Choose a model.
8. Remove last model: no selection; no processing attempt.

Required exact copy:

```text
This model doesn't support Live speaker diarization
```

## 5. New-meeting snapshot tests

For each selected profile:

1. start a meeting;
2. inspect captured manifest/run policy;
3. change Settings while recording;
4. toggle Live where eligible;
5. stop and let Final complete;
6. confirm the meeting used its captured concrete profile, not the later Settings value.

Any `supportsLive == false` case:

- Live control disabled with exact message;
- Live ASR remains usable and labels system text Others;
- no other model/adapter load occurs.

Any `supportsLive == true` case:

- Live may start/stop/restart;
- Final remains a separate authoritative pass;
- descriptor constraints such as a speaker limit are visible.

## 6. Historical compatibility

Open fixtures containing:

- AppConfig profile Automatic;
- captured raw manifest profile Automatic;
- completed diarization snapshot requested as Automatic;
- concrete current, deprecated, unknown, and future stable IDs;
- malformed profile value.

Assert only the future global AppConfig preference is materialized. Meeting/evidence records and
their effective configuration/model digests remain byte-for-byte unchanged.

## 7. Onboarding matrix

### Use cases

| Use case | Speaker separation section |
|---|---|
| Dictation | hidden |
| Voice notes | hidden |
| Meetings | visible |
| Dictation + Meetings | visible |

### Choice/download cases

For Meetings and combined:

1. Not now -> no diarization item/network request;
2. any offered descriptor absent -> queued after ASR, progress `n of m`, validates, becomes selected;
3. offered Final-only descriptor -> same, without enabling Live/Final;
4. selected model already ready -> no download, reconciliation only;
5. failed optional diarization -> Retry/Continue, onboarding remains completable;
6. relaunch during download -> Checking then authoritative resume;
7. finish Wizard mid-download -> same item/plan continues globally;
8. switch use case away from Meetings before start -> item removed, existing assets preserved.

Verify catalog recommendation metadata does not preselect a model or trigger download. Add a
synthetic third offered descriptor and verify onboarding displays it without view code changes.

## 8. Processing regression matrix

Run at least:

- local ASR Final with current Final-only and Live-capable descriptors;
- Homan Whisper Final with both capability classes;
- recovery after app quit during ASR and diarization;
- Re-transcribe Keep / meeting setting / concrete override / Off;
- standalone Analyze speakers again with each ready profile;
- start a second meeting while the first processes;
- collapse Separated to Others and restore;
- manual transcript + summary-staleness behavior;
- audio expiry with retained transcript evidence.

No behavior may diarize microphone audio or make Live evidence authoritative.

## 9. Catalog evolution matrix

Using synthetic bundled catalogs, verify:

1. add a descriptor using an existing adapter -> all three views show it without edits;
2. rename display metadata -> stored selection/evidence identity does not change;
3. deprecate a selected descriptor -> it remains usable but is not recommended;
4. retire it with a replacement -> it becomes unselectable and shows Get replacement/Remove;
5. remove active descriptor but keep tombstone -> installed legacy asset remains manageable;
6. create replacement cycle/duplicate ID/unknown adapter -> catalog is rejected safely;
7. update success -> atomic new revision; update failure -> prior revision remains ready;
8. leave abandoned staging state -> relaunch performs internal recovery with no user storage step.

## 10. Test commands

Use the repository's documented SwiftPM cache/build workflow. At minimum run targeted tests for:

```text
MeetingDiarizationSelectionTests
MeetingDiarizationProfileTests
MeetingLiveDiarizationTests
MeetingProcessingCaptureTests
OnboardingModelPreparationTests
OnboardingProgressTests
OnboardingFlowTests
ModelsTests
```

Then run the full native test suite and the signed Release build workflow. Do not publish or install
a release merely because targeted tests pass.

## 11. Signed app acceptance

After explicit implementation/build approval:

- Developer ID Application signature and Team ID validate;
- bundle remains `com.zebrig.homan` unless separately changed;
- existing AppConfig and downloaded assets survive installation;
- app launches without new permission/Keychain prompts;
- Model/Settings/onboarding copy matches this specification;
- no release version change occurs unless separately requested.
