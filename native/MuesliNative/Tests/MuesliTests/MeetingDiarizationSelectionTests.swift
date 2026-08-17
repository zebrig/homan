import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting diarization selection resolver")
struct MeetingDiarizationSelectionTests {

    private let offlineID = MeetingDiarizationModelID(rawValue: "offline")
    private let stableID = MeetingDiarizationModelID(rawValue: "stable")

    @Test("no ready models resolves unavailable regardless of stored value")
    func noReadyModelsUnavailable() {
        let result = resolve(ready: [], stored: "offline")

        #expect(result == .unavailable(readyDescriptors: []))
    }

    @Test("one ready model is selected automatically even with a stale preference")
    func soleReadyWinsOverStalePreference() {
        let result = resolve(ready: [offlineID], stored: "stable")

        guard case .selected(let modelID, let source, let ready) = result else {
            Issue.record("expected selected, got \(result)")
            return
        }
        #expect(modelID == offlineID)
        #expect(source == .soleReady)
        #expect(ready.map(\.id) == [offlineID])
    }

    @Test("stored concrete preference is preserved among several ready models")
    func storedPreferencePreserved() {
        for stored in ["offline", "stable"] {
            let expectedID = MeetingDiarizationModelID(rawValue: stored)
            let result = resolve(ready: [offlineID, stableID], stored: stored)

            guard case .selected(let modelID, let source, _) = result else {
                Issue.record("expected selected, got \(result)")
                continue
            }
            #expect(modelID == expectedID)
            #expect(source == .storedPreference)
        }
    }

    @Test("legacy Automatic alias migrates to Offline quality when ready")
    func automaticAliasMigratesToOfflineQuality() {
        let result = resolve(ready: [offlineID, stableID], stored: "automatic")

        guard case .selected(let modelID, let source, _) = result else {
            Issue.record("expected selected, got \(result)")
            return
        }
        #expect(modelID == offlineID)
        #expect(source == .legacyAliasMigration)
    }

    @Test("legacy profile alias resolves through descriptor aliases")
    func legacyProfileAliasResolves() {
        let result = resolve(ready: [offlineID, stableID], stored: "offline_quality")

        guard case .selected(let modelID, let source, _) = result else {
            Issue.record("expected selected, got \(result)")
            return
        }
        #expect(modelID == offlineID)
        #expect(source == .legacyAliasMigration)
    }

    @Test("several ready models without a valid preference require a choice")
    func choiceRequiredWithoutValidPreference() {
        for stored in [nil, "bad", "withdrawn"] {
            let result = resolve(ready: [offlineID, stableID], stored: stored)

            guard case .choiceRequired(let ready) = result else {
                Issue.record("expected choiceRequired for \(stored ?? "nil"), got \(result)")
                continue
            }
            #expect(ready.map(\.id) == [offlineID, stableID])
        }
    }

    @Test("Automatic is not a fallback when its historical target is not ready")
    func automaticNeverFallsBackToOfflineWhenMissing() {
        let result = resolve(ready: [stableID], stored: "automatic")

        guard case .selected(let modelID, let source, _) = result else {
            Issue.record("expected selected, got \(result)")
            return
        }
        #expect(modelID == stableID)
        #expect(source == .soleReady)
    }

    @Test("unsupported tombstones are never selectable or counted")
    func tombstonesAreNotSelectable() throws {
        let tombstoneID = MeetingDiarizationModelID(rawValue: "legacy-tombstone")
        let catalog = try makeCatalog(
            descriptors: [
                descriptor(id: "offline", aliases: ["offline_quality"]),
                descriptor(id: "stable"),
                descriptor(
                    id: "legacy-tombstone",
                    lifecycle: .unsupportedTombstone,
                    supportsLive: false
                ),
            ]
        )
        let input = MeetingDiarizationSelectionInput(
            catalog: catalog,
            readyModelIDs: [offlineID, stableID, tombstoneID],
            storedModelIDOrLegacyAlias: "legacy-tombstone"
        )

        let result = MeetingDiarizationSelectionResolver.resolve(input)

        guard case .choiceRequired(let ready) = result else {
            Issue.record("expected choiceRequired, got \(result)")
            return
        }
        #expect(ready.map(\.id) == [offlineID, stableID])
    }

    @Test("ready descriptors keep catalog order regardless of set order")
    func orderingFollowsCatalog() throws {
        let catalog = try makeCatalog(descriptors: [
            descriptor(id: "stable"),
            descriptor(id: "offline", aliases: ["offline_quality"]),
        ])
        let input = MeetingDiarizationSelectionInput(
            catalog: catalog,
            readyModelIDs: [offlineID, stableID]
        )

        let result = MeetingDiarizationSelectionResolver.resolve(input)

        guard case .choiceRequired(let ready) = result else {
            Issue.record("expected choiceRequired, got \(result)")
            return
        }
        #expect(ready.map(\.id) == [stableID, offlineID])
    }

    @Test("resolution is deterministic and idempotent")
    func resolutionIsIdempotent() {
        let first = resolve(ready: [offlineID, stableID], stored: nil)
        let second = resolve(ready: [offlineID, stableID], stored: nil)
        #expect(first == second)
    }

    // MARK: - Fixtures

    private func resolve(
        ready: [MeetingDiarizationModelID],
        stored: String?
    ) -> MeetingDiarizationSelectionResult {
        let catalog = try! makeCatalog(descriptors: [
            descriptor(id: "offline", aliases: ["offline_quality"]),
            descriptor(id: "stable"),
        ])
        return MeetingDiarizationSelectionResolver.resolve(
            MeetingDiarizationSelectionInput(
                catalog: catalog,
                readyModelIDs: Set(ready),
                storedModelIDOrLegacyAlias: stored
            )
        )
    }

    private func descriptor(
        id: String,
        aliases: [String] = [],
        lifecycle: MeetingDiarizationModelLifecycle = .active,
        supportsLive: Bool = true
    ) -> MeetingDiarizationModelDescriptor {
        MeetingDiarizationModelDescriptor(
            id: MeetingDiarizationModelID(rawValue: id),
            displayNameKey: "fixture.\(id).name",
            detailKey: "fixture.\(id).detail",
            assetRevision: "1",
            runtimeAdapterID: "fluidaudio.offline-community-vbx",
            capabilities: MeetingDiarizationCapabilities(
                supportsFinal: true,
                supportsLive: supportsLive,
                maximumRemoteSpeakers: nil,
                latencyClass: supportsLive ? .liveCapable : .finalOnly
            ),
            lifecycle: lifecycle,
            onboarding: .offered,
            license: MeetingDiarizationModelLicense(
                displayName: "Fixture license",
                noticeURL: URL(string: "https://example.com/license")!
            ),
            replacementID: nil,
            legacyAliases: aliases
        )
    }

    private func makeCatalog(
        descriptors: [MeetingDiarizationModelDescriptor]
    ) throws -> MeetingDiarizationCatalogSnapshot {
        let snapshot = MeetingDiarizationCatalogSnapshot(
            schemaVersion: MeetingDiarizationModelCatalog.currentSchemaVersion,
            revision: "fixture",
            descriptors: descriptors
        )
        try MeetingDiarizationModelCatalog.validate(snapshot)
        return snapshot
    }
}
