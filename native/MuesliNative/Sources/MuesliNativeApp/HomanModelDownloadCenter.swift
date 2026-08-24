import FluidAudio
import Foundation
import MuesliCore

/// Homan-owned model locations and compatibility adoption for the first model
/// family migrated to the unified download center.
enum HomanModelDownloadCenter {
    /// The single process-wide mutable job and progress owner.
    static let shared = ModelDownloadCoordinator.shared

    static func modelsRoot(
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) -> URL {
        supportDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("ManagedASR", isDirectory: true)
    }

    static func parakeetPlan(
        version: AsrModelVersion,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) -> ManagedASRModelPlan {
        version == .v2
            ? ManagedASRModelPlans.parakeetV2(modelsRoot: modelsRoot(supportDirectory: supportDirectory))
            : ManagedASRModelPlans.parakeetV3(modelsRoot: modelsRoot(supportDirectory: supportDirectory))
    }

    static func legacyParakeetPlan(
        version: AsrModelVersion,
        modelsRoot: URL? = nil
    ) -> ManagedASRModelPlan {
        let resolvedRoot: URL?
        if let modelsRoot {
            resolvedRoot = modelsRoot
        } else if AppIdentity.isRunningTests {
            resolvedRoot = AppIdentity.supportDirectoryURL
                .appendingPathComponent("ModelTestFixtures", isDirectory: true)
                .appendingPathComponent("LegacyFluidAudio", isDirectory: true)
        } else {
            resolvedRoot = nil
        }
        return version == .v2
            ? ManagedASRModelPlans.parakeetV2(modelsRoot: resolvedRoot)
            : ManagedASRModelPlans.parakeetV3(modelsRoot: resolvedRoot)
    }

    static func legacyParakeetPlan(for option: BackendOption) -> ManagedASRModelPlan? {
        guard option.backend == "fluidaudio", option.model.contains("parakeet") else {
            return nil
        }
        return legacyParakeetPlan(version: option.model.contains("v2") ? .v2 : .v3)
    }

    static func parakeetPlan(for option: BackendOption) -> ManagedASRModelPlan? {
        guard option.backend == "fluidaudio", option.model.contains("parakeet") else {
            return nil
        }
        return parakeetPlan(version: option.model.contains("v2") ? .v2 : .v3)
    }

    static func isLegacySuppressed(
        _ option: BackendOption,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default
    ) -> Bool {
        ManagedASRLegacyAdoptionPolicy.isSuppressed(
            modelID: option.model,
            supportDirectory: supportDirectory,
            fileManager: fileManager
        )
    }

    static func suppressLegacyAdoption(
        _ option: BackendOption,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default
    ) throws {
        try ManagedASRLegacyAdoptionPolicy.suppress(
            modelID: option.model,
            supportDirectory: supportDirectory,
            fileManager: fileManager
        )
    }

    /// UI/runtime readiness is stricter than legacy-candidate discovery. Only a
    /// Homan-owned package with a completion marker is ready. A structurally
    /// complete FluidAudio cache remains a migration candidate until the real
    /// Core ML runtime validates and adopts it.
    static func isAvailableLocally(
        _ option: BackendOption,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        legacyModelsRoot: URL? = nil
    ) -> Bool {
        guard option.backend == "fluidaudio", option.model.contains("parakeet") else {
            return false
        }
        let version: AsrModelVersion = option.model.contains("v2") ? .v2 : .v3
        let ownedPlan = parakeetPlan(version: version, supportDirectory: supportDirectory)
        return ownedPlan.isComplete()
    }

    /// Reconciles interrupted atomic installs once per launch under the same
    /// app/CLI lock used by downloads and deletion.
    static func reconcileManagedPackages() async {
        for version: AsrModelVersion in [.v2, .v3] {
            let plan = parakeetPlan(version: version)
            do {
                try await ManagedASRModelDownloader.withRegisteredOperation(plan) {
                    try plan.reconcileInterruptedInstallation()
                    if let paused = plan.recoveredPausedProgress() {
                        await shared.publish(paused)
                    }
                }
            } catch is CancellationError {
                continue
            } catch {
                fputs("[homan-models] launch reconciliation failed for \(plan.modelID): \(error)\n", stderr)
            }
        }
    }
}
