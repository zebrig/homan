import FluidAudio
import Foundation
import MuesliCore
import MuesliFluidAudioSupport

/// Native Swift transcription backend using FluidAudio's Parakeet TDT model
/// running on Apple's Neural Engine (ANE) via CoreML.
actor FluidAudioTranscriber {
    private var asrManager: AsrManager?
    private var loadedVersion: AsrModelVersion?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "FluidAudio models not loaded. Call loadModels() first."
            }
        }
    }

    /// Downloads models (if needed) and initializes the ASR manager.
    /// - Parameter version: .v3 for multilingual (25 langs), .v2 for English-only
    func loadModels(
        version: AsrModelVersion = .v3,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if loadedVersion == version, asrManager != nil { return }

        fputs("[fluidaudio] downloading/loading models (version: \(version))...\n", stderr)
        let plan = HomanModelDownloadCenter.parakeetPlan(version: version)
        let legacyPlan = HomanModelDownloadCenter.legacyParakeetPlan(version: version)

        if !plan.isAvailableLocally(),
           !HomanModelDownloadCenter.isLegacySuppressed(
               version == .v2 ? .parakeetEnglish : .parakeetMultilingual
           ),
           legacyPlan.isAvailableLocally() {
            do {
                let adopted = try await ManagedASRModelDownloader.withRegisteredOperation(plan) {
                    try plan.reconcileInterruptedInstallation()
                    guard !plan.isAvailableLocally(),
                          !HomanModelDownloadCenter.isLegacySuppressed(
                              version == .v2 ? .parakeetEnglish : .parakeetMultilingual
                          ),
                          legacyPlan.isAvailableLocally()
                    else { return false }
                    let validating = ModelDownloadProgress.preparing(
                        modelID: plan.modelID,
                        message: "Validating existing Parakeet model..."
                    )
                    await HomanModelDownloadCenter.shared.publish(validating)
                    progressSnapshot?(validating)
                    progress?(0.9, validating.message)
                    let adopting = validating.replacing(
                        phase: .preparing,
                        message: "Importing model into Homan..."
                    )
                    await HomanModelDownloadCenter.shared.publish(adopting)
                    progressSnapshot?(adopting)
                    progress?(0.96, adopting.message)
                    let manager = try await plan.adoptValidatedInstallation(from: legacyPlan) { copiedDirectory in
                        let validatingCopy = adopting.replacing(
                            phase: .preparing,
                            message: "Validating imported Parakeet model..."
                        )
                        await HomanModelDownloadCenter.shared.publish(validatingCopy)
                        progressSnapshot?(validatingCopy)
                        progress?(0.98, validatingCopy.message)
                        return try await Self.loadManager(from: copiedDirectory, version: version)
                    }
                    try Task.checkCancellation()
                    try await self.commitLoadedManager(manager, version: version)
                    let ready = adopting.replacing(phase: .ready, message: "Model ready")
                    await HomanModelDownloadCenter.shared.publish(ready)
                    progressSnapshot?(ready)
                    progress?(1, ready.message)
                    return true
                }
                if adopted {
                    fputs("[fluidaudio] existing models validated and ready\n", stderr)
                    return
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Never delete or mutate the old cache. A broken legacy package
                // falls through to a fresh staged Homan-owned download.
                fputs("[fluidaudio] existing model validation failed; downloading managed copy: \(error)\n", stderr)
            }
        }

        _ = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot,
            finalize: { manager in
                try Task.checkCancellation()
                try await self.commitLoadedManager(manager, version: version)
                let ready = ModelDownloadProgress.ready(modelID: plan.modelID)
                await HomanModelDownloadCenter.shared.publish(ready)
                progressSnapshot?(ready)
                progress?(1, ready.message)
            }
        ) { modelDirectory in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading Parakeet into Core ML..."
            )
            await HomanModelDownloadCenter.shared.publish(preparing)
            progressSnapshot?(preparing)
            progress?(0.98, preparing.message)
            return try await Self.loadManager(from: modelDirectory, version: version)
        }
        fputs("[fluidaudio] models ready\n", stderr)
    }

    private func commitLoadedManager(
        _ manager: AsrManager,
        version: AsrModelVersion
    ) throws {
        try Task.checkCancellation()
        asrManager = manager
        loadedVersion = version
    }

    private static func loadManager(
        from directory: URL,
        version: AsrModelVersion
    ) async throws -> AsrManager {
        let models = try await OfflineParakeetModelLoader.load(from: directory, version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return manager
    }

    /// Transcribe a WAV file URL directly.
    func transcribe(wavURL: URL) async throws -> ASRResult {
        guard let asrManager else { throw TranscriberError.notLoaded }
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        return try await asrManager.transcribe(wavURL, decoderState: &decoderState)
    }

    func shutdown() {
        asrManager = nil
        loadedVersion = nil
    }

    func shutdown(ifLoadedVersion version: AsrModelVersion) {
        guard loadedVersion == version else { return }
        shutdown()
    }
}
