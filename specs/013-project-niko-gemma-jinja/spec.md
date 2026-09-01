# Feature Specification: Project Niko — Gemma Jinja Chat Architecture

**Implementation branch**: `main` (owner-approved direct integration)

**Base**: `63dd769a`

**Created**: 2026-09-01

**Status**: Implemented; verification complete except for sandbox-blocked macOS media/pasteboard tests

**Input**: Replace Homan's accidental ChatML formatting for Gemma with the exact Jinja chat
template embedded in the selected GGUF. Keep summary language policy and model thinking as two
independent user settings. Prefer current externally published model revisions; do not pin model
SHA values as a product policy.

## Problem

`SummaryRuntime` currently calls `llama_chat_apply_template(nil, ...)`. In the public llama.cpp C
API this does not execute arbitrary embedded Jinja; for the installed Gemma 4 model it produces a
ChatML-shaped prompt. The model was trained with a richer Gemma template whose output changes with
`enable_thinking`, and whose whitespace is token-significant. Output cleanup then hides some of the
resulting protocol leakage while also collapsing Markdown layout. The UI cannot independently say
whether the summary language is model-selected, transcript-detected, or explicitly requested.

## User Scenarios & Testing

### User Story 1 — Render the model's real template (P1)

As a Gemma user, I want Homan to use the template shipped inside the exact GGUF it loaded so model
updates do not require a hand-copied prompt format.

**Acceptance scenarios**:

1. Given the installed Gemma 4 template, rendering system and user messages is byte-identical to
   Python Jinja2 for thinking on and off.
2. Given a compatible newer Gemma template, Homan compiles and preflights that template before use.
3. Given a missing, oversized, invalid, or unsupported template, Homan reports an explicit model
   compatibility error and never silently falls back to ChatML.
4. Given marker-looking text inside a Jinja string or user transcript, whitespace preprocessing
   does not reinterpret it as template syntax.

### User Story 2 — Choose summary language policy independently (P1)

As a user, I want the summary language to be chosen by the model, forced from transcript detection,
or specified by me as text.

**Acceptance scenarios**:

1. `Model decides` adds no forced language directive.
2. `Detect from transcript` detects a dominant language from bounded transcript text and adds an
   explicit language directive; uncertain detection falls back to model choice.
3. `Custom` adds the user's non-empty language instruction as data, with a bounded length.
4. Existing configurations decode to `Model decides` without migration failure.

### User Story 3 — Control thinking independently (P1)

As a user, I want a separate thinking toggle whose value is passed into the embedded Gemma template
without changing my language setting.

**Acceptance scenarios**:

1. Every language mode renders with thinking both enabled and disabled.
2. Thinking disabled is the default for existing and fresh configurations.
3. Thinking-channel output is stripped without destroying Markdown paragraph or list boundaries.

### User Story 4 — Preserve the legacy Qwen path (P1)

As a dictation user, I want the rarely used Qwen cleanup backend to remain behaviorally stable
while Gemma adopts Jinja.

**Acceptance scenarios**:

1. Qwen calls an explicit legacy ChatML renderer rather than inheriting Gemma template behavior.
2. Qwen tokenization and cleanup regression tests remain green.

## Functional Requirements

- **FR-001**: Gemma MUST obtain `tokenizer.chat_template` from the loaded model with
  `llama_model_chat_template` and compile that exact value.
- **FR-002**: Homan MUST use `huggingface/swift-jinja` at an exact reviewed code revision.
- **FR-003**: Jinja whitespace control MUST be normalized by a state-aware scanner before the
  dependency sees the template. A global regex rewrite is forbidden.
- **FR-004**: Gemma context MUST include `messages`, `add_generation_prompt`, `enable_thinking`,
  `preserve_thinking`, `tools`, `bos_token`, and `eos_token` with correct Jinja value types.
- **FR-005**: The compiled immutable template MUST be cached per loaded model. Each render MUST use
  a fresh environment so requests cannot leak context.
- **FR-006**: Jinja-rendered prompts containing their own BOS MUST be tokenized with
  `add_special=false`; special tokens MUST still be parsed.
- **FR-007**: Generation MUST stop on any vocabulary EOG token, not only the primary EOS token.
- **FR-008**: Token-to-piece conversion MUST retry with the size requested by llama.cpp rather than
  relying on a fixed 64-byte buffer.
- **FR-009**: The sampler MUST reset between independent requests.
- **FR-010**: User-controlled prompt content MUST not be able to inject model control tokens.
- **FR-011**: The selected summary-language mode and thinking toggle MUST be Codable, backward
  compatible, independently persisted, and exposed in the Gemma settings UI.
- **FR-012**: Model updates remain unpinned. Template/model hashes MAY be recorded diagnostically;
  activation MUST depend on compatibility preflight, not an allowlist of model hashes.
- **FR-013**: An incompatible model MUST fail closed without altering any other installed model.
  Transactional replacement of the same Gemma package remains part of its later download-center
  migration and is not claimed by this feature.
- **FR-014**: Qwen MUST remain on an explicit legacy ChatML path.
- **FR-015**: Tests MUST be hermetic and MUST NOT load the user's installed models or Homan profile.

## Non-Goals

- Pinning model revisions or SHA values.
- Replacing the GGUF runtime, sampler policy, or model catalog.
- Migrating the remaining model families into the unified download center.
- Adding tools/function calling or multi-turn meeting chat.
- Publishing a DMG, tag, GitHub Release, or changing the marketing version.
- Redesigning process-wide llama backend lifetime beyond the minimal reference counting required
  for Gemma and legacy Qwen runtimes to coexist safely.

## Success Criteria

- **SC-001**: Embedded and current Google Gemma templates match stored Python Jinja2 goldens for
  all three language modes × thinking on/off.
- **SC-002**: Negative lexical fixtures preserve delimiter-like strings and reject malformed tags.
- **SC-003**: Gemma no longer calls `llama_chat_apply_template`; Qwen does so only through a named
  legacy strategy.
- **SC-004**: Markdown blank lines and lists survive Gemma output cleanup.
- **SC-005**: Targeted tests and release builds pass. The authoritative serial suite has no Niko
  failures; its 24 sandbox-only issues are isolated to AVFoundation encoding/ALAC and the macOS
  pasteboard, both unavailable to the test process in this execution environment.
