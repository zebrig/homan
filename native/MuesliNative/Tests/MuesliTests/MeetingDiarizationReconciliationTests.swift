import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting diarization reconciliation")
struct MeetingDiarizationReconciliationTests {

    private let offlineID = MeetingDiarizationModelID(rawValue: "offline")
    private let stableID = MeetingDiarizationModelID(rawValue: "stable")

    @Test("no ready models resolves unavailable without persisting")
    func noReadyModelsUnavailable() throws {
        let decision = try plan(
            statuses: [],
            stored: "offline",
            liveOn: true
        )

        #expect(decision.selection.state == .unavailable)
        #expect(!decision.shouldPersistSelection)
        #expect(!decision.normalizeLiveOff)
    }

    @Test("sole ready model is selected and persisted even with a stale stored value")
    func soleReadyPersistsConcreteID() throws {
        let decision = try plan(
            statuses: MeetingDiarizationAssetFixtures.onlyOfflineReady,
            stored: "stable",
            liveOn: true
        )

        #expect(decision.selection.state == .selected)
        #expect(decision.selection.profileID == offlineID)
        #expect(decision.selection.source == .soleReady)
        #expect(decision.shouldPersistSelection)
        #expect(decision.storedModelID == "offline")
        #expect(decision.normalizeLiveOff)
    }

    @Test("stored concrete preference is preserved without a config write")
    func storedPreferencePreservedIdempotently() throws {
        let decision = try plan(
            statuses: MeetingDiarizationAssetFixtures.bothReady,
            stored: "stable",
            liveOn: false
        )

        #expect(decision.selection.state == .selected)
        #expect(decision.selection.profileID == stableID)
        #expect(decision.selection.source == .storedPreference)
        #expect(!decision.shouldPersistSelection)
        #expect(!decision.normalizeLiveOff)
    }

    @Test("Final-only selected model normalizes Live default Off in the same decision")
    func finalOnlyModelNormalizesLiveOff() throws {
        let decision = try plan(
            statuses: MeetingDiarizationAssetFixtures.bothReady,
            stored: "offline",
            liveOn: true
        )

        #expect(decision.selection.state == .selected)
        #expect(decision.selection.profileID == offlineID)
        #expect(decision.selection.capabilities?.supportsLive == false)
        #expect(!decision.shouldPersistSelection)
        #expect(decision.normalizeLiveOff)
    }

    @Test("live-capable selected model leaves Live default untouched")
    func liveCapableModelKeepsLiveDefault() throws {
        let decision = try plan(
            statuses: MeetingDiarizationAssetFixtures.bothReady,
            stored: "stable",
            liveOn: true
        )

        #expect(decision.selection.profileID == stableID)
        #expect(!decision.normalizeLiveOff)
    }

    @Test("legacy Automatic migrates to Offline quality and persists the concrete ID")
    func automaticMigratesAndPersists() throws {
        let decision = try plan(
            statuses: MeetingDiarizationAssetFixtures.bothReady,
            stored: "automatic",
            liveOn: true
        )

        #expect(decision.selection.state == .selected)
        #expect(decision.selection.profileID == offlineID)
        #expect(decision.selection.source == .legacyAliasMigration)
        #expect(decision.shouldPersistSelection)
        #expect(decision.storedModelID == "offline")
        #expect(decision.normalizeLiveOff)
    }

    @Test("several ready models without a valid stored value require a choice")
    func choiceRequiredIsNeverPersisted() throws {
        for stored in [nil, "bad", "retired"] {
            let decision = try plan(
                statuses: MeetingDiarizationAssetFixtures.bothReady,
                stored: stored,
                liveOn: false
            )

            #expect(decision.selection.state == .choiceRequired)
            #expect(!decision.shouldPersistSelection)
            #expect(decision.selection.readyAlternatives.map(\.id) == [offlineID, stableID])
        }
    }

    @Test("ready assets unknown to the catalog never participate in selection")
    func unknownReadyAssetsExcluded() throws {
        let catalog = try makeCatalog(
            descriptors: [
                descriptor(id: "stable", aliases: ["stable_four_speaker"], supportsLive: true),
            ]
        )
        let statuses = [
            MeetingDiarizationAssetFixtures.status(profileID: .offlineQuality, state: .ready),
            MeetingDiarizationAssetFixtures.status(profileID: .stableFourSpeaker, state: .ready),
        ]

        let decision = MeetingDiarizationReconciliation.plan(
            catalog: catalog,
            statuses: statuses,
            storedModelID: nil,
            liveDefaultEnabled: false,
            generation: 7
        )

        #expect(decision.selection.state == .selected)
        #expect(decision.selection.profileID == stableID)
        #expect(decision.selection.source == .soleReady)
        #expect(decision.selection.generation == 7)
    }

    @Test("unsupported tombstone assets are never counted as ready")
    func tombstoneAssetsExcluded() throws {
        let tombstoneID = MeetingDiarizationModelID(rawValue: "tombstone")
        let catalog = try makeCatalog(
            descriptors: [
                descriptor(id: "offline", aliases: ["offline_quality"], supportsLive: false),
                descriptor(
                    id: "tombstone",
                    aliases: ["legacy_unknown"],
                    supportsLive: false,
                    lifecycle: .unsupportedTombstone
                ),
            ]
        )
        let statuses = [
            MeetingDiarizationAssetFixtures.status(profileID: .offlineQuality, state: .ready),
            MeetingDiarizationAssetFixtures.status(profileID: .stableFourSpeaker, state: .ready),
        ]

        let decision = MeetingDiarizationReconciliation.plan(
            catalog: catalog,
            statuses: statuses,
            storedModelID: nil,
            liveDefaultEnabled: false,
            generation: 8
        )

        #expect(decision.selection.state == .selected)
        #expect(decision.selection.profileID == offlineID)
        #expect(decision.selection.readyAlternatives.allSatisfy { $0.id != tombstoneID })
    }

    // MARK: - Fixtures

    private func plan(
        statuses: [MeetingDiarizationAssetStatus],
        stored: String?,
        liveOn: Bool
    ) throws -> MeetingDiarizationReconciliationDecision {
        let catalog = try makeCatalog(descriptors: [
            descriptor(id: "offline", aliases: ["offline_quality"], supportsLive: false),
            descriptor(id: "stable", aliases: ["stable_four_speaker"], supportsLive: true),
        ])
        return MeetingDiarizationReconciliation.plan(
            catalog: catalog,
            statuses: statuses,
            storedModelID: stored,
            liveDefaultEnabled: liveOn,
            generation: 1
        )
    }

    private func descriptor(
        id: String,
        aliases: [String],
        supportsLive: Bool,
        lifecycle: MeetingDiarizationModelLifecycle = .active
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
