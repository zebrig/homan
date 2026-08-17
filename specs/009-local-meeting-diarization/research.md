# Research: Local Meeting Diarization

## Executive finding

Homan does not lack diarization code. It has three generations of diarization available through
FluidAudio, but production still instantiates only the oldest online pipeline:

```swift
let diarizer = DiarizerManager()
let models = try await DiarizerModels.download(...)
diarizer.initialize(models: models)
```

There are no Homan call sites for `SortformerDiarizer`, `SortformerModels`, `balancedV2_1`,
`highContextV2_1`, `LSEENDDiarizer`, or `OfflineDiarizerManager`. The unused Sortformer symbols are
therefore working dependency APIs and presets, not dormant Homan models. A preset selects static
tensor shapes and a matching downloadable CoreML asset; it does not activate itself.

The safe design is not to replace one concrete class inline. Homan needs an ASR-independent local
diarization stage, an engine-neutral artifact, explicit resource scheduling, and finer timestamps
from Homan Whisper. The shipping final-quality default should be chosen by Homan-specific
benchmarks. Existing evidence makes Offline Community-1/VBx the leading default candidate and
Sortformer `balancedV2_1` a useful opt-in stable-four-speaker profile.

## Current Homan behavior

### What works

- New meetings retain raw microphone and system sources separately.
- AEC uses system as reference and modifies only a disposable microphone derivative.
- Final, recovery, and Re-transcribe share `MeetingTranscriptionPipeline`.
- Microphone is authoritatively `You`; system is `Others` or a remote label.
- Optional diarization failure already degrades to `Others`.
- Processing progress is durable and shared by list/detail views.

### What is structurally wrong

1. `TranscriptionCoordinator` owns a concrete `DiarizerManager`, so engine choice cannot be made or
   recorded as a policy.
2. `preloadMeetingHelpers()` loads the legacy diarizer together with VAD, even for Homan Whisper,
   but `MeetingTranscriptionPipeline` explicitly skips using it when Homan Whisper is selected.
3. Diarization runs independently for every recording unit, then speaker numbers are reconstructed
   from first appearance inside each unit. `Speaker 1` is not meeting-global.
4. The full system WAV is converted to `[Float]` before the legacy diarizer runs. Long recordings
   receive no disk-backed or bounded-memory diarization contract.
5. The result is ephemeral. Speaker activity is immediately folded into transcript turns, so a
   later ASR change repeats diarization and provenance is lost.
6. Persisted progress has no diarization phase; audio staging has a separate `.diarizing` marker,
   but that is not the canonical UI progress model.
7. `TranscriptFormatter` assigns an entire ASR segment to one speaker by maximum time overlap. It
   cannot split a coarse 30-second remote ASR item across several diarization turns.

### Lifecycle audit findings that change the product design

- `MeetingSession.stop`, `MeetingFinalProcessingService`, and Re-transcribe all receive a final
  formatted string from `MeetingTranscriptionPipeline`; none persists `AttributedTurn`, source ASR
  spans, or diarization activity.
- The staging state is marked `diarizing` only after the pipeline has already returned, so current
  progress is cosmetic rather than tied to real diarizer execution.
- `MeetingProcessingOperation.phases` is static. It cannot truthfully express Off, reuse, rerun, or
  standalone Re-diarize without a run-specific phase plan.
- Re-transcribe currently always asks the same pipeline for `.optionalPost`, immediately
  re-summarizes, and atomically replaces only flat transcript/notes. ASR and speaker policy cannot
  be selected independently.
- The meeting detail view allows direct editing of the whole flat transcript. Regenerating labels
  from an artifact would overwrite those edits unless Manual becomes a separate presentation.
- Summary backends receive only the flattened transcript string. The default system prompt already
  maps `You` to `config.userName` and `Speaker N`/`Others` to remote system audio, but summary
  metadata does not record which transcript presentation/digest it used.
- Raw audio retention defaults to seven days, while transcript retention defaults to sixty days.
  Attaching diarization metadata to audio deletion would break reversible labels long before the
  transcript disappears.
- CloudKit and text backup currently carry the materialized transcript only. A new reversible
  representation must be additive and old-client readable.
- Live ASR has an explicit restartable generation/state and separate microphone/system engines, but
  all system captions are hard-coded to `Others`. Crash checkpoints store a speaker string and are
  used as recovery fallback; provisional Live speaker labels must not be written there.
- Audio import is a second, separate pipeline: it calls the legacy concrete diarizer directly over
  one mixed WAV and skips diarization for Homan Whisper. It must converge on the common evidence and
  provider contracts, while preserving the fact that an imported mixed file has no authoritative
  `You` source.

These findings rule out a one-line switch from `DiarizerManager` to `SortformerDiarizer`. The first
architectural deliverable is durable structured evidence and reversible presentation, not a model
replacement.

### Homan Whisper timestamp limitation

The current batch response contains one result per VAD item:

```text
id, source, start, end, text
```

`start` and `end` are the submitted VAD item's outer bounds, not necessarily the model's inner
sentence/word bounds. Items may be up to about 30 seconds. Local diarization can detect several
speakers within that item, but Homan has no evidence for dividing the returned text among them.
Removing the `backend != homanWhisper` condition alone would therefore make diarization run, but
would not make the attribution correct.

Decision: extend the server response backward-compatibly with optional inner timestamped ASR
segments. The server remains ASR-only. Old responses remain valid and receive coarse/dominant or
generic attribution.

## Engine inventory

### 1. Current `DiarizerManager` (Pyannote 3.1 + WeSpeaker)

**Type**: legacy online segmentation, embeddings, and incremental clustering.

**Strengths**:

- already integrated and tested in Homan;
- no fixed speaker limit;
- modular speaker database and enrollment are comparatively easy;
- useful as a rollout fallback.

**Weaknesses**:

- FluidAudio describes it as its slowest and most computationally heavy online diarizer;
- fragile on noise, short turns, overlap, and similar voices;
- requires larger chunks and external alignment for sliding-window use;
- it is being used for a final whole-recording task even though FluidAudio has a dedicated offline
  quality pipeline.

**Decision**: retain temporarily as compatibility fallback; do not make it the new Automatic
profile and do not run it as a hidden second opinion.

### 2. `OfflineDiarizerManager` (Community-1 + WeSpeaker + PLDA/VBx)

**Type**: whole-file offline segmentation, embedding extraction, global clustering, and timeline
reconstruction.

**Strengths**:

- FluidAudio's recommended offline-quality route;
- no fixed four-speaker ceiling and optional speaker-count constraints;
- file API is disk-backed/memory-mapped rather than requiring one full `[Float]` buffer;
- global clustering is a strong fit for Final and for several recording units;
- progress callbacks and cooperative cancellation exist in the relevant processing loops;
- published FluidAudio v0.15.5 AMI-SDM benchmark: 10.6% average DER at threshold 0.7 on Apple M5
  Pro; VoxConverse default-speed profile: 15.07% average DER at about 122x real time.

**Weaknesses**:

- several models and a multi-stage pipeline increase model-management surface;
- quality depends on domain-sensitive clustering thresholds and speaker-count constraints;
- v0.15.1 predates later deterministic K-Means, zero-vote re-embedding, and compute-unit fixes;
- not suitable for low-latency Live labels.

**Decision**: leading candidate for Automatic Final quality after Homan's RU/PL/EN benchmark. Use
a versioned Homan profile rather than exposing raw clustering parameters.

### 3. `LSEENDDiarizer`

**Type**: end-to-end online diarizer with up to ten output speakers.

**Strengths**:

- supports more speakers than Sortformer;
- lightweight model and strong overlap/quiet-speech recall;
- FluidAudio positions it as the default online diarizer;
- published AMI-SDM benchmark is about 20.7% average DER at about 74.5x real time on an M4 Max CPU.

**Weaknesses**:

- more false alarms and less stable speaker identity than Sortformer;
- weaker speaker enrollment when voices are similar;
- primarily useful for provisional Live, which is deliberately delivered after Final correctness.

**Decision**: do not add it to the first user-facing Final selector. Keep the provider architecture
capable of supporting it in a future Live-diarization specification.

### 4. `SortformerDiarizer` + `SortformerModels`

**Type**: CoreML port of NVIDIA Streaming Sortformer 4-speaker v2.1. The model directly returns a
speaker-activity probability matrix at 80 ms resolution and maintains an arrival-order speaker
cache across chunks.

**Strengths**:

- stable speaker slots over a long stream;
- handles noise and overlap better than the legacy online pipeline;
- one end-to-end model, no separate clustering stage;
- same streaming API can process a complete buffer;
- strong candidate when participant focus and slot stability matter and there are at most four
  remote speakers.

**Weaknesses**:

- hard maximum of four; five or more are missed or merged;
- common error is missed quiet/distant speech because background conversations are intentionally
  suppressed;
- predominantly English training may degrade RU/PL and other non-English meetings;
- slots are arrival-order labels, not identities and not persistent people;
- v0.15.1 lacks later cancellation, model/config validation, precision control, and safer compute-
  unit selection.

**Decision**: expose through a Homan profile only after FluidAudio prerequisite work and local
benchmarks. The first candidate profile is `balancedV2_1`.

## What the Sortformer presets actually mean

The following values are compiled into different CoreML tensor shapes. They cannot be mixed with a
different asset or independently tuned safely.

| Homan relevance | FluidAudio preset | Core frames | FIFO | Nominal output latency | Evidence and trade-off |
|---|---|---:|---:|---:|---|
| Candidate | `fastV2_1` / default | 6 | 40 | 1.04 s | smallest recent context; adequate for Live, no demonstrated Final advantage |
| Recommended Sortformer candidate | `balancedV2_1` | 6 | 188 | 1.04 s | larger FIFO, NVIDIA AMI-SDM 20.57% DER; best documented low-latency v2.1 profile |
| Experimental | `highContextV2_1` | 340 | 40 | 30.4 s | much larger chunk and asset; official NVIDIA high-latency AMI-SDM 17.8%, but FluidAudio's CoreML AMI runs report materially worse results than Community-1 and no consistent advantage over balanced |

`highContextV2_1` is not synonymous with "full quality". In the currently checked-out FluidAudio
documentation, balanced is explicitly the best AMI-SDM preset (20.6% DER), while the high-context
CoreML benchmark is 31.7% DER. FluidAudio v0.15.5 reports newer streaming high-context results around
26.4% DER versus 56.7% for its extremely fast stateless offline Sortformer. These figures differ by
artifact and harness, which is itself a reason to benchmark the exact shipping asset in Homan.

The newer `OfflineSortformerDiarizer` in FluidAudio v0.15.5 is not a better replacement for long
meetings: it independently processes 30.72-second windows and loses global speaker identity.
FluidAudio documents 56.7% DER on AMI-SDM, with the entire gap caused by speaker confusion. It is
appropriate only for short clips or throughput-bound batch work and is rejected for Homan Final.

## Dependency prerequisite

Homan pins FluidAudio exactly at 0.15.1. The latest official release found during this research is
0.15.5 (2026-07-07). Relevant changes after 0.15.1 include:

- cooperative Sortformer cancellation before expensive inference calls;
- validation that runtime config matches model-embedded static shapes;
- BNNS-fixed v3 Sortformer assets;
- fp16 versus 6-bit palettized precision control;
- compute-unit selection and low-memory protection for large high-context models;
- deterministic and more robust Offline VBx re-clustering;
- zero-vote span re-embedding;
- honoring caller compute-unit configuration for offline models;
- additional progress support.

Decision: do not wire Sortformer on the 0.15.1 API and call the work complete. First isolate and
validate a FluidAudio upgrade in its own commit and regression matrix. Version range updates are
not acceptable; pin the tested exact version and exact model artifact revisions.

## Quality comparison and intended use

| Engine/profile | Final quality | Speaker capacity | Quiet/distant speech | Identity stability | Resource behavior | Intended Homan role |
|---|---|---:|---|---|---|---|
| Offline Community-1/VBx | strongest published final candidate | inferred, configurable | generally better coverage | global clustering | multi-model, fast offline, disk-backed | Automatic/Offline quality |
| Sortformer balanced v2.1 | medium; must validate RU/PL/EN | 4 hard max | may miss it | strongest streaming slots | one substantial CoreML model, chunk-cancellable after upgrade | Stable up to 4 |
| LS-EEND | medium online | 10 | strongest of online options | less stable/false alarms | light CPU-oriented model | future Live option |
| Legacy DiarizerManager | weakest/fragile online | no fixed max | variable | manipulable database | slow/heavy online pipeline | temporary fallback only |
| Offline Sortformer v0.15.5 | poor long-meeting identity despite speed | 4 hard max | same detection as streaming | resets/confuses across windows | extremely fast fused windows | rejected for long Homan meetings |

Published DER values are not Homan acceptance values. Homan's system track is digitally captured,
often multilingual, may include media playback, and is processed separately from the microphone.
The benchmark gate must include real Homan-like data and evaluate missed speech, speaker confusion,
false alarms, speaker-count error, and ASR attribution—not only aggregate DER.

## Architectural decisions

### Decision: Homan is the sole diarization orchestrator

- The Mac runs and owns diarization.
- Local and remote ASR providers return timestamped text only.
- The server never becomes a second speaker-label authority.
- This keeps retries, artifacts, settings, progress, retention, and provider changes in one place.

### Decision: diarization is a sibling of ASR, not a method on the ASR provider

After the prepared system timeline exists, ASR and diarization are independent operations joined by
the attribution stage. A provider ID must never decide whether diarization is eligible.

### Decision: one logical system timeline per processing run

Render all source-aware system units into one disposable timeline with a reversible unit-offset map.
This lets Offline Community-1 cluster globally and lets streaming Sortformer keep one cache over the
whole run. Unit-local ASR timestamps are mapped into the same coordinate space before attribution.

### Decision: artifact first, text attribution second

The diarizer publishes timed speaker activity and provenance. A separate aligner combines it with
ASR timestamps. This permits ASR-only retries, makes coarse timestamp degradation explicit, and
keeps overlapping activity rather than destroying it during model execution.

### Decision: resource scheduling is explicit

- capture and audio-device continuity always win;
- Live local inference wins over background final processing;
- remote ASR may overlap local diarization because the heavy work is on different machines;
- local ASR and local diarization use a single coordinator policy, normally sequential on memory-
  constrained systems;
- cancellation occurs between bounded chunks, never by freeing a model under active inference;
- model unload happens only after the owning operation has joined all tasks.

The first production implementation is intentionally sequential for heavy local stages. Remote
ASR/local diarization concurrency can be added later under one parent run after the dynamic progress
and cancellation contract is proven. This avoids turning an optimization into a second processing
workflow.

### Decision: no silent ensemble

Automatic maps to one versioned profile. Running Community-1 and Sortformer and selecting/voting
would double work, complicate cancellation, and require a calibrated confidence model that does not
exist. An ensemble can be researched separately with its own measurable benefit.

### Decision: user settings express intent, not tensor parameters

Normal settings expose Final enablement, Automatic/Offline-quality/Stable-up-to-4 profiles, a
separate Live-by-default toggle, and installed assets. Thresholds, FIFO/cache lengths, model
precision, and compute units are profile implementation data. A diagnostics export records them for
support.

### Decision: microphone is never diarized

The canonical microphone track is one local app owner and always maps to `You`. Only the system
track is diarized. This makes source role deterministic, keeps echo/AEC concerns separate, and
prevents an acoustic model from moving local speech to a remote participant or vice versa.

### Decision: labels are a reversible presentation

Persist ASR spans, acoustic activity, and their attribution independently. `Separated` and `Others`
are projections; a user edit is a separate `Manual` presentation. The active projection continues
to materialize into `raw_transcript` for compatibility. This makes a bad diarization recoverable in
one click without inference and without deleting manual edits.

### Decision: Final, meeting, and Live scopes are independent

- global Settings define Final default/profile and Live-by-default separately;
- a meeting stores Follow Settings/On/Off for Final and future retries;
- Re-transcribe can reuse/rerun/disable diarization once without changing defaults;
- standalone Re-diarize reuses ASR and does not call summary;
- active Live uses a session-only toggle and provisional state, never Final evidence.

### Decision: summary consumes the active role projection with provenance

Homan deterministically renders the active transcript and a speaker legend before calling any LLM.
The summary run records transcript/attribution revision, presentation mode, digest, and configured
owner name. Changing presentation marks notes stale and requires explicit Re-summarize; the LLM is
not asked to fix or infer diarization.

### Decision: speaker metadata follows transcript retention

Audio expiry removes raw/retained media and disposable renders but keeps structured text and
speaker activity. Transcript expiry removes ASR, diarization, attribution, generated/manual
presentations, and the materialized transcript together. Meeting deletion cascades everything.

## Sources

- FluidAudio v0.15.1 source and documentation in the pinned SwiftPM checkout.
- FluidAudio v0.15.5 release and benchmark documentation:
  https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.5
- FluidAudio diarization guide:
  https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md
- FluidAudio benchmarks:
  https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md
- FluidAudio CoreML Sortformer artifacts:
  https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml
- NVIDIA Streaming Sortformer 4-speaker v2.1 model card and published evaluation:
  https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
