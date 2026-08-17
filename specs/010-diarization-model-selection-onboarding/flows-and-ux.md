# Flows and UX: Diarization Model Selection and Onboarding

This document is normative for labels, control ownership, and state transitions.

## Product mental model

The UI communicates three separate questions:

1. **Models** — Which speaker models are downloaded on this Mac?
2. **Settings** — Which downloaded model should Homan use for new meetings?
3. **Final / Live controls** — Should speaker separation run in this context?

No screen uses `Automatic` as a model name. Automatic behavior is expressed naturally: when there
is only one downloaded model, Settings says it was selected automatically.

## 1. Models > Meeting speaker separation

Section intro:

> Optional local models analyze the system-audio side. Your microphone remains You.
>
> If one speaker model is downloaded, Homan selects it automatically. When multiple models are
> available, choose one in Settings.

Each card contains:

- name;
- concise capability (`Final only` or `Final + Live`);
- speaker-limit claim where applicable;
- revision, downloaded size when known, and license link;
- asset status and one applicable action.

The list and every displayed value come from validated catalog descriptors and asset state. The
view contains no current model names/IDs and does not assume how many models exist.

### Card states

```text
<Model name>                                         Not downloaded
<Catalog description>
<Capabilities> · Revision … · License
                                                [Download]
```

```text
<Model name>                                         Downloading
<Catalog description>
<Capabilities> · Revision … · License
[=================             ] 47%
```

```text
<Model name>                                         Downloaded
<Catalog description>
<Capabilities> · Revision … · 246 MB · License
                                                  [Remove]
```

```text
<Model name>                                    Needs attention
Homan couldn't finish setting up this model.
                                     [Retry]    [Remove]
```

```text
<Model name>                                   Update available
An updated model is available.
                                     [Update]   [Remove]
```

```text
<Legacy model name>                         No longer supported
This model can't be used by this version of Homan.
                          [Get replacement]   [Remove]
```

Forbidden card terms/actions:

- `Used by Automatic`;
- `Active` or `Final default`;
- `Use for Final` / `Set as Final default`;
- any storage path, cache/package terminology, or manual cleanup instruction.

After Download/Retry reaches validated ready state, the selection coordinator runs. The Models
card remains `Downloaded`; it does not animate into an `Active` configuration state.

## 2. Settings > Meetings > Speaker separation

Recommended row order:

1. `Analyze remote speakers in Final` toggle;
2. `Speaker separation model` state/picker;
3. `Live speaker analysis by default` toggle and capability message.

Final and Live descriptions retain microphone=`You`, system-only analysis, and independence from
the chosen ASR provider.

### Zero downloaded models

```text
Speaker separation model     No model downloaded   [Open Models]
```

Final and Live switches are disabled with help:

> Download a speaker separation model in Models first.

Stored enablement preferences may be retained internally when the last model is removed, except an
unsupported Final-only selection always normalizes Live Off. No processing run is attempted without
a ready captured profile.

### One downloaded/selectable model

```text
Speaker separation model     <Model name>
                             Selected automatically — only downloaded model
```

There is no popup arrow. Installing any additional selectable model creates a real choice and
changes this row into a picker without switching the current model.

### Two or more downloaded/selectable models

```text
Speaker separation model     [<Selected model>                ▾]
```

Menu:

```text
✓ <Selected model>      <Capabilities/constraints>
  <Another model>       <Capabilities/constraints>
  <Additional model>    <Capabilities/constraints>
```

Changing the picker applies to future meetings and normal Settings-following retries. It does not
mutate an active meeting or a captured recovery run.

If there are multiple choices but no valid prior/legacy selection, the row shows `Choose a model`
and Final/Live controls remain unavailable until the user chooses. Homan never guesses from a model
name, array position, or current recommendation.

### Selected model does not support Live

The Live row renders:

```text
Live speaker analysis by default        [Off, disabled]
This model doesn't support Live speaker diarization
```

The exact required sentence is shown next to/below the Live control at the same visual hierarchy
as other setting constraints. Selecting any Final-only model turns the global Live-speaker default
Off; there is no hidden pending On state. This is capability-driven and applies to every
current/future Final-only descriptor; Offline quality is the current example.

### Selected model supports Live

The Live row is enabled and shows any catalog constraint such as a remote-speaker limit. Changing
Live does not change Final or the selected model.

## 3. Active meeting > Live

The active meeting uses the profile captured when that meeting began.

### Captured model supports Live

`Separate remote speakers` is available independently of Live ASR. It may be turned On/Off/On per
the existing epoch rules. The UI may show the captured descriptor's localized name as secondary
context but has no model picker.

### Captured model does not support Live

`Separate remote speakers` is disabled and the Live area shows exactly:

> This model doesn't support Live speaker diarization

Starting Live ASR remains available; its system text stays `Others`. Homan must not load another
model as a fallback.

### Captured unavailable model

If the asset disappears/fails after capture, enabling Live produces a non-blocking, dismissible
status and leaves recording/Live ASR operational. It does not start a download.

## 4. Final, Re-transcribe, and Re-diarize

- Final default uses the shared captured concrete profile when Final is enabled.
- Per-meeting `Follow Settings / On / Off` remains unchanged.
- Re-transcribe speaker options list `Keep existing analysis`, `Use meeting setting`, `Off`, and
  concrete ready installed profiles as one-time actions.
- Analyze speakers again lists concrete ready profiles only.
- One-time choices do not change Settings and may differ from the shared global selection.
- Old meetings may display historical provenance `Automatic — Offline quality`, but Automatic is
  not offered as a new action.

## 5. Onboarding Wizard model step

The existing step remains step 1. Heading:

> Choose your models

Subheading:

> Parakeet is included for transcription. You can prepare optional models now or add them later in
> Models.

### Transcription section

Retain existing Parakeet and optional ASR cards and Cohere language control. Their functional
behavior is unchanged except they participate in the durable plan.

### Speaker separation section

Visible only when the selected use case includes Meetings:

```text
SPEAKER SEPARATION (OPTIONAL)
Separate remote participants in meeting transcripts. Your microphone stays You.

(•) Not now
( ) <Catalog model>     Recommended (only when descriptor says so)
    <Catalog-derived capabilities and constraints>
( ) <Catalog model>
    <Catalog-derived capabilities and constraints>
( ) … future eligible catalog entries …
```

The cards are mutually exclusive. Recommended is a badge, not a preselected download. If an asset
is already ready, its card adds `Downloaded`; selecting it performs no network work.

A non-Live descriptor does not need the Live Settings sentence on this card, because its `Final
only` capability is explicit. If the Wizard includes a Live-default control in the future, that
control must use the exact required incompatibility sentence.

### Button behavior

- No selected items need download: `Continue`.
- Any selected item is not ready: `Download & Continue`.
- Pressing it starts/updates one app-owned preparation plan, then advances as today.
- Selecting `Not now` never removes an already downloaded model; it only removes the Wizard's
  unstarted diarization plan item.

The Wizard does not silently enable Final or Live. It prepares and selects a concrete model after
validation; the user controls enablement in Settings/per meeting.

## 6. Preparation progress

The floating indicator and model-test preparation area show the current item:

```text
Preparing models
Downloading <Model name> (2 of 3) · 47%
```

Phase changes:

```text
Checking <Model name> (2 of 3)
Downloading <Model name> (2 of 3) · 47%
Setting up <Model name> (2 of 3)
<Model name> ready (2 of 3)
```

Never display `47% of all models`; model sizes/providers are not comparable. Throttle percentage
announcements for VoiceOver.

### Failure

Required transcription model:

```text
Transcription model setup paused
[Retry]
```

Optional diarization model:

```text
Speaker model download paused
Check your connection and retry. You can continue without speaker separation.
[Retry] [Continue without speaker separation]
```

If setup was interrupted or local state is not usable:

```text
Homan couldn't finish setting up this model.
[Retry]
```

No technical storage detail or manual cleanup instruction is shown. Retry lets Homan decide whether
to resume, validate, roll back, quarantine, or replace its own data.

## 7. Relaunch and ownership transfer

- Wizard saves selected diarization intent and the ordered plan before starting work.
- On relaunch, percentages are hints only. Each item first displays `Checking…` while its
  authoritative store validates it.
- If onboarding completes during preparation, the global status indicator keeps the same active
  item and `n of m`; progress does not reset to the primary transcription model.
- A Ready notification names the item that became ready. The final notification says all selected
  models are ready.

## 8. Selection transition messaging

Avoid noisy banners for expected rules. Settings reflects the result. Use a brief toast only when a
user action has an indirect but important consequence:

- removing the selected model and leaving exactly one selectable model:
  `<Removed model> removed. <Remaining model> is now selected.`
- selecting any Final-only model while Live default was On:
  `Live speaker diarization was turned off because <Selected model> supports Final only.`
- removing the selected model while several alternatives remain:
  `<Removed model> removed. Choose a speaker separation model in Settings.`

Startup legacy migration is silent unless no model is available; then Settings shows its ordinary
zero-ready state.

## 9. Model updates and retirement

### Update

`Update` is a normal card action. While it runs, the card says `Updating`; the existing working
revision remains usable until Homan finishes and validates the update. If it fails:

```text
Couldn't update <Model name>. Your current version is still available.
[Retry]
```

The user never uninstalls/reinstalls or manipulates local storage to update.

### Deprecated but supported

The card says `Legacy model`, explains that a newer option is available when the descriptor has a
replacement, and offers the normal app-owned actions. It is not recommended in onboarding. Homan
does not remove it automatically or invalidate old meetings.

### No longer supported

The card remains visible only when Homan owns an installed legacy asset. It is not selectable. The
user can choose `Get replacement` or `Remove`; both are application operations. If no replacement
is declared, only `Remove` is offered. Completed transcripts/evidence remain untouched.

## 10. Accessibility and layout acceptance

- `Model category` segmented control remains label-hidden visually and correctly labelled for
  VoiceOver (existing fix retained).
- Model cards do not horizontally compress status/accessibility labels at minimum supported window
  width.
- The onboarding model page remains vertically scrollable at 640×520 and on smaller visible-screen
  heights; bottom navigation never leaves the visible frame.
- Live incompatibility copy wraps to two lines rather than truncating.
- Every disabled control exposes its reason via accessibility help.
