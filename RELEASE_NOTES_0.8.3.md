# Homan 0.8.3

Homan 0.8.3 is a packaging hotfix for the refreshed 0.8.2 installer.

## Startup reliability

- Fixed an immediate launch crash on Macs other than the build machine when Homan loads its bundled speaker-diarization catalog.
- Resolved packaged SwiftPM resources from the conventional `Contents/Resources` location while preserving normal SwiftPM behavior for local builds and tests.
- Added an isolated packaged-GUI smoke test that loads the diarization catalog and AEC resources without opening Homan or touching user data.
- Extended the packaging check to verify all required SwiftPM resource bundles and the embedded CLI before a release is published.

## Speaker-model experience

- Included the latest speaker-separation model catalog, installation recovery, Models asset-management view, Settings selection, and optional onboarding download step.
- Speaker-model cards now remain in a clear Checking state until the installed-asset scan completes.

## Installation

Download `Homan-0.8.3.dmg`, open it, and drag Homan to Applications.

The release is signed with Developer ID, notarized, and stapled by Apple. It requires macOS 14.2 or newer on Apple Silicon.
