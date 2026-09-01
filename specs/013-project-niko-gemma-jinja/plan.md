# Implementation Plan: Project Niko — Gemma Jinja Chat Architecture

**Status**: Implemented

**Specification**: [spec.md](spec.md)

## Architecture

```text
selected Gemma GGUF
  -> llama_model_chat_template(model, nil)
  -> size/shape limits
  -> state-aware Jinja whitespace normalization
  -> swift-jinja compile + six-case preflight
  -> immutable compiled template cached with loaded runtime

summary request
  -> language policy builds bounded system directive
  -> thinking toggle remains independent
  -> fresh Jinja Environment + typed context
  -> control-token-safe rendered prompt
  -> tokenize(add_special: false, parse_special: true)
  -> llama.cpp decode until any EOG
  -> channel-aware output cleanup preserving Markdown
```

Qwen uses a separate named legacy ChatML renderer. There is no automatic fallback from Gemma Jinja
to Qwen/ChatML formatting.

## Dependency Strategy

Use `https://github.com/huggingface/swift-jinja.git` at reviewed revision
`7d0b8880ef8e567dd4e0089f8b99fb354129017c` (release 2.4.2). Homan owns a narrow state-aware
whitespace-control normalizer because 2.4.2 performs unsafe global regex preprocessing and omits
comment whitespace controls. Passing normalized templates without `-` control delimiters bypasses
that defect without maintaining a source fork. The normalizer is differential-tested against
Python-generated golden output, including syntax-like substrings inside quoted expressions.

The dependency is Apache-2.0 and adds only the existing Apache-2.0 `swift-collections` runtime
dependency. Distribution attribution is recorded in Project Niko research and the repository's
third-party notice surface.

## Runtime Decisions

- Compile after the model pointer is loaded; do not compile from a catalog copy.
- Cache the compiled value together with the loaded model URL.
- Use fresh render state for each call.
- Maximum source length: 256 KiB; maximum rendered prompt length: 16 MiB; bounded language input.
- Preflight both thinking values with minimal system/user messages before activation.
- Treat unsupported template syntax as a model compatibility error.
- Sanitize reserved model control tokens in message content before rendering; never alter the
  stored transcript.
- Keep model downloads on latest published revisions. Record template SHA-256 only in diagnostics.

## Commit Boundaries

1. SpecKit + Jinja dependency, normalizer, renderer, and golden tests.
2. Gemma runtime integration and llama token correctness; explicit Qwen legacy path.
3. Language/thinking persistence, prompt policy, Settings UI, and tests.
4. Output/preflight hardening and regression fixes.
5. Minimal reference-counted llama backend lifetime fix, required so separately cached Gemma and
   legacy Qwen runtimes cannot free the shared backend underneath one another.

## Verification Gates

1. Normalizer and golden renderer tests.
2. App-config migration and prompt-policy tests.
3. Gemma/Qwen targeted suites.
4. All summary, settings, model, and processing tests.
5. Serial full suite using repository-local SwiftPM scratch storage.
6. Release build. Installation and publication require separate owner instructions.
