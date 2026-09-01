# Tasks: Project Niko — Gemma Jinja Chat Architecture

**Status**: Implemented

## A. Contract and dependency

- [x] T001 Record user decisions, non-goals, and audited alternatives.
- [x] T002 Add exact `swift-jinja` code dependency and license attribution.
- [x] T003 Add state-aware whitespace-control normalization.
- [x] T004 Add embedded/current-template goldens for three language modes × thinking on/off.
- [x] T005 Add negative lexical tests for quoted delimiters, comments, adjacent braces, and malformed
  syntax.

## B. Gemma runtime

- [x] T006 Extract the exact embedded template from the loaded GGUF.
- [x] T007 Compile/cache/preflight it with bounded source and rendered sizes.
- [x] T008 Render the typed Gemma context with fresh request state.
- [x] T009 Tokenize without duplicate BOS, stop on any EOG, reset sampler, and resize token-piece
  buffers.
- [x] T010 Sanitize control-token strings in untrusted message content.
- [x] T011 Surface explicit template-compatibility errors with no silent ChatML fallback.

## C. Product settings

- [x] T012 Add Codable language policy: model decides, transcript detection, custom text.
- [x] T013 Add an independent Codable thinking toggle.
- [x] T014 Add bounded dominant-language detection and prompt directives.
- [x] T015 Wire both settings through summary and title generation.
- [x] T016 Expose both settings in Gemma Settings UI.

## D. Compatibility and cleanup

- [x] T017 Keep Qwen on an explicit legacy ChatML strategy and add regression tests.
- [x] T018 Strip Gemma thought channels and protocol markers while preserving Markdown layout.
- [x] T019 Add diagnostics for template identity and compatibility failure.
- [x] T020 Keep model revision policy unpinned and avoid download-center scope expansion.
- [x] T020A Reference-count the shared llama backend across Gemma and Qwen runtimes.

## E. Gates

- [x] T021 Run Project Niko targeted suites.
- [x] T022 Run existing Gemma, Qwen, summary, settings, and model suites.
- [x] T023 Run the authoritative serial full suite (1893 tests; all 24 issues are isolated to
  sandbox-denied AVFoundation encoding/ALAC and pasteboard access, with no Niko failures).
- [x] T024 Produce release builds of `MuesliNativeApp` and `homan-cli` without installing,
  publishing, or bumping version.
- [x] T025 Review `main`, branches, and worktrees for an orderly handoff.
