# Specification Quality Checklist: Local Meeting Diarization

**Created**: 2026-08-16

**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] User value and failure behavior are explicit.
- [x] Existing raw-audio/source-role contracts are preserved.
- [x] Final-first delivery and independent provisional Live milestone are explicit.
- [x] Research distinguishes library claims from Homan acceptance evidence.
- [x] No production implementation is implied by document creation.

## Requirement Completeness

- [x] ASR/provider independence is testable.
- [x] Homan Whisper timestamp limitation and backward-compatible remedy are defined.
- [x] Multi-unit speaker namespace is defined.
- [x] Artifact reuse/invalidation/atomicity are defined.
- [x] Progress, cancellation, scheduling, and model lifecycle are defined.
- [x] Sortformer four-speaker ceiling and quiet-speech risk are explicit.
- [x] `balancedV2_1` and `highContextV2_1` are not treated as equivalent quality levels.
- [x] Legacy, missing-source, and no-model fallbacks are defined.
- [x] Privacy, diagnostics, model licensing, and retention are defined.
- [x] Global, per-meeting, one-time, and Live override scopes are defined.
- [x] Microphone-as-single-owner and system-only diarization are invariant.
- [x] Re-transcribe reuse/rerun/off and standalone Re-diarize are distinct.
- [x] Separated/Others collapse is reversible and requires no inference.
- [x] Manual transcript edits, summary staleness, and role prompting are defined.
- [x] Audio versus transcript retention and additive backup/sync are defined.
- [x] Run-specific progress avoids fake diarization phases.

## Open Approval Gates

- [x] Owner approved global Final/Live defaults, per-meeting policy, and transcript presentation UX.
- [x] Owner approved the exact FluidAudio upgrade before provider integration.
- [ ] Benchmark corpus and measurable Automatic thresholds are agreed.
- [ ] Exact shipping Automatic profile is selected from observed Homan results.
- [ ] Homan Whisper optional inner-segment response change is approved for server work.
- [x] Owner approved Final-first then provisional-Live rollout order.
- [x] Backup/CloudKit evidence-payload scope was approved before schema work.
- [x] Rollout/rollback implementation is approved; changing defaults still requires benchmark approval.

## Notes

- The specification deliberately recommends no immediate one-line switch to Sortformer.
- The first implementation concern is durable evidence/reversible presentation, then model choice.
- Offline Community-1 is the leading Final-quality candidate from current evidence.
- Sortformer `balancedV2_1` is the leading stable-four-speaker candidate.
- Sortformer balanced and LS-EEND remain candidates for the later provisional Live milestone.
- `highContextV2_1` remains experimental because its cost and CoreML benchmark quality do not
  justify exposing it as "full quality" today.
