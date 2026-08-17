import Foundation
import MuesliCore

/// Open stable identity for a diarization model. Never a display name and
/// never a closed UI enum: views and the generic resolver operate on these
/// values, and future catalog entries require no view changes.
struct MeetingDiarizationModelID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum MeetingDiarizationModelLifecycle: String, Codable, Sendable, Equatable {
    case active
    case deprecatedSupported
    case unsupportedTombstone
    case withdrawnNotInstalled
}

enum MeetingDiarizationLatencyClass: String, Codable, Sendable, Equatable {
    case finalOnly
    case liveCapable
}

struct MeetingDiarizationCapabilities: Codable, Sendable, Equatable {
    let supportsFinal: Bool
    let supportsLive: Bool
    let maximumRemoteSpeakers: Int?
    let latencyClass: MeetingDiarizationLatencyClass
}

enum MeetingDiarizationOnboardingAvailability: String, Codable, Sendable, Equatable {
    case hidden
    case offered
}

struct MeetingDiarizationModelLicense: Codable, Sendable, Equatable {
    let displayName: String
    let noticeURL: URL
}

struct MeetingDiarizationModelDescriptor: Codable, Sendable, Equatable {
    let id: MeetingDiarizationModelID
    let displayNameKey: String
    let detailKey: String
    let assetRevision: String
    let runtimeAdapterID: String
    let capabilities: MeetingDiarizationCapabilities
    let lifecycle: MeetingDiarizationModelLifecycle
    let onboarding: MeetingDiarizationOnboardingAvailability
    let license: MeetingDiarizationModelLicense
    let replacementID: MeetingDiarizationModelID?
    let legacyAliases: [String]

    /// Only active or deprecated-but-supported descriptors may be selected for
    /// a new run. Tombstones and withdrawn entries are presented, never run.
    var isSelectable: Bool {
        lifecycle == .active || lifecycle == .deprecatedSupported
    }
}

struct MeetingDiarizationCatalogSnapshot: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let revision: String
    let descriptors: [MeetingDiarizationModelDescriptor]
}

extension MeetingDiarizationModelDescriptor {
    /// Legacy pipeline profile bridged through the first catalog alias. Views
    /// use this only to reach the runtime definitions, never to name models.
    var legacyProfileID: MeetingDiarizationProfileID? {
        legacyAliases.first.flatMap(MeetingDiarizationProfileID.init(rawValue:))
    }

    /// Product display name supplied by the runtime definition, keeping view
    /// code free of hard-coded model names.
    var displayName: String {
        guard let profile = legacyProfileID else { return id.rawValue }
        return MeetingDiarizationProfiles.resolve(profile).displayName
    }

    var detailText: String {
        guard let profile = legacyProfileID else { return "" }
        return MeetingDiarizationProfiles.resolve(profile).detail
    }
}

/// Compile-time allowlist of executable runtime adapters. Catalog content may
/// reference only these IDs; it can never select arbitrary code.
enum MeetingDiarizationRuntimeAdapter {
    static let allowlist: Set<String> = [
        "fluidaudio.offline-community-vbx",
        "fluidaudio.sortformer-balanced-v2.1",
    ]

    static func adapterID(for engineID: MeetingDiarizationEngineID) -> String {
        switch engineID {
        case .offlineCommunity:
            return "fluidaudio.offline-community-vbx"
        case .sortformerBalanced:
            return "fluidaudio.sortformer-balanced-v2.1"
        }
    }
}

/// Historical compatibility only. `.automatic` is never a catalog model; the
/// future-global resolver bridges it to the Offline-quality target when that
/// target is still ready, while historical evidence resolution keeps using the
/// unchanged `MeetingDiarizationProfiles.resolve(.automatic)` path.
enum MeetingDiarizationCompatibility {
    static let automaticAlias = MeetingDiarizationProfileID.automatic.rawValue

    static func historicalAutomaticTarget(
        in catalog: MeetingDiarizationCatalogSnapshot
    ) -> MeetingDiarizationModelID? {
        catalog.descriptors.first {
            $0.legacyAliases.contains(MeetingDiarizationProfileID.offlineQuality.rawValue)
        }?.id
    }

    /// Resolves a captured manifest profile value back to the legacy profile
    /// used by the processing pipeline. Legacy raw values pass through
    /// unchanged; spec-010 stable IDs map through their catalog alias; unknown
    /// future values fall back safely without crashing or rewriting evidence.
    static func capturedProfileID(
        profileRawValue: String?,
        catalog: MeetingDiarizationCatalogSnapshot,
        safeFallbackProfile: MeetingDiarizationProfileID = .automatic
    ) -> MeetingDiarizationProfileID {
        guard let rawValue = profileRawValue else {
            return safeFallbackProfile
        }
        if let legacy = MeetingDiarizationProfileID(rawValue: rawValue) {
            return legacy
        }
        guard let descriptor = catalog.descriptors.first(
            where: { $0.id.rawValue == rawValue }
        ), let alias = descriptor.legacyAliases.first,
        let legacy = MeetingDiarizationProfileID(rawValue: alias) else {
            return safeFallbackProfile
        }
        return legacy
    }
}

enum MeetingDiarizationCatalogError: Error, Equatable, Sendable {
    case invalidSchemaVersion(Int)
    case duplicateID(String)
    case duplicateAlias(String)
    case reservedAutomaticName(String)
    case unknownRuntimeAdapter(String)
    case invalidCapabilities(String)
    case missingLicense(String)
    case unknownReplacementTarget(String)
    case replacementCycle(String)
}

enum MeetingDiarizationModelCatalog {
    static let currentSchemaVersion = 1
    static let bundledRevision = "2026-08-17.1"

    private static let lock = NSLock()
    private static var lastValid: MeetingDiarizationCatalogSnapshot?

    /// Loads and validates the bundled catalog. On any failure the last
    /// validated catalog is reused; if none exists, a safe empty catalog is
    /// returned. Installed assets are never touched by catalog failures.
    static func loadBundled() -> MeetingDiarizationCatalogSnapshot {
        guard let url = Bundle.module.url(
            forResource: "DiarizationModels",
            withExtension: "json"
        ), let data = try? Data(contentsOf: url) else {
            return fallback()
        }
        do {
            let snapshot = try validated(data)
            lock.lock()
            lastValid = snapshot
            lock.unlock()
            return snapshot
        } catch {
            return fallback()
        }
    }

    static func validated(_ data: Data) throws -> MeetingDiarizationCatalogSnapshot {
        let snapshot = try JSONDecoder().decode(
            MeetingDiarizationCatalogSnapshot.self,
            from: data
        )
        try validate(snapshot)
        return snapshot
    }

    static func validate(
        _ snapshot: MeetingDiarizationCatalogSnapshot
    ) throws {
        guard snapshot.schemaVersion >= 1,
              snapshot.schemaVersion <= currentSchemaVersion else {
            throw MeetingDiarizationCatalogError.invalidSchemaVersion(
                snapshot.schemaVersion
            )
        }

        var ids = Set<String>()
        var aliases = Set<String>()
        var byID: [String: MeetingDiarizationModelDescriptor] = [:]

        for descriptor in snapshot.descriptors {
            let id = descriptor.id.rawValue
            guard ids.insert(id).inserted else {
                throw MeetingDiarizationCatalogError.duplicateID(id)
            }
            guard id != MeetingDiarizationCompatibility.automaticAlias else {
                throw MeetingDiarizationCatalogError.reservedAutomaticName(id)
            }
            byID[id] = descriptor

            for alias in descriptor.legacyAliases {
                guard alias != MeetingDiarizationCompatibility.automaticAlias,
                      !ids.contains(alias) else {
                    throw MeetingDiarizationCatalogError.reservedAutomaticName(alias)
                }
                guard aliases.insert(alias).inserted else {
                    throw MeetingDiarizationCatalogError.duplicateAlias(alias)
                }
            }

            if descriptor.isSelectable {
                guard descriptor.runtimeAdapterID.isEmpty == false,
                      MeetingDiarizationRuntimeAdapter.allowlist.contains(
                        descriptor.runtimeAdapterID
                      ) else {
                    throw MeetingDiarizationCatalogError.unknownRuntimeAdapter(
                        descriptor.runtimeAdapterID
                    )
                }
                guard descriptor.capabilities.supportsFinal,
                      !descriptor.assetRevision.isEmpty else {
                    throw MeetingDiarizationCatalogError.invalidCapabilities(id)
                }
                guard !descriptor.license.displayName.isEmpty else {
                    throw MeetingDiarizationCatalogError.missingLicense(id)
                }
            }

            if let replacementID = descriptor.replacementID {
                guard byID[replacementID.rawValue] != nil else {
                    throw MeetingDiarizationCatalogError.unknownReplacementTarget(
                        replacementID.rawValue
                    )
                }
            }
        }

        for descriptor in snapshot.descriptors {
            var visited = Set<String>()
            var current = descriptor.replacementID
            while let next = current {
                guard visited.insert(next.rawValue).inserted else {
                    throw MeetingDiarizationCatalogError.replacementCycle(
                        descriptor.id.rawValue
                    )
                }
                guard let nextDescriptor = byID[next.rawValue] else {
                    throw MeetingDiarizationCatalogError.unknownReplacementTarget(
                        next.rawValue
                    )
                }
                current = nextDescriptor.replacementID
            }
        }
    }

    static func fallback() -> MeetingDiarizationCatalogSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return lastValid ?? MeetingDiarizationCatalogSnapshot(
            schemaVersion: currentSchemaVersion,
            revision: "empty-fallback",
            descriptors: []
        )
    }
}
