# Homan 0.8.5

Homan 0.8.5 improves meeting audio processing feedback and makes Gemma meeting summaries more
predictable across languages.

## Meeting audio processing

- Meeting processing now clearly reports when it is paused while another meeting is being
  recorded, instead of appearing to process unusually slowly.
- LocalVQE v1.2 echo cancellation now uses the validated four-thread configuration for faster
  post-processing without changing the selected acoustic model.
- Added internal AEC timing instrumentation used to verify processing performance on saved real
  calls.

## Gemma summaries

- Gemma prompts are now rendered through the model's native Jinja chat template instead of a
  hand-built approximation.
- Added separate controls for summary language and Gemma thinking mode.
- `Detect from transcript` is the safe language default, while thinking remains off by default.
- Hardened Gemma output handling for end-of-generation markers, accidental ChatML output,
  thought-channel removal, and Markdown preservation.
- Added bundled reference fixtures and real-model multi-seed validation for the supported Gemma
  prompt modes.

## Installation

Download `Homan-0.8.5.dmg`, open it, and drag Homan to Applications.

The release is signed with Developer ID, notarized, and stapled by Apple. It requires macOS 14.2
or newer on Apple Silicon.
