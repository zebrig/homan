# Homan 0.8.4

Homan 0.8.4 consolidates the tested post-0.8.3 meeting, audio, and model-management improvements.

## Reliable model setup

- Added a unified, resumable model-download engine for Parakeet v2 and v3 with truthful byte
  progress across onboarding, Models, and the Sidebar.
- Added HTTP Range/ETag resume, bounded retries, strict redirects, disk-space and package
  validation, Homan-owned staging, and atomic installation with last-known-good preservation.
- Existing FluidAudio Parakeet packages are validated and copied into Homan-owned storage without
  modifying the legacy cache.
- Partial or failed packages are no longer shown as downloaded or active; downloads can be
  cancelled, resumed, retried, and safely removed.

## Meeting audio and re-transcription

- Preserved raw synchronized meeting sources so re-transcription can repeat echo cancellation and
  channel separation instead of reusing only the previous processed output.
- Made re-transcription source lifetime and processing progress reliable across background work.
- Fixed the floating meeting indicator remaining stuck on Saving after processing completed.
- Updated the default meeting echo-cancellation model to the validated LocalVQE v1.2 path.

## Audio lifecycle stability

- Hardened CoreAudio handoffs, capture diagnostics, meeting-microphone recovery, and shutdown while
  background processing is active.
- Kept model loading and deletion serialized between Homan and the bundled `homan-cli`.

## Installation

Download `Homan-0.8.4.dmg`, open it, and drag Homan to Applications.

The release is signed with Developer ID, notarized, and stapled by Apple. It requires macOS 14.2
or newer on Apple Silicon.
