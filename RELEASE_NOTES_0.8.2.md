# Homan 0.8.2

Homan 0.8.2 focuses on reliable long-running meeting capture, recoverable processing, faster repeated dictation, and more useful meeting-note export.

## Meeting recording and recovery

- Added automatic same-route microphone recovery when CoreAudio callbacks disappear or a selected microphone silently produces only zero samples while system audio remains active.
- Kept the previous microphone active during a route change until the replacement device produces a real non-zero signal.
- Bounded recovery attempts and grouped repeated degradation into one visible diagnostic episode instead of repeatedly restarting capture.
- Stabilized CoreAudio aggregate-device identities and added cleanup diagnostics, preventing unbounded phantom aggregate devices after interrupted recordings.
- Preserved raw microphone and system sources throughout recording and post-processing.

## Processing and templates

- Made meeting-processing progress persistent and meeting-scoped. Progress now remains visible in the meeting list and detail view during ordinary completion, retries, recovery, re-transcription, and re-summarization.
- Fixed retry and recovery paths so incomplete meetings retain actionable processing controls.
- Unified template resolution: meetings without a complete saved template now use the configured default profile, including user overrides for built-in profiles, before safely falling back to Auto.

## Notes and transcript export

- Added inline Markdown rendering and round-trip editing for bold, emphasis, inline code, and links while retaining headings, lists, numbered lists, and checkboxes.
- Added timed plain-text transcript export in `[00:00:05.40 - 00:00:19.02] Speaker: text` format.
- Added standards-compatible WebVTT (`.vtt`) transcript export.
- Preserved speaker labels in timed-text and WebVTT output.

## Dictation and data management

- Kept prepared dictation audio graphs warm after successful dictations, reducing repeated CoreAudio setup work and improving subsequent dictation startup.
- Avoided unnecessary input-graph rebuilds for unrelated output-route changes while retaining teardown after real failures, cancellation, shutdown, or explicit device changes.
- Added settings import/export and text-only meeting backups.
- Reorganized the Settings data section into clearer deletion, settings-backup, and meeting-backup groups.

## Installation

Download `Homan-0.8.2.dmg`, open it, and drag Homan to Applications.

The release is signed with Developer ID, notarized, and stapled by Apple. It requires macOS 14.2 or newer on Apple Silicon.
