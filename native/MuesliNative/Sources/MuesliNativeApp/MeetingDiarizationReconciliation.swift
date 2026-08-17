import Foundation

enum MeetingDiarizationSelectionTrigger: String, Sendable, Equatable {
    case startup
    case meetingStart
    case install
    case update
    case retry
    case remove
    case repair
}

enum MeetingDiarizationSelectionState: String, Sendable, Equatable {
    case unavailable
    case choiceRequired
    case selected
}

/// Published global selection for future meetings. `profileID`, `source`, and
/// `capabilities` are non-nil only when `state == .selected`.
struct MeetingDiarizationSelection: Sendable, Equatable {
    let state: MeetingDiarizationSelectionState
    let profileID: MeetingDiarizationModelID?
    let source: MeetingDiarizationSelectionSource?
    let readyAlternatives: [MeetingDiarizationModelDescriptor]
    let capabilities: MeetingDiarizationCapabilities?
    let generation: UInt64

    static func placeholder(generation: UInt64) -> MeetingDiarizationSelection {
        MeetingDiarizationSelection(
            state: .unavailable,
            profileID: nil,
            source: nil,
            readyAlternatives: [],
            capabilities: nil,
            generation: generation
        )
    }
}

/// Pure decision produced from authoritative inputs; the controller applies it
/// in one config transaction. Kept I/O-free so the reconciliation semantics
/// are unit-testable without instantiating the full application controller.
struct MeetingDiarizationReconciliationDecision: Sendable, Equatable {
    let selection: MeetingDiarizationSelection
    let storedModelID: String?
    let normalizeLiveOff: Bool

    var shouldPersistSelection: Bool {
        storedModelID != nil
    }
}

enum MeetingDiarizationReconciliation {
    /// Maps legacy asset-status profile IDs onto catalog stable IDs through
    /// descriptor aliases, then applies the pure selection resolver.
    static func plan(
        catalog: MeetingDiarizationCatalogSnapshot,
        statuses: [MeetingDiarizationAssetStatus],
        storedModelID: String?,
        liveDefaultEnabled: Bool,
        generation: UInt64 = 0
    ) -> MeetingDiarizationReconciliationDecision {
        let descriptorByLegacyID = Dictionary(
            catalog.descriptors.compactMap { descriptor -> (String, MeetingDiarizationModelDescriptor)? in
                guard let alias = descriptor.legacyAliases.first else { return nil }
                return (alias, descriptor)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let readyModelIDs = Set(
            statuses.compactMap { status -> MeetingDiarizationModelID? in
                guard status.state == .ready else { return nil }
                return descriptorByLegacyID[status.profileID.rawValue]?.id
            }
        )
        let result = MeetingDiarizationSelectionResolver.resolve(
            MeetingDiarizationSelectionInput(
                catalog: catalog,
                readyModelIDs: readyModelIDs,
                storedModelIDOrLegacyAlias: storedModelID
            )
        )

        switch result {
        case .unavailable(let ready):
            return MeetingDiarizationReconciliationDecision(
                selection: MeetingDiarizationSelection(
                    state: .unavailable,
                    profileID: nil,
                    source: nil,
                    readyAlternatives: ready,
                    capabilities: nil,
                    generation: generation
                ),
                storedModelID: nil,
                normalizeLiveOff: false
            )
        case .choiceRequired(let ready):
            return MeetingDiarizationReconciliationDecision(
                selection: MeetingDiarizationSelection(
                    state: .choiceRequired,
                    profileID: nil,
                    source: nil,
                    readyAlternatives: ready,
                    capabilities: nil,
                    generation: generation
                ),
                storedModelID: nil,
                normalizeLiveOff: false
            )
        case .selected(let modelID, let source, let ready):
            let descriptor = ready.first { $0.id == modelID }
            let needsPersist = storedModelID != modelID.rawValue
            let normalizeLiveOff = liveDefaultEnabled
                && descriptor?.capabilities.supportsLive == false
            return MeetingDiarizationReconciliationDecision(
                selection: MeetingDiarizationSelection(
                    state: .selected,
                    profileID: modelID,
                    source: source,
                    readyAlternatives: ready,
                    capabilities: descriptor?.capabilities,
                    generation: generation
                ),
                storedModelID: needsPersist ? modelID.rawValue : nil,
                normalizeLiveOff: normalizeLiveOff
            )
        }
    }
}
