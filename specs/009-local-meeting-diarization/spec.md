# Feature Specification: Local Meeting Diarization

**Implementation Branch**: `main` (working tree; not committed by this task)

**Created**: 2026-08-16

**Status**: Implemented behind opt-in Final and Live defaults; quality/default rollout gate pending

**Planned UX follow-up**: [Specification 010](../010-diarization-model-selection-onboarding/spec.md)
replaces the user-facing Automatic/Models/Settings selection model and adds onboarding download
planning. Until 010 is implemented, the behavior documented below remains the shipping behavior.

**Input**: "Run remote-participant diarization on the Mac under Homan's control, independently of
the selected transcription provider. Understand and deliberately integrate the currently unused
FluidAudio Sortformer engines and presets without weakening source roles, recovery, or existing
meeting processing. Make Final and Live enablement independently configurable; support per-meeting
and one-time retry overrides; preserve manual transcript edits; and make remote labels instantly
collapsible back to Others without rerunning ASR."

**Normative flow companion**: [flows-and-ux.md](flows-and-ux.md)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Separate remote participants consistently (Priority: P1)

As a user processing a source-aware meeting, I want the system-audio side split into stable remote
speaker turns while microphone speech remains authoritatively mine, regardless of whether final
transcription is local or remote.

**Why this priority**: Homan already preserves microphone and system sources, but the current
diarizer is a legacy streaming pipeline and Homan Whisper bypasses diarization completely. The
result therefore depends on the ASR provider rather than on the recording.

**Independent Test**: Process the same two-source fixture with two local ASR providers and Homan
Whisper. Verify identical `You` versus remote source roles, the same local diarization artifact,
and equivalent remote-speaker attribution when all ASR responses provide adequate timestamps.

**Acceptance Scenarios**:

1. **Given** a new meeting with microphone and system sources, **When** final processing runs with
   any supported transcription provider, **Then** microphone turns remain `You` and local
   diarization is applied only to the prepared system source.
2. **Given** Homan Whisper is selected, **When** its remote ASR response returns timestamped inner
   segments, **Then** local diarization is aligned to those segments exactly as it is for local ASR.
3. **Given** a diarizer is unavailable, cancelled, or fails, **When** transcription succeeds,
   **Then** the transcript completes with generic `Others`, a visible non-fatal warning, and a retry
   path; the prior transcript is not destroyed.
4. **Given** a meeting has several retained recording units, **When** it is processed, **Then** one
   meeting-level speaker namespace is used rather than independently restarting `Speaker 1` for
   every unit.

---

### User Story 2 - Control separation without coupling it to transcription (Priority: P1)

As a user, I want an on/off Final default, a per-meeting override, an independent Live toggle, and
one-time Re-transcribe/Re-diarize controls so that changing speaker labels never silently changes
my ASR model or application-wide settings.

**Why this priority**: The current code has one hard-coded `optionalPost` policy inside ASR and no
durable speaker artifact. A superficial toggle would either be ignored by Homan Whisper, restart
the wrong work, or mutate settings unexpectedly.

**Independent Test**: Exercise global On/Off, meeting Follow Settings/On/Off, Live on/off toggles,
ASR overrides, artifact reuse, explicit Re-diarize, and app relaunch. Verify the documented policy
resolution and that every override has exactly its intended scope.

**Acceptance Scenarios**:

1. **Given** Final separation is globally Off, **When** a recording is active, **Then** the user can
   set that meeting's Final policy to On without changing Settings.
2. **Given** Live separation is globally Off, **When** Live ASR is running, **Then** the user can
   start and stop provisional system-speaker labels while recording and Final policy is unchanged.
3. **Given** a compatible artifact exists, **When** Re-transcribe changes only ASR, **Then** the UI
   defaults to reusing speaker analysis and does not invoke the diarizer.
4. **Given** retained audio and structured ASR exist, **When** the user chooses Analyze speakers
   again, **Then** Homan reruns diarization without invoking ASR or summary.
5. **Given** a one-time ASR or diarizer override, **When** the run finishes, **Then** global and
   per-meeting defaults remain unchanged.

---

### User Story 3 - Correct bad labels without losing text (Priority: P1)

As a user, I want to collapse all remote `Speaker N` labels to `Others` instantly, restore the
separated view when useful, and keep any transcript text I edited manually.

**Why this priority**: Acoustic diarization is probabilistic. It must remain a reversible
presentation layer rather than permanently rewriting the only copy of a transcript.

**Independent Test**: Produce a separated transcript, switch to Others, switch back, create a
manual edit, switch among Manual/Separated/Others, delete the audio, and repeat. Verify no ASR or
diarizer call and no loss of words or manual text.

**Acceptance Scenarios**:

1. **Given** a separated transcript, **When** the user selects Others, **Then** only remote labels
   collapse, adjacent compatible turns are projected deterministically, and microphone stays You.
2. **Given** the artifact still exists, **When** the user returns to Separated, **Then** labels are
   restored immediately without audio or inference.
3. **Given** the user edited the flat transcript, **When** a generated view becomes active, **Then**
   the manual presentation remains saved and can be restored.
4. **Given** summary notes were produced from another presentation, **When** the active transcript
   changes, **Then** notes are marked stale and Homan offers Re-summarize without doing it silently.
5. **Given** audio retention deleted the recording, **When** the user changes presentation, **Then**
   stored text/evidence still works; only a new Re-diarize is unavailable.

---

### User Story 4 - Choose safe quality and resource behavior (Priority: P1)

As a user, I want a simple default that produces good final quality without making recording or
Live transcription unstable, while advanced users may choose another local diarization profile for
a particular type of meeting.

**Why this priority**: Sortformer profiles differ materially in speaker limits, latency, memory,
missed-speech behavior, and model assets. Exposing raw model names as equivalent choices would be
misleading and could create large downloads or long uninterruptible work.

**Independent Test**: Exercise Automatic, Offline quality, and Stable four-speaker profiles on a
representative Mac under idle, local-ASR, remote-ASR, and active-new-meeting conditions. Verify the
documented engine selection, progress, cancellation boundary, memory ceiling, and fallback.

**Acceptance Scenarios**:

1. **Given** the default Automatic profile, **When** final, recovery, or Re-transcribe runs, **Then**
   it uses the validated offline-quality engine and never silently runs multiple diarizers as an
   ensemble.
2. **Given** the Stable four-speaker profile, **When** a meeting has no more than four remote
   speakers, **Then** Homan may use Sortformer v2.1 with one configuration whose asset shapes match
   its runtime configuration.
3. **Given** the user expects five or more remote speakers, **When** selecting a profile, **Then**
   Homan does not present Sortformer as suitable and recommends the offline clustering profile.
4. **Given** a new recording or Live session begins during background diarization, **When** local
   inference resources are needed, **Then** capture remains uninterrupted and background
   diarization yields or is safely cancelled at a bounded checkpoint.
5. **Given** a required model is not installed, **When** processing begins, **Then** Homan never
   performs an unexplained download in the critical finalization path; it reports the missing asset
   and either performs the documented fallback or completes with `Others`.

---

### User Story 5 - Reuse and audit diarization safely (Priority: P2)

As a user re-transcribing a retained meeting, I want Homan to reuse a valid local diarization result
when only the ASR provider changes, and to rerun it automatically when its source, model, or
configuration is no longer equivalent.

**Why this priority**: Diarization is independent of ASR. Baking it only into transcript text wastes
work, hides provenance, and makes retries provider-dependent.

**Independent Test**: Diarize once, Re-transcribe with another ASR, change the diarization profile,
change a prepared-system source digest, and remove the artifact. Verify reuse only for the first
case and deterministic invalidation for the others.

**Acceptance Scenarios**:

1. **Given** an artifact whose source digest, timeline map, engine, model revision, and effective
   configuration still match, **When** Re-transcribe changes only ASR, **Then** the artifact is
   reused and its original provenance remains visible.
2. **Given** the AEC/preparation selection, system source, diarizer profile, model revision, or
   artifact schema changes, **When** processing runs, **Then** the prior artifact is ignored and a
   new one is produced atomically.
3. **Given** the application terminates during diarization, **When** it relaunches, **Then** no
   partial artifact is treated as complete and the persisted processing state offers a safe retry.
4. **Given** meeting audio is expired or manually deleted, **When** cleanup completes, **Then**
   disposable audio renders are removed but structured ASR, diarization, attribution, presentation,
   and manual transcript revisions remain until transcript retention expires.

### Edge Cases

- The system source contains one, four, five, or more remote speakers.
- Two remote speakers overlap; one ASR segment spans the speaker boundary.
- A quiet or distant participant is treated as background by Sortformer.
- A presentation, music, or prerecorded clip introduces voices that are not meeting participants.
- Remote participants leave and return, or a recording is paused and resumed into another unit.
- System audio is missing, silent, corrupt, or shorter than microphone audio.
- A remote ASR response has only VAD-item bounds and no timestamped inner segments.
- ASR produces word/token timestamps, coarse sentence timestamps, or text without timestamps.
- A diarizer reports no speech even though ASR produced text.
- Speaker labels change order between repeated model runs.
- A model download, compile, inference, or database write is cancelled.
- A new meeting begins while a prior meeting is transcribing, diarizing, or summarizing.
- The app runs on a low-memory Apple Silicon Mac or under high CoreML/ANE contention.
- An older Homan build opens a database containing a newer processing phase or artifact.
- Live separation is toggled on, off, and on again in one recording.
- Live ASR is stopped/restarted independently of Live separation.
- A crash-recovery checkpoint was captured while provisional Live speaker labels were visible.
- The user manually edited a transcript before Re-transcribe or Re-diarize.
- Audio has expired but the transcript and its role projections have not.
- The active transcript view changes after summary generation.
- Homan Whisper returns only coarse VAD-item bounds or optional fine inner segments.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Local diarization MUST be an ASR-independent meeting-pipeline stage and MUST NOT be
  disabled solely because the selected ASR provider is remote.
- **FR-002**: For source-aware recordings, local diarization MUST consume only a disposable system
  view derived from canonical system audio; it MUST NOT diarize the microphone to decide `You`.
- **FR-003**: Canonical microphone speech MUST remain `You`; canonical system speech MUST remain
  remote-side (`Others` or a numbered remote label) under every success and failure path.
- **FR-004**: Local diarization MUST run for Final, recovery, Re-transcribe, and standalone
  Re-diarize according to an immutable captured run policy.
- **FR-005**: Live diarization MUST be an independent, optional, provisional system-audio layer.
  Final remains authoritative and reruns from retained sources; Live labels MUST NOT become crash-
  recovery or Final evidence.
- **FR-006**: The default profile MUST select exactly one validated final diarizer. Automatic MUST
  NOT mean racing, voting, or sequentially ensembling multiple models.
- **FR-007**: Sortformer MUST be described and enforced as a maximum-four-speaker engine. It MUST
  NOT be automatically selected when the run explicitly expects more than four remote speakers.
- **FR-008**: A Sortformer model asset and runtime configuration MUST be a validated pair. Shape-
  defining values MUST NOT be user-editable independently of the corresponding asset.
- **FR-009**: `balancedV2_1` MAY be offered only as the validated low-latency/stable-identity
  Sortformer profile. `highContextV2_1` MUST remain experimental or hidden until Homan-specific
  benchmarks demonstrate a quality benefit that justifies its larger asset and 30.4-second chunk.
- **FR-010**: The legacy `DiarizerManager` MUST remain a compatibility fallback during rollout, not
  the default quality engine and not a second hidden pass.
- **FR-011**: Offline Community-1/VBx, Sortformer, and any future engine MUST conform to one local
  provider contract returning engine-neutral timed speaker activity.
- **FR-012**: The provider result MUST retain overlapping speaker activity. Attribution MAY reduce
  it for a particular ASR segment, but the canonical diarization artifact MUST NOT discard overlap.
- **FR-013**: Homan MUST NOT label Sortformer slots as persistent people. Numbered remote labels are
  scoped to one processing run and ordered deterministically by first accepted appearance.
- **FR-014**: All retained recording units in one run MUST share one logical system timeline and
  one speaker namespace. Per-unit offsets MUST be reversible and validated.
- **FR-015**: ASR text MUST be split or attributed across a speaker boundary only when the ASR
  provider supplies timestamps fine enough to support that split. Coarse responses MUST degrade
  honestly to dominant-speaker or generic `Others` attribution.
- **FR-016**: Homan Whisper MUST remain an ASR-only service. Its response contract MUST gain an
  optional backward-compatible list of inner timestamped ASR segments; it MUST NOT become a second
  diarization authority.
- **FR-017**: A completed diarization revision MUST include source and preparation fingerprints,
  engine and model provenance, effective configuration, timeline mapping, segments, timings, and
  completion state.
- **FR-018**: An artifact MAY be reused only when every correctness fingerprint matches. Reuse MUST
  NOT depend on ASR provider identity.
- **FR-019**: Artifact publication MUST be atomic. Cancellation, termination, or write failure MUST
  leave either the previous complete artifact or no complete artifact.
- **FR-020**: Diarization failure MUST be non-fatal to transcription. The completed meeting MUST
  expose a degradation and a retry action while preserving prior committed output on a failed
  Re-transcribe.
- **FR-021**: The persisted processing model MUST use one run-specific phase plan containing
  diarization and attribution only when effective; list, detail, recovery, and `N of M` MUST derive
  from the same state.
- **FR-022**: Progress MUST include model preparation and audio processing and MUST remain monotonic
  across recovery. A phase transition MUST not falsely report completion before artifact commit.
- **FR-023**: Capture has priority over all processing. Live local inference has priority over
  background final diarization. Resource scheduling MUST define bounded cancellation or yield
  points before rollout.
- **FR-024**: Remote ASR MAY run concurrently with local diarization when measured resource limits
  permit it. Local ASR and local diarization MUST use an explicit resource policy rather than
  contending accidentally for CoreML/ANE, CPU, and memory.
- **FR-025**: Required model assets MUST be versioned, integrity-checked, shown in Models settings,
  explicitly installable/removable, and accompanied by their license notice.
- **FR-026**: Model download or compilation MUST NOT start implicitly while recording is active.
- **FR-027**: Diarization configuration MUST be snapshotted per processing run. A one-time retry
  override MUST NOT mutate the global default.
- **FR-028**: Legacy mixed recordings MUST retain existing generic behavior in version 1. They MUST
  NOT gain false `You` versus remote guarantees.
- **FR-029**: Audio, transcript text, prompts, or credentials MUST NOT be added to telemetry or
  diagnostics. Local diagnostics MAY contain IDs, engine/model identifiers, durations, speaker and
  segment counts, resource policy, and categorized errors.
- **FR-030**: No new outbound data path is permitted except explicit model download and the already
  configured remote ASR operation.
- **FR-031**: Global Settings MUST independently expose Final speaker separation On/Off and Live
  speaker separation by default On/Off. Existing Live ASR enablement/model settings remain separate.
- **FR-032**: Every source-aware meeting MUST support a persistent Final policy of Follow Settings,
  On, or Off. It MUST be snapshotted for a run and MUST NOT be changed by a Live toggle.
- **FR-033**: The active recording UI MUST allow Live separation to be enabled or disabled at any
  time Live ASR can run, regardless of global defaults, without changing AppConfig.
- **FR-034**: Live diarization failure or unavailability MUST leave Live ASR, raw recording, and
  Final processing operational with generic Others.
- **FR-035**: Re-transcribe MUST expose ASR and remote-speaker policy as independent one-time
  choices: meeting default, compatible reuse, explicit rerun/profile, or Off.
- **FR-036**: Standalone Re-diarize MUST reuse persisted ASR spans, MUST NOT invoke ASR/title/summary,
  and MUST atomically preserve the active transcript on failure.
- **FR-037**: Homan MUST persist provider-neutral source-aware ASR spans separately from
  diarization activity and from rendered transcript text.
- **FR-038**: Homan MUST support active Separated and Others presentations without inference. If a
  user-edited transcript exists, Manual MUST be a separately retained presentation.
- **FR-039**: Collapse to Others MUST affect system turns only, be deterministic and reversible,
  and MUST NOT parse or rewrite the only stored copy of transcript text.
- **FR-040**: Audio cleanup MUST retain structured transcript/diarization/presentation revisions.
  Transcript-retention cleanup and meeting deletion MUST remove them under their respective scope.
- **FR-041**: Summary input MUST record the exact transcript revision, presentation mode, digest,
  owner name, and speaker legend. Re-summarize MUST use the currently active presentation.
- **FR-042**: Changing the active presentation MUST mark a summary based on another digest as stale
  and offer Re-summarize; it MUST NOT automatically call a local or remote LLM.
- **FR-043**: Summary prompting MUST identify `You` as the one local microphone speaker (and the
  configured owner name), `Speaker N` as anonymous remote system speakers, and `Others` as remote
  speech without usable separation. It MUST instruct the model not to infer identities.
- **FR-044**: A separated presentation MUST be selected automatically only when timestamp precision
  and attribution coverage satisfy a versioned quality gate. Otherwise the artifact MAY be retained
  while the active presentation remains Others.
- **FR-045**: Manual transcript edits MUST be retained across presentation changes and MUST receive
  an explicit warning before a new Re-transcribe presentation becomes active.
- **FR-046**: Backups and sync MUST keep the active materialized transcript backward-compatible and
  carry structured evidence through an optional versioned additive payload. A client without that
  payload MUST degrade honestly rather than claiming reversible speaker controls.
- **FR-047**: Imported single-track audio MUST migrate from its separate concrete-diarizer path to
  the common revision/provider/attribution flow. It MAY separate anonymous Speaker N labels but
  MUST NOT invent You or known remote-side source roles.
- **FR-048**: Homan Whisper MUST NOT suppress local diarization for imported mixed audio; the server
  remains ASR-only and the Mac applies the same optional local provider after ASR.
- **FR-049**: Existing flat imported meetings MUST remain readable as legacy-rendered text and MUST
  require one structured Re-transcribe before standalone Re-diarize/restore is advertised.

### User-facing controls

- **Final speaker separation**: On / Off global default.
- **Final quality profile**: Automatic (recommended), Offline quality, Stable up to 4 speakers.
- **Live speaker separation by default**: On / Off; recommended Off. Live ASR remains independent.
- **Per-meeting Final policy**: Follow Settings / On / Off.
- **Active Live toggle**: Separate remote speakers; session-only and always available when eligible.
- **Transcript presentation**: Manual (when present) / Separated / Others.
- **Analyze speakers again**: standalone installed-profile action without ASR.
- **Re-transcribe run options**: ASR backend plus Meeting default / Keep / Re-run / Off.
- **Installed model state**: asset revision, disk size, license, Install/Remove, and last error.
- Raw class names, `highContextV2_1`, thresholds, FIFO/cache sizes, CoreML compute units, and
  clustering constants are not normal controls; they belong to versioned profiles/diagnostics.

### Key Entities

- **Diarization Profile**: Stable user-facing intent mapped to one versioned engine configuration.
- **Diarization Run Snapshot**: Immutable effective selection and resource policy for one attempt.
- **Logical System Timeline**: Disposable continuous view plus reversible offsets for every retained
  system-audio unit in the meeting.
- **Diarization Artifact**: Small derived metadata product containing timed speaker activity and
  provenance; never canonical audio.
- **Transcript Revision**: Provider-neutral, source-aware, timestamped ASR evidence retained
  independently from rendered text and diarization.
- **Attribution Revision**: Versioned join between one transcript revision and an optional
  diarization revision, including ambiguity/precision evidence.
- **Transcript Presentation**: Active generated Separated/Collapsed or retained Manual text; the
  current raw transcript column is its backward-compatible materialized snapshot.
- **Summary Input Descriptor**: Exact transcript/presentation/digest and role legend used by notes.
- **Attribution Evidence**: ASR segment timestamps plus diarization overlap used to assign text to a
  remote label with an explicit confidence/precision class.
- **Model Asset Record**: Installed revision, digest, size, license, compatible profiles, and load
  state.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In deterministic source-aware fixtures, 100% of microphone turns remain `You` and 0%
  of system turns become `You` for every ASR/diarizer success and failure combination.
- **SC-002**: The same retained system source produces the same artifact digest and speaker-label
  order on three consecutive runs with identical engine, model, and configuration.
- **SC-003**: Re-transcribing with another ASR reuses a matching artifact with zero diarizer model
  invocations; changing any correctness fingerprint causes exactly one new diarization run.
- **SC-004**: Homan Whisper and local ASR produce equivalent speaker-boundary attribution on a
  reference fixture when both provide equivalent timestamp granularity.
- **SC-005**: Cancellation during every model-processing checkpoint leaves no complete partial
  artifact, no corrupted prior transcript, and a recoverable processing state.
- **SC-006**: Starting a new recording during background diarization loses zero captured frames and
  reaches recording-ready state within the existing recording-start budget.
- **SC-007**: On the agreed RU/PL/EN evaluation set, Automatic beats the current legacy diarizer on
  median DER and speaker-confusion error without increasing missed speech beyond the agreed gate.
- **SC-008**: Sortformer profiles never emit more than four remote labels and are never selected for
  an explicit More-than-4 run.
- **SC-009**: The complete test matrix covers local ASR, remote ASR, Final, recovery, Re-transcribe,
  cancellation, relaunch, multiple units, missing sources, and legacy recordings with no regression
  to current playback, retention, or source-role behavior.
- **SC-010**: Switching Separated -> Others -> Separated performs zero ASR/diarizer invocations,
  preserves every word and manual presentation, and completes within 200 ms for a four-hour fixture.
- **SC-011**: All global/meeting/one-time/Live policy combinations resolve deterministically and no
  one-time or Live action mutates global settings.
- **SC-012**: Re-diarize invokes exactly one diarizer and zero ASR/summary/title providers; failure
  leaves the active revision and summary unchanged.
- **SC-013**: Crash-recovery output never contains tentative Live `Speaker N` labels unless a Final
  or completed Re-diarize artifact independently produced them.
- **SC-014**: Summary provenance detects every presentation change and Re-summarize sends the exact
  currently active transcript digest with the correct owner/remote role legend.
- **SC-015**: Audio expiry leaves collapse/restore/manual presentation working; transcript expiry
  removes all structured transcript and speaker metadata with no searchable orphan text.

## Assumptions and Scope Boundaries

- Delivery is staged: Final/Homan Whisper/persistence/retry/summary correctness is milestone A;
  independent provisional Live enable/disable is milestone B on the same contracts. Milestone B is
  part of the feature but cannot block validating Final correctness.
- Remote speaker numbers are session-local labels, not names, biometrics, or cross-meeting identity.
- The system track may include prerecorded voices and other audible content. Homan separates
  acoustic speakers; it does not infer who was invited to the meeting.
- Accurate word ownership during simultaneous speech is bounded by the timestamp granularity and
  separation ability of the ASR result.
- Existing raw audio, AEC direction, source retention, playback, and deletion contracts remain
  unchanged. Structured speaker evidence follows transcript retention rather than audio retention.
- A benchmark gate, not a library README claim, chooses Homan's shipping Automatic profile.
