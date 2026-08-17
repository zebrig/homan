import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting diarization model catalog")
struct MeetingDiarizationCatalogTests {

    @Test("bundled catalog validates and seeds Offline quality and Stable up to 4")
    func bundledCatalogValidates() throws {
        let snapshot = try MeetingDiarizationModelCatalog.loadBundled()

        #expect(snapshot.schemaVersion == MeetingDiarizationModelCatalog.currentSchemaVersion)
        #expect(snapshot.revision == MeetingDiarizationModelCatalog.bundledRevision)
        #expect(snapshot.descriptors.count == 2)

        let offline = try #require(snapshot.descriptors.first {
            $0.legacyAliases.contains("offline_quality")
        })
        let stable = try #require(snapshot.descriptors.first {
            $0.legacyAliases.contains("stable_four_speaker")
        })

        #expect(offline.capabilities.supportsFinal)
        #expect(!offline.capabilities.supportsLive)
        #expect(offline.capabilities.maximumRemoteSpeakers == nil)
        #expect(stable.capabilities.supportsLive)
        #expect(stable.capabilities.maximumRemoteSpeakers == 4)
        #expect(snapshot.descriptors.allSatisfy { $0.id.rawValue != "automatic" })
        #expect(snapshot.descriptors.allSatisfy { descriptor in
            !descriptor.legacyAliases.contains("automatic")
        })
    }

    @Test("duplicate stable IDs are rejected")
    func duplicateIDsRejected() throws {
        let data = try catalogJSON(descriptors: [
            descriptor(id: "a", adapter: "fluidaudio.offline-community-vbx"),
            descriptor(id: "a", adapter: "fluidaudio.sortformer-balanced-v2.1"),
        ])

        #expect(throws: MeetingDiarizationCatalogError.duplicateID("a")) {
            try MeetingDiarizationModelCatalog.validated(data)
        }
    }

    @Test("duplicate aliases are rejected")
    func duplicateAliasesRejected() throws {
        let data = try catalogJSON(descriptors: [
            descriptor(id: "a", aliases: ["shared"]),
            descriptor(id: "b", aliases: ["shared"]),
        ])

        #expect(throws: MeetingDiarizationCatalogError.duplicateAlias("shared")) {
            try MeetingDiarizationModelCatalog.validated(data)
        }
    }

    @Test("unknown runtime adapters are rejected")
    func unknownAdapterRejected() throws {
        let data = try catalogJSON(descriptors: [
            descriptor(id: "a", adapter: "not-in-allowlist"),
        ])

        #expect(throws: MeetingDiarizationCatalogError.unknownRuntimeAdapter("not-in-allowlist")) {
            try MeetingDiarizationModelCatalog.validated(data)
        }
    }

    @Test("replacement cycles are rejected")
    func replacementCyclesRejected() throws {
        let data = try catalogJSON(descriptors: [
            descriptor(id: "a", replacementID: "b"),
            descriptor(id: "b", replacementID: "a"),
        ])

        #expect(throws: MeetingDiarizationCatalogError.self) {
            try MeetingDiarizationModelCatalog.validated(data)
        }
    }

    @Test("unknown replacement targets are rejected")
    func unknownReplacementTargetRejected() throws {
        let data = try catalogJSON(descriptors: [
            descriptor(id: "a", replacementID: "missing"),
        ])

        #expect(throws: MeetingDiarizationCatalogError.unknownReplacementTarget("missing")) {
            try MeetingDiarizationModelCatalog.validated(data)
        }
    }

    @Test("Automatic is reserved and cannot be a model ID or alias")
    func automaticNameIsReserved() throws {
        let idData = try catalogJSON(descriptors: [
            descriptor(id: "automatic"),
        ])
        #expect(throws: MeetingDiarizationCatalogError.reservedAutomaticName("automatic")) {
            try MeetingDiarizationModelCatalog.validated(idData)
        }

        let aliasData = try catalogJSON(descriptors: [
            descriptor(id: "a", aliases: ["automatic"]),
        ])
        #expect(throws: MeetingDiarizationCatalogError.reservedAutomaticName("automatic")) {
            try MeetingDiarizationModelCatalog.validated(aliasData)
        }
    }

    @Test("future schema versions are rejected")
    func futureSchemaRejected() throws {
        let data = try catalogJSON(
            schemaVersion: MeetingDiarizationModelCatalog.currentSchemaVersion + 1,
            descriptors: [descriptor(id: "a")]
        )

        #expect(throws: MeetingDiarizationCatalogError.self) {
            try MeetingDiarizationModelCatalog.validated(data)
        }
    }

    @Test("malformed catalog data throws instead of selecting a fallback model")
    func malformedCatalogThrows() {
        #expect(throws: Error.self) {
            try MeetingDiarizationModelCatalog.validated(Data("not json".utf8))
        }
    }

    // MARK: - Fixtures

    private func descriptor(
        id: String,
        adapter: String = "fluidaudio.offline-community-vbx",
        aliases: [String] = [],
        lifecycle: MeetingDiarizationModelLifecycle = .active,
        replacementID: String? = nil
    ) -> MeetingDiarizationModelDescriptor {
        MeetingDiarizationModelDescriptor(
            id: MeetingDiarizationModelID(rawValue: id),
            displayNameKey: "fixture.\(id).name",
            detailKey: "fixture.\(id).detail",
            assetRevision: "1",
            runtimeAdapterID: adapter,
            capabilities: MeetingDiarizationCapabilities(
                supportsFinal: true,
                supportsLive: true,
                maximumRemoteSpeakers: nil,
                latencyClass: .liveCapable
            ),
            lifecycle: lifecycle,
            onboarding: .offered,
            license: MeetingDiarizationModelLicense(
                displayName: "Fixture license",
                noticeURL: URL(string: "https://example.com/license")!
            ),
            replacementID: replacementID.map(MeetingDiarizationModelID.init(rawValue:)),
            legacyAliases: aliases
        )
    }

    private func catalogJSON(
        schemaVersion: Int = MeetingDiarizationModelCatalog.currentSchemaVersion,
        descriptors: [MeetingDiarizationModelDescriptor]
    ) throws -> Data {
        let snapshot = MeetingDiarizationCatalogSnapshot(
            schemaVersion: schemaVersion,
            revision: "fixture",
            descriptors: descriptors
        )
        return try JSONEncoder().encode(snapshot)
    }
}
