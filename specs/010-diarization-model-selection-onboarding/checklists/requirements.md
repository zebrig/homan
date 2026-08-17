# Specification Quality Checklist: Diarization Model Selection and Onboarding

**Created**: 2026-08-17

**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] User value is separated into asset availability, model choice, and enablement.
- [x] Exact required Live incompatibility copy is specified.
- [x] User-facing Automatic/default/use terminology is explicitly removed.
- [x] Scope relative to implemented specification 009 is explicit.
- [x] No implementation, build, commit, push, or release is implied by document creation.

## Requirement Completeness

- [x] Zero/one/many ready-model resolution is deterministic and has no model-name fallback.
- [x] Install-additional, update, deprecate, retire, remove-selected, remove-last, retry, rollback,
  relaunch, and tombstone transitions are defined.
- [x] Non-ready/unsupported assets never count as selectable.
- [x] One shared concrete Final/Live model and independent enablement are reconciled.
- [x] Capabilities/constraints are descriptor-driven; current Offline/Stable fixtures remain explicit.
- [x] Settings and active-meeting Live behavior are both specified.
- [x] New-run concrete capture and Settings-after-start behavior are specified.
- [x] Legacy Automatic config, manifests, and evidence are distinguished.
- [x] Per-meeting/one-time overrides remain supported.
- [x] Models is constrained to asset management only.
- [x] Onboarding visibility, Not now, single-choice, ordering, progress, failure, retry, skip, resume,
  and ownership transfer are specified.
- [x] Onboarding schema migration and authoritative readiness source are specified.
- [x] Optional download does not silently enable Final/Live.
- [x] Capture/install mutual exclusion and no-surprise-download rule are preserved.
- [x] No new telemetry/network/audio path is introduced.
- [x] Accessibility and constrained-window behavior are included.
- [x] Every user-visible recovery is an app action and no storage/file instruction is permitted.
- [x] Model revision update retains the last-known-good asset until atomic activation succeeds.
- [x] Retirement never deletes meeting evidence or silently removes a validated installed model.

## Architecture Checks

- [x] Selection is one pure resolver plus one serialized coordinator.
- [x] Open stable IDs and a versioned descriptor catalog replace UI raw-ID/name conditionals.
- [x] Adding a descriptor using an existing adapter requires no Models/Settings/onboarding/resolver
  change; new engines require only an allowlisted adapter plus descriptor.
- [x] Catalog schema, adapter, aliases, lifecycle, replacements, and safe fallback are validated.
- [x] Existing config key can remain compatible while new semantics use a shared accessor.
- [x] Live accepts the captured profile and cannot silently substitute an engine.
- [x] Onboarding uses the production asset store rather than a duplicate downloader.
- [x] Plan IDs/attempts and owner transfer prevent stale callbacks and duplicate tasks.
- [x] Item-local progress avoids false cross-model percentages.

## Open Approval Gates

- [ ] Owner approves the full 010 specification package.
- [ ] Owner approves `Not now` as the initial onboarding diarization choice (no implicit download).
- [ ] Owner approves catalog metadata as the source of onboarding recommendation/order.
- [ ] Owner approves normalizing Live default Off whenever the selected descriptor lacks Live support.
- [ ] Owner authorizes implementation after plan approval.

## Notes

- `.automatic` remains necessary internally for old data even though it disappears from new UI.
- The existing persisted profile key may keep its Final-oriented name during the first patch to
  reduce migration and downgrade risk.
- Installing a model selects it when it is the sole ready model, but never enables analysis by
  itself.
- Quality benchmarking and default rollout remain governed by specification 009.
