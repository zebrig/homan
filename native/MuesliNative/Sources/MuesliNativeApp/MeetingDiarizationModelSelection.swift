import Foundation

enum MeetingDiarizationSelectionSource: String, Codable, Sendable, Equatable {
    case soleReady
    case storedPreference
    case legacyAliasMigration
    case explicitUserChoice
}

struct MeetingDiarizationSelectionInput: Equatable, Sendable {
    let catalog: MeetingDiarizationCatalogSnapshot
    let readyModelIDs: Set<MeetingDiarizationModelID>
    let storedModelIDOrLegacyAlias: String?

    init(
        catalog: MeetingDiarizationCatalogSnapshot,
        readyModelIDs: Set<MeetingDiarizationModelID>,
        storedModelIDOrLegacyAlias: String? = nil
    ) {
        self.catalog = catalog
        self.readyModelIDs = readyModelIDs
        self.storedModelIDOrLegacyAlias = storedModelIDOrLegacyAlias
    }
}

enum MeetingDiarizationSelectionResult: Equatable, Sendable {
    case unavailable(readyDescriptors: [MeetingDiarizationModelDescriptor])
    case choiceRequired(readyDescriptors: [MeetingDiarizationModelDescriptor])
    case selected(
        modelID: MeetingDiarizationModelID,
        source: MeetingDiarizationSelectionSource,
        readyDescriptors: [MeetingDiarizationModelDescriptor]
    )
}

/// Pure, deterministic, I/O-free resolution of the shared concrete model.
///
/// Truth table (R = ready/selectable descriptors in catalog order):
///   R={}                          -> unavailable
///   R={A}                         -> A, soleReady (stale preference ignored)
///   |R|>=2 and stored == P in R   -> P, storedPreference
///   |R|>=2 and alias maps to L    -> L, legacyAliasMigration
///   |R|>=2 and no valid target    -> choiceRequired (never a fallback name)
enum MeetingDiarizationSelectionResolver {
    static func resolve(
        _ input: MeetingDiarizationSelectionInput
    ) -> MeetingDiarizationSelectionResult {
        let ready = input.catalog.descriptors.filter { descriptor in
            descriptor.isSelectable && input.readyModelIDs.contains(descriptor.id)
        }

        guard !ready.isEmpty else {
            return .unavailable(readyDescriptors: [])
        }

        if ready.count == 1 {
            return .selected(
                modelID: ready[0].id,
                source: .soleReady,
                readyDescriptors: ready
            )
        }

        if let stored = input.storedModelIDOrLegacyAlias {
            if let direct = ready.first(where: { $0.id.rawValue == stored }) {
                return .selected(
                    modelID: direct.id,
                    source: .storedPreference,
                    readyDescriptors: ready
                )
            }
            if let aliased = resolveLegacyAlias(stored, catalog: input.catalog, ready: ready) {
                return .selected(
                    modelID: aliased.id,
                    source: .legacyAliasMigration,
                    readyDescriptors: ready
                )
            }
        }

        return .choiceRequired(readyDescriptors: ready)
    }

    private static func resolveLegacyAlias(
        _ stored: String,
        catalog: MeetingDiarizationCatalogSnapshot,
        ready: [MeetingDiarizationModelDescriptor]
    ) -> MeetingDiarizationModelDescriptor? {
        if stored == MeetingDiarizationCompatibility.automaticAlias,
           let automaticTarget = MeetingDiarizationCompatibility
               .historicalAutomaticTarget(in: catalog) {
            return ready.first { $0.id == automaticTarget }
        }
        return ready.first { $0.legacyAliases.contains(stored) }
    }
}
