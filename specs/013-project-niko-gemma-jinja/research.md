# Research: Project Niko — Gemma Jinja Chat Architecture

## Verified 2026-09-01

- Homan's current `llama_chat_apply_template(nil, ...)` path renders ChatML for the installed
  Gemma 4 GGUF; the public API is not a general Jinja executor.
- `swift-jinja` 2.4.2 parses and renders both the installed embedded Gemma template and Google's
  current template. Its published lexer mishandles comment whitespace control and uses global
  regex preprocessing for other controls, so raw use is unsafe.
- A temporary regex patch achieved 12/12 Gemma parity but corrupted delimiter-like text inside
  quoted expressions. It is explicitly rejected for production.
- A state-aware normalization layer can remove Jinja whitespace-control markers before compilation,
  avoiding the dependency's regex path while retaining the rest of its parser/interpreter.
- Patched-spike rendering was byte-identical to Python Jinja2 3.1.6 for two templates × three
  language policies × thinking on/off. Token IDs were also identical with the installed vocabulary.
- The production state-aware normalizer and renderer were subsequently rerun against those same
  twelve fixtures and were byte-identical in all 12/12 cases.
- Compile cost was about 65 ms once and render cost about 0.037 ms on the reference M4.
- Standalone `google/minja` and `ochafik/minja` matched the installed template but rejected Google's
  current adjacent-string syntax. Full llama.cpp chat support is not exposed through the current
  llama.swift public product without adding a C++ integration layer.
- A hand-written Gemma renderer matches today's restricted two-message use, but would silently drift
  as Google changes the template. It is suitable only as an explicit known-template emergency
  fallback, not as the primary architecture.

## Licensing

`huggingface/swift-jinja` is Apache License 2.0. Its runtime dependency `apple/swift-collections`
is also Apache License 2.0. The production dependency is linked as an unmodified library; Homan's
state-aware normalizer is original integration code outside the dependency.

## Operational Policy

The owner explicitly rejected model revision/SHA pinning. Homan therefore continues resolving the
latest external model revision, compiles and preflights the template before activation, records
identity hashes for diagnosis only, and fails closed on incompatibility. No unknown template is
silently rendered as ChatML.

## Verification Record

- Project Niko renderer: the two audited templates and all 12 Python Jinja2 goldens are bundled as
  hermetic test resources; the parity test has no environment-variable skip path.
- Gemma summary/policy/cleanup: 26 tests passed.
- Qwen and meeting-summary compatibility: 75 tests passed.
- Serial full suite: 1893 tests executed. Its 24 issues are exclusively pre-existing environment
  failures in AVFoundation AAC/ALAC and `NSPasteboard` under the Codex sandbox; no Niko, Gemma,
  Qwen, settings, or summary-pipeline test failed.
- Production SwiftPM builds passed for both `MuesliNativeApp` and `homan-cli`.
- Installed-model validation used the local E4B-QAT GGUF (`tokenizer.chat_template` SHA-256
  `241c50d86bdfe5e43307da87f559cd2416aacd67a8de46c15acc0105ef2200b7`) on Apple M4/Metal. With
  a fixed mixed EN/RU transcript whose dominant language was English, `Detect from transcript`,
  thinking off, and production sampler settings, notes and titles were English for all six seeds
  (12/12 generations). The original reporter's private meeting-id-12 transcript was not available
  on this Mac, so the test uses a committed-equivalent synthetic reproduction fixture.
