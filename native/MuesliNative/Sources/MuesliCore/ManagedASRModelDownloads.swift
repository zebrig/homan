import Darwin
import Foundation

/// A third-party ASR model whose transport is owned by Muesli.
public struct ManagedASRModelPlan: Sendable {
    private struct CompletionMarker: Codable {
        struct File: Codable {
            let relativePath: String
            let expectedByteCount: Int64?
        }

        let modelID: String
        let revision: String
        let manifestVersion: String
        let files: [File]
    }

    private static let completionMarkerName = ".muesli-managed-model-complete.json"
    private static let downloadStateName = ".muesli-download-state.json"
    private static let legacyManifestVersion = "legacy-local-v1"

    public let modelID: String
    public let repository: String
    public let revision: String
    public let cacheDirectory: URL
    public let selections: [HuggingFaceModelSelection]
    /// Every inner group is an either/or requirement; every group must be satisfied.
    public let requiredArtifactAlternatives: [[String]]
    public let maximumConcurrency: Int

    public init(
        modelID: String,
        repository: String,
        revision: String = "main",
        cacheDirectory: URL,
        selections: [HuggingFaceModelSelection],
        requiredArtifactAlternatives: [[String]],
        maximumConcurrency: Int = 2
    ) {
        self.modelID = modelID
        self.repository = repository
        self.revision = revision
        self.cacheDirectory = cacheDirectory
        self.selections = selections
        self.requiredArtifactAlternatives = requiredArtifactAlternatives
        self.maximumConcurrency = maximumConcurrency
    }

    /// A stable sibling directory used for resumable transfer. It is never the
    /// runtime-visible model directory, so a partial package cannot be loaded.
    public var stagingDirectory: URL {
        cacheDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(cacheDirectory.lastPathComponent).homan-download",
            isDirectory: true
        )
    }

    /// Stable sibling lock shared by Homan.app and homan-cli. The lock lives
    /// outside the package so deleting or atomically replacing the package does
    /// not remove the serialization primitive itself.
    public var operationLockURL: URL {
        cacheDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(cacheDirectory.lastPathComponent).homan-operation.lock"
        )
    }

    public func replacingCacheDirectory(_ directory: URL) -> Self {
        Self(
            modelID: modelID,
            repository: repository,
            revision: revision,
            cacheDirectory: directory,
            selections: selections,
            requiredArtifactAlternatives: requiredArtifactAlternatives,
            maximumConcurrency: maximumConcurrency
        )
    }

    public func isComplete(fileManager: FileManager = .default) -> Bool {
        guard requiredArtifactsExist(fileManager: fileManager),
              let data = try? Data(contentsOf: completionMarkerURL),
              let marker = try? JSONDecoder().decode(CompletionMarker.self, from: data),
              marker.modelID == modelID,
              marker.revision == revision,
              !marker.files.isEmpty
        else { return false }

        return marker.files.allSatisfy { file in
            let url = cacheDirectory.appendingPathComponent(file.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { return false }
            guard let expectedByteCount = file.expectedByteCount else { return true }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return size == expectedByteCount
        }
    }

    /// True for either a marker-validated managed download or a complete cache
    /// created by a Muesli version that predates managed completion markers.
    /// Legacy recognition is refused when resumable state or partial files are
    /// present, so interrupted managed downloads cannot masquerade as installs.
    public func isAvailableLocally(fileManager: FileManager = .default) -> Bool {
        isComplete(fileManager: fileManager) || isLegacyInstallation(fileManager: fileManager)
    }

    /// Whether this cache predates managed completion markers and still needs
    /// one successful runtime load before it can be trusted as complete.
    public func requiresRuntimeValidation(fileManager: FileManager = .default) -> Bool {
        isLegacyInstallation(fileManager: fileManager)
    }

    /// Records a successful, fully validated coordinator install. The marker
    /// carries every manifest file so readiness cannot be inferred from an
    /// early sentinel while sibling weights are still partial or missing.
    public func recordSuccessfulInstallation(
        _ manifest: ModelDownloadManifest,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let marker = CompletionMarker(
            modelID: modelID,
            revision: revision,
            manifestVersion: manifest.version,
            files: manifest.files.map {
                CompletionMarker.File(
                    relativePath: $0.relativePath,
                    expectedByteCount: $0.expectedByteCount
                )
            }
        )
        try JSONEncoder().encode(marker).write(to: completionMarkerURL, options: .atomic)
    }

    /// Backfills a completion marker after a legacy cache has successfully
    /// loaded through its runtime. This deliberately runs after validation: a
    /// file-presence check alone must never certify a partially installed model.
    public func recordValidatedLegacyInstallationIfNeeded(
        fileManager: FileManager = .default
    ) throws {
        guard !isComplete(fileManager: fileManager),
              isLegacyInstallation(fileManager: fileManager)
        else { return }

        let files = try selectedLocalFiles(fileManager: fileManager)
        guard !files.isEmpty else { return }
        let marker = CompletionMarker(
            modelID: modelID,
            revision: revision,
            manifestVersion: Self.legacyManifestVersion,
            files: files
        )
        try JSONEncoder().encode(marker).write(to: completionMarkerURL, options: .atomic)
    }

    public func delete(fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileManager.removeItem(at: stagingDirectory)
        }
    }

    /// Repairs filesystem states left by an interrupted pre-0.8.4 two-rename
    /// install or by the current atomic swap before cleanup completed. Callers
    /// must hold `operationLockURL` while invoking this method.
    public func reconcileInterruptedInstallation(
        fileManager: FileManager = .default
    ) throws {
        let parent = cacheDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let packageName = cacheDirectory.lastPathComponent
        let contents = try fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        )
        let leftovers = contents.filter {
            let name = $0.lastPathComponent
            // `contentsOfDirectory` does not preserve the directory-hint bit on
            // URL values, so URL equality can miss the stable staging sibling
            // even when both values resolve to the same filesystem path.
            return name == stagingDirectory.lastPathComponent
                || name.hasPrefix(".\(packageName).homan-backup-")
                || name.hasPrefix(".\(packageName).homan-adopt-")
        }
        let newestFirst = leftovers.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }

        if isComplete(fileManager: fileManager) {
            // A stable download sibling may be a fully transferred replacement
            // whose runtime validation was cancelled. Preserve it until the
            // current package successfully loads; at that point loadValidated
            // can safely discard the now-unneeded sibling. Backup/adoption
            // leftovers never carry resumable transfer state.
            for leftover in leftovers where leftover.lastPathComponent != stagingDirectory.lastPathComponent {
                try? fileManager.removeItem(at: leftover)
            }
            return
        }

        guard !fileManager.fileExists(atPath: cacheDirectory.path),
              let previous = newestFirst.first(where: {
                  $0.lastPathComponent.hasPrefix(".\(packageName).homan-backup-")
                      && replacingCacheDirectory($0).isAvailableLocally(fileManager: fileManager)
              })
        else { return }
        try atomicRename(from: previous, to: cacheDirectory)
    }

    /// Reconstructs a conservative paused snapshot from durable staging bytes.
    /// Exact totals return once manifest discovery resumes; recovered bytes are
    /// still shown immediately instead of resetting the UI to a fake zero.
    public func recoveredPausedProgress(
        fileManager: FileManager = .default
    ) -> ModelDownloadProgress? {
        guard fileManager.fileExists(atPath: stagingDirectory.path),
              !replacingCacheDirectory(stagingDirectory).isComplete(fileManager: fileManager),
              let enumerator = fileManager.enumerator(
                  at: stagingDirectory,
                  includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                  options: [.skipsHiddenFiles]
              )
        else { return nil }

        var completedBytes: Int64 = 0
        var partialFile: String?
        var partialBytes: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            completedBytes += size
            if url.pathExtension == "part" {
                partialFile = url.deletingPathExtension().lastPathComponent
                partialBytes = size
            }
        }
        return ModelDownloadProgress(
            modelID: modelID,
            phase: .paused,
            currentFile: partialFile,
            completedBytes: completedBytes,
            totalBytes: nil,
            currentFileCompletedBytes: partialBytes,
            currentFileTotalBytes: nil,
            bytesPerSecond: 0,
            estimatedSecondsRemaining: nil,
            retryCount: 0,
            message: completedBytes > 0
                ? "Download paused; recovered local progress"
                : "Download paused; ready to resume"
        )
    }

    /// Copies a legacy package into Homan-owned storage, validates that exact
    /// copy through the caller's runtime, and only then promotes it atomically.
    /// The legacy source is never modified or deleted.
    public func adoptValidatedInstallation<T: Sendable>(
        from source: ManagedASRModelPlan,
        validate: @escaping @Sendable (URL) async throws -> T,
        fileManager: FileManager = .default
    ) async throws -> T {
        guard source.modelID == modelID,
              source.isAvailableLocally(fileManager: fileManager)
        else { throw ManagedASRModelInstallationError.invalidPackage(modelID) }
        if isComplete(fileManager: fileManager) {
            return try await validate(cacheDirectory)
        }

        let adoptionDirectory = cacheDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(cacheDirectory.lastPathComponent).homan-adopt-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: adoptionDirectory) }
        let adoptionPlan = replacingCacheDirectory(adoptionDirectory)
        for file in try source.selectedLocalFiles(fileManager: fileManager) {
            let sourceURL = source.cacheDirectory.appendingPathComponent(file.relativePath)
            let targetURL = adoptionDirectory.appendingPathComponent(file.relativePath)
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: sourceURL, to: targetURL)
        }
        try adoptionPlan.recordValidatedLegacyInstallationIfNeeded(fileManager: fileManager)
        guard adoptionPlan.isComplete(fileManager: fileManager) else {
            throw ManagedASRModelInstallationError.invalidPackage(modelID)
        }
        // Validate the copied, Homan-owned bytes rather than trusting that a
        // successful load from the legacy source survived the copy unchanged.
        let value = try await validate(adoptionPlan.cacheDirectory)
        try Task.checkCancellation()
        try installAtomically(from: adoptionPlan, fileManager: fileManager)
        return value
    }

    /// Atomically swaps a complete sibling package into the runtime-visible
    /// location. If a package already exists, Darwin `RENAME_SWAP` guarantees
    /// that a crash cannot leave the canonical path absent.
    public func installAtomically(
        from stagedPlan: ManagedASRModelPlan,
        fileManager: FileManager = .default
    ) throws {
        guard stagedPlan.isComplete(fileManager: fileManager) else {
            throw ManagedASRModelInstallationError.invalidPackage(modelID)
        }
        let parent = cacheDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let hadExisting = fileManager.fileExists(atPath: cacheDirectory.path)
        if hadExisting {
            try atomicSwap(stagedPlan.cacheDirectory, cacheDirectory)
        } else {
            try atomicRename(from: stagedPlan.cacheDirectory, to: cacheDirectory)
        }

        guard isComplete(fileManager: fileManager) else {
            do {
                if hadExisting {
                    try atomicSwap(stagedPlan.cacheDirectory, cacheDirectory)
                } else {
                    try atomicRename(from: cacheDirectory, to: stagedPlan.cacheDirectory)
                }
            } catch {
                throw ManagedASRModelInstallationError.rollbackFailed(modelID, error.localizedDescription)
            }
            throw ManagedASRModelInstallationError.invalidPackage(modelID)
        }
        if hadExisting, fileManager.fileExists(atPath: stagedPlan.cacheDirectory.path) {
            // The canonical package is already durable. A failed cleanup only
            // leaves a recoverable sibling that launch reconciliation removes.
            try? fileManager.removeItem(at: stagedPlan.cacheDirectory)
        }
    }

    private func atomicSwap(_ first: URL, _ second: URL) throws {
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw ManagedASRModelInstallationError.atomicPromotionFailed(
                modelID,
                String(cString: strerror(errno))
            )
        }
    }

    private func atomicRename(from source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw ManagedASRModelInstallationError.atomicPromotionFailed(
                modelID,
                String(cString: strerror(errno))
            )
        }
    }

    private var completionMarkerURL: URL {
        cacheDirectory.appendingPathComponent(Self.completionMarkerName)
    }

    private func requiredArtifactsExist(fileManager: FileManager) -> Bool {
        !requiredArtifactAlternatives.isEmpty
            && requiredArtifactAlternatives.allSatisfy { alternatives in
                alternatives.contains { relativePath in
                    fileManager.fileExists(
                        atPath: cacheDirectory.appendingPathComponent(relativePath).path
                    )
                }
            }
    }

    private func isLegacyInstallation(fileManager: FileManager) -> Bool {
        guard requiredArtifactsExist(fileManager: fileManager),
              !fileManager.fileExists(atPath: completionMarkerURL.path),
              !fileManager.fileExists(
                atPath: cacheDirectory.appendingPathComponent(Self.downloadStateName).path
              )
        else { return false }

        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "part" {
            return false
        }
        return true
    }

    private func selectedLocalFiles(fileManager: FileManager) throws -> [CompletionMarker.File] {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let rootPath = cacheDirectory.standardizedFileURL.path
        var files: [CompletionMarker.File] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            guard isSelected(relativePath: relativePath) else { continue }
            files.append(CompletionMarker.File(
                relativePath: relativePath,
                expectedByteCount: values.fileSize.map(Int64.init)
            ))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func isSelected(relativePath: String) -> Bool {
        selections.contains { selection in
            let destination = selection.destinationDirectory.map { $0 + "/" } ?? ""
            if selection.includedPaths.isEmpty {
                return destination.isEmpty || relativePath.hasPrefix(destination)
            }
            return selection.includedPaths.contains { includedPath in
                let selectedPath = destination + includedPath
                return relativePath == selectedPath || relativePath.hasPrefix(selectedPath + "/")
            }
        }
    }
}

public enum ManagedASRModelInstallationError: Error, LocalizedError, Sendable {
    case invalidPackage(String)
    case atomicPromotionFailed(String, String)
    case rollbackFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidPackage(let modelID):
            return "The downloaded model package failed validation: \(modelID)"
        case .atomicPromotionFailed(let modelID, let detail):
            return "Could not atomically install model \(modelID): \(detail)"
        case .rollbackFailed(let modelID, let detail):
            return "Could not restore model \(modelID) after a failed install: \(detail)"
        }
    }
}

/// Canonical cache layouts and artifact sets shared by the app and CLI.
public enum ManagedASRModelPlans {
    private static let fluidAudioRootRelativePath = "Library/Application Support/FluidAudio/Models"

    public static func fluidAudioModelsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(fluidAudioRootRelativePath, isDirectory: true)
    }

    public static func parakeetV2(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
            "JointDecision.mlmodelc", "parakeet_vocab.json",
        ]
        return fluidAudioPlan(
            modelID: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            repository: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            revision: "ee09c569f73759e6d44c9bd16766f477b2b36d39",
            directoryName: "parakeet-tdt-0.6b-v2",
            required: required,
            modelsRoot: modelsRoot
        )
    }

    public static func parakeetV3(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
            "JointDecisionv3.mlmodelc", "parakeet_vocab.json",
        ]
        return fluidAudioPlan(
            modelID: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
            directoryName: "parakeet-tdt-0.6b-v3",
            required: required,
            modelsRoot: modelsRoot
        )
    }

    /// Parakeet Unified 0.6B (FastConformer-RNNT), English-focused offline batch
    /// path: int8 full-attention encoder + decoder + joint + vocabulary.
    public static func parakeetUnified(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "parakeet_unified_encoder_int8.mlmodelc",
            "parakeet_unified_decoder.mlmodelc",
            "parakeet_unified_joint_decision_single_step.mlmodelc",
            "vocab.json",
            "metadata.json",
        ]
        return fluidAudioPlan(
            modelID: "FluidInference/parakeet-unified-en-0.6b-coreml",
            repository: "FluidInference/parakeet-unified-en-0.6b-coreml",
            directoryName: "parakeet-unified-en-0.6b-coreml",
            required: required,
            modelsRoot: modelsRoot
        )
    }

    public static func senseVoice(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "SenseVoicePreprocessor.mlmodelc", "SenseVoiceSmall_int8.mlmodelc", "vocab.json",
        ]
        return fluidAudioPlan(
            modelID: "FluidInference/sensevoice-small-coreml",
            repository: "FluidInference/sensevoice-small-coreml",
            directoryName: "sensevoice-small-coreml",
            required: required,
            modelsRoot: modelsRoot
        )
    }

    public static func qwen3ASRInt8(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let directory = (modelsRoot ?? fluidAudioModelsRoot())
            .appendingPathComponent("qwen3-asr-0.6b/int8", isDirectory: true)
        return qwen3ASRInt8(cacheDirectory: directory)
    }

    /// Qwen3 ASR int8 plan with an explicit install directory, so callers can
    /// install into any location the managed downloader supports.
    public static func qwen3ASRInt8(cacheDirectory: URL) -> ManagedASRModelPlan {
        let required = [
            "qwen3_asr_audio_encoder_v2.mlmodelc",
            "qwen3_asr_decoder_stateful.mlmodelc",
            "qwen3_asr_embeddings.bin",
            "vocab.json",
        ]
        return ManagedASRModelPlan(
            modelID: "FluidInference/qwen3-asr-0.6b-coreml",
            repository: "FluidInference/qwen3-asr-0.6b-coreml",
            cacheDirectory: cacheDirectory,
            selections: [
                HuggingFaceModelSelection(
                    remoteDirectory: "int8",
                    includedPaths: Set(required),
                    recursive: true
                )
            ],
            requiredArtifactAlternatives: completenessRequirements(for: required)
        )
    }

    public static func parakeetRealtimeEOU320(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json",
        ]
        let directory = (modelsRoot ?? fluidAudioModelsRoot())
            .appendingPathComponent("parakeet-eou-streaming/320ms", isDirectory: true)
        return ManagedASRModelPlan(
            modelID: "FluidInference/parakeet-realtime-eou-120m-coreml/320ms",
            repository: "FluidInference/parakeet-realtime-eou-120m-coreml",
            cacheDirectory: directory,
            selections: [
                HuggingFaceModelSelection(
                    remoteDirectory: "320ms",
                    includedPaths: Set(required),
                    recursive: true
                )
            ],
            requiredArtifactAlternatives: completenessRequirements(for: required)
        )
    }

    public static func whisperKit(
        modelName: String,
        downloadRoot: URL? = nil
    ) -> ManagedASRModelPlan {
        let fullName = modelName.hasPrefix("openai_whisper-") ? modelName : "openai_whisper-\(modelName)"
        let root = downloadRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let directory = root.appendingPathComponent(fullName, isDirectory: true)
        let requiredModels = [
            "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
        ]
        let requiredFiles = requiredModels + ["config.json", "generation_config.json"]
        return ManagedASRModelPlan(
            modelID: modelName,
            repository: "argmaxinc/whisperkit-coreml",
            cacheDirectory: directory,
            selections: [HuggingFaceModelSelection(
                remoteDirectory: fullName,
                includedPaths: Set(requiredFiles)
            )],
            requiredArtifactAlternatives: completenessRequirements(for: requiredFiles)
        )
    }

    private static func fluidAudioPlan(
        modelID: String,
        repository: String,
        revision: String = "main",
        directoryName: String,
        required: [String],
        modelsRoot: URL?
    ) -> ManagedASRModelPlan {
        let directory = (modelsRoot ?? fluidAudioModelsRoot())
            .appendingPathComponent(directoryName, isDirectory: true)
        return ManagedASRModelPlan(
            modelID: modelID,
            repository: repository,
            revision: revision,
            cacheDirectory: directory,
            selections: [HuggingFaceModelSelection(includedPaths: Set(required))],
            requiredArtifactAlternatives: completenessRequirements(for: required)
        )
    }

    private static func completenessRequirements(for paths: [String]) -> [[String]] {
        paths.flatMap { path in
            if path.hasSuffix(".mlmodelc") {
                return [
                    [path + "/coremldata.bin"],
                    [path + "/weights/weight.bin"],
                ]
            }
            return [[path]]
        }
    }
}

/// Bridges Hugging Face discovery to the resumable coordinator and legacy scalar UI callbacks.
public enum ManagedASRModelDownloader {
    private enum PreparedDirectory: Sendable {
        case installed(URL)
        case staged(ManagedASRModelPlan)

        var url: URL {
            switch self {
            case .installed(let url): return url
            case .staged(let plan): return plan.cacheDirectory
            }
        }
    }

    private static let operations = ManagedASRModelOperations()

    /// Downloads missing bytes into an isolated staging directory. A newly
    /// downloaded package is deliberately not promoted by this transport-only
    /// API because only the model runtime can prove that it is actually usable.
    @discardableResult
    public static func downloadIfNeeded(
        _ plan: ManagedASRModelPlan,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil,
        resolver: HuggingFaceModelManifestResolver = .shared,
        coordinator: ModelDownloadCoordinator = .shared
    ) async throws -> URL {
        try await operations.run(modelID: plan.modelID, lockURL: plan.operationLockURL) {
            let prepared = try await downloadDirectoryIfNeeded(
                plan,
                progress: progress,
                progressSnapshot: progressSnapshot,
                resolver: resolver,
                coordinator: coordinator
            )
            return prepared.url
        }
    }

    /// Loads a managed model and validates markerless legacy caches through the
    /// real runtime. A legacy cache that cannot load is retained while a fresh
    /// staged package is downloaded; a successful legacy load is promoted to a strict,
    /// size-aware managed installation without requiring network access.
    public static func loadValidated<T: Sendable>(
        _ plan: ManagedASRModelPlan,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil,
        resolver: HuggingFaceModelManifestResolver = .shared,
        coordinator: ModelDownloadCoordinator = .shared,
        finalize: (@Sendable (T) async throws -> Void)? = nil,
        load: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await operations.run(modelID: plan.modelID, lockURL: plan.operationLockURL) {
            let hadLocalPackage = plan.isAvailableLocally()
            let prepared = try await downloadDirectoryIfNeeded(
                plan,
                progress: progress,
                progressSnapshot: progressSnapshot,
                resolver: resolver,
                coordinator: coordinator
            )

            switch prepared {
            case .staged(let stagedPlan):
                return try await validateAndInstall(
                    stagedPlan,
                    as: plan,
                    progress: progress,
                    progressSnapshot: progressSnapshot,
                    coordinator: coordinator,
                    finalize: finalize,
                    load: load
                )
            case .installed(let directory):
                let value: T
                do {
                    value = try await load(directory)
                    try? plan.recordValidatedLegacyInstallationIfNeeded()
                    if FileManager.default.fileExists(atPath: plan.stagingDirectory.path) {
                        try? FileManager.default.removeItem(at: plan.stagingDirectory)
                    }
                } catch {
                    let validationError = error
                    guard hadLocalPackage, !(error is CancellationError) else {
                        await publishValidationFailure(
                            validationError,
                            modelID: plan.modelID,
                            progressSnapshot: progressSnapshot,
                            coordinator: coordinator
                        )
                        throw validationError
                    }
                    try Task.checkCancellation()
                    guard plan.isAvailableLocally() else { throw validationError }

                    // The current package remains untouched until a freshly
                    // downloaded sibling passes the real runtime loader.
                    let stagedPlan = try await performDownload(
                        plan,
                        progress: progress,
                        progressSnapshot: progressSnapshot,
                        resolver: resolver,
                        coordinator: coordinator
                    )
                    return try await validateAndInstall(
                        stagedPlan,
                        as: plan,
                        progress: progress,
                        progressSnapshot: progressSnapshot,
                        coordinator: coordinator,
                        finalize: finalize,
                        load: load
                    )
                }
                do {
                    try await finalize?(value)
                    return value
                } catch {
                    await publishValidationFailure(
                        error,
                        modelID: plan.modelID,
                        progressSnapshot: progressSnapshot,
                        coordinator: coordinator
                    )
                    throw error
                }
            }
        }
    }

    /// Cancels manifest discovery and transfer for a model without blocking a
    /// later resume.
    public static func cancel(
        modelID: String,
        coordinator: ModelDownloadCoordinator = .shared
    ) async {
        await operations.cancel(modelID: modelID)
        await coordinator.cancel(modelID: modelID)
    }

    /// Cancels and awaits manifest discovery plus any registered transfer.
    public static func cancelAndWait(
        modelID: String,
        coordinator: ModelDownloadCoordinator = .shared
    ) async {
        await operations.cancelAndWait(modelID: modelID)
        await coordinator.cancelAndWait(modelID: modelID)
    }

    /// Blocks new operations for a model while callers remove its cache.
    public static func beginDeletion(
        _ plan: ManagedASRModelPlan,
        coordinator: ModelDownloadCoordinator = .shared
    ) async throws -> ManagedASRModelDeletionToken {
        let localToken = try await operations.beginDeletion(modelID: plan.modelID)
        await coordinator.cancelAndWait(modelID: plan.modelID)
        do {
            let fileLock = try await ManagedASRInterprocessLock.acquire(at: plan.operationLockURL)
            return ManagedASRModelDeletionToken(
                modelID: localToken.modelID,
                id: localToken.id,
                fileLock: fileLock
            )
        } catch {
            await operations.endDeletion(localToken)
            throw error
        }
    }

    public static func endDeletion(_ token: ManagedASRModelDeletionToken) async {
        token.fileLock?.unlock()
        await operations.endDeletion(token)
    }

    /// Registers non-download model work (for example read-only legacy
    /// validation and adoption) in the same lifecycle domain as downloads, so
    /// deletion cancels and awaits the complete operation before touching disk.
    public static func withRegisteredOperation<T: Sendable>(
        _ plan: ManagedASRModelPlan,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await operations.run(
            modelID: plan.modelID,
            lockURL: plan.operationLockURL,
            operation: operation
        )
    }

    private static func downloadDirectoryIfNeeded(
        _ plan: ManagedASRModelPlan,
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?,
        resolver: HuggingFaceModelManifestResolver,
        coordinator: ModelDownloadCoordinator
    ) async throws -> PreparedDirectory {
        try plan.reconcileInterruptedInstallation()
        if plan.isAvailableLocally() {
            let snapshot = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Validating local model..."
            )
            await coordinator.publish(snapshot)
            progressSnapshot?(snapshot)
            progress?(0.97, snapshot.message)
            return .installed(plan.cacheDirectory)
        }

        return .staged(try await performDownload(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot,
            resolver: resolver,
            coordinator: coordinator
        ))
    }

    private static func performDownload(
        _ plan: ManagedASRModelPlan,
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?,
        resolver: HuggingFaceModelManifestResolver,
        coordinator: ModelDownloadCoordinator
    ) async throws -> ManagedASRModelPlan {
        try Task.checkCancellation()

        let scalarProgress = ManagedASRScalarProgressRelay(progress)
        let stagedPlan = plan.replacingCacheDirectory(plan.stagingDirectory)
        if stagedPlan.isComplete() {
            let recovered = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Validating recovered model download..."
            )
            await coordinator.publish(recovered)
            progressSnapshot?(recovered)
            scalarProgress.call(0.97, recovered.message)
            return stagedPlan
        }

        scalarProgress.call(0.01, "Finding model files...")
        let discoverySnapshot = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: "Finding model files..."
        )
        await coordinator.publish(discoverySnapshot)
        progressSnapshot?(discoverySnapshot)

        do {
            let manifest = try await resolver.resolve(
                modelID: plan.modelID,
                repository: plan.repository,
                revision: plan.revision,
                selections: plan.selections,
                maximumConcurrency: plan.maximumConcurrency
            )
            try await coordinator.download(manifest, to: stagedPlan.cacheDirectory) { snapshot in
                if let fraction = snapshot.fractionCompleted {
                    scalarProgress.call(min(0.95, fraction * 0.95), snapshot.message)
                }
                progressSnapshot?(snapshot)
            }
            let transferSnapshot = await coordinator.progress(for: plan.modelID)
            let validatingSnapshot = (transferSnapshot
                ?? ModelDownloadProgress.preparing(modelID: plan.modelID, message: "Validating model..."))
                .replacing(phase: .preparing, message: "Validating model before installation...")
            await coordinator.publish(validatingSnapshot)
            progressSnapshot?(validatingSnapshot)

            try stagedPlan.recordSuccessfulInstallation(manifest)
            guard stagedPlan.isComplete() else {
                throw ManagedASRModelInstallationError.invalidPackage(plan.modelID)
            }
            scalarProgress.call(0.97, validatingSnapshot.message)
            return stagedPlan
        } catch {
            let latest = await coordinator.progress(for: plan.modelID)
                ?? discoverySnapshot
            let terminal = latest.replacing(
                phase: error is CancellationError ? .paused : .failed,
                message: error is CancellationError ? "Download paused" : error.localizedDescription
            )
            await coordinator.publish(terminal)
            progressSnapshot?(terminal)
            throw error
        }
    }

    private static func validateAndInstall<T: Sendable>(
        _ stagedPlan: ManagedASRModelPlan,
        as targetPlan: ManagedASRModelPlan,
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?,
        coordinator: ModelDownloadCoordinator,
        finalize: (@Sendable (T) async throws -> Void)?,
        load: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        let validating = ModelDownloadProgress.preparing(
            modelID: targetPlan.modelID,
            message: "Loading downloaded model into its runtime..."
        )
        await coordinator.publish(validating)
        progressSnapshot?(validating)
        progress?(0.98, validating.message)

        let value: T
        do {
            value = try await load(stagedPlan.cacheDirectory)
            try Task.checkCancellation()
        } catch {
            if !(error is CancellationError) {
                // A structurally complete package that the runtime rejects must
                // not be reused forever on the next retry.
                try? FileManager.default.removeItem(at: stagedPlan.cacheDirectory)
            }
            await publishValidationFailure(
                error,
                modelID: targetPlan.modelID,
                progressSnapshot: progressSnapshot,
                coordinator: coordinator
            )
            throw error
        }

        do {
            try targetPlan.installAtomically(from: stagedPlan)
            guard targetPlan.isComplete() else {
                throw ManagedASRModelInstallationError.invalidPackage(targetPlan.modelID)
            }
            let installed = validating.replacing(
                phase: .preparing,
                message: "Model installed; finalizing runtime..."
            )
            await coordinator.publish(installed)
            progressSnapshot?(installed)
            progress?(0.99, installed.message)
            try await finalize?(value)
            return value
        } catch {
            await publishValidationFailure(
                error,
                modelID: targetPlan.modelID,
                progressSnapshot: progressSnapshot,
                coordinator: coordinator
            )
            throw error
        }
    }

    private static func publishValidationFailure(
        _ error: Error,
        modelID: String,
        progressSnapshot: ModelDownloadProgressHandler?,
        coordinator: ModelDownloadCoordinator
    ) async {
        let latest = await coordinator.progress(for: modelID)
            ?? ModelDownloadProgress.preparing(modelID: modelID, message: "Validating model...")
        let terminal = latest.replacing(
            phase: error is CancellationError ? .paused : .failed,
            message: error is CancellationError ? "Model validation paused" : error.localizedDescription
        )
        await coordinator.publish(terminal)
        progressSnapshot?(terminal)
    }
}

public struct ManagedASRModelDeletionToken: Sendable {
    fileprivate let modelID: String
    fileprivate let id: UUID
    fileprivate let fileLock: ManagedASRInterprocessLockHandle?
}

private actor ManagedASRModelOperations {
    private struct Operation {
        let id: UUID
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private struct PermitWaiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var operations: [String: Operation] = [:]
    private var activePermits: [String: UUID] = [:]
    private var permitWaiters: [String: [PermitWaiter]] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []
    private var deletionTokens: [String: UUID] = [:]

    func run<T: Sendable>(
        modelID: String,
        lockURL: URL,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let permitID = try await acquirePermit(modelID: modelID)
        guard deletionTokens[modelID] == nil else {
            releasePermit(modelID: modelID, id: permitID)
            throw CancellationError()
        }
        let task = Task {
            let fileLock = try await ManagedASRInterprocessLock.acquire(at: lockURL)
            defer { fileLock.unlock() }
            try Task.checkCancellation()
            return try await operation()
        }
        operations[modelID] = Operation(
            id: permitID,
            cancel: { task.cancel() },
            wait: { _ = try? await task.value }
        )
        defer {
            if operations[modelID]?.id == permitID {
                operations[modelID] = nil
            }
            releasePermit(modelID: modelID, id: permitID)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel(modelID: String) {
        failPermitWaiters(modelID: modelID)
        operations[modelID]?.cancel()
    }

    func cancelAndWait(modelID: String) async {
        failPermitWaiters(modelID: modelID)
        let active = operations[modelID]
        active?.cancel()
        await active?.wait()
    }

    func beginDeletion(modelID: String) async throws -> ManagedASRModelDeletionToken {
        guard deletionTokens[modelID] == nil else {
            throw ManagedASRModelOperationError.deletionAlreadyInProgress(modelID)
        }
        let token = ManagedASRModelDeletionToken(modelID: modelID, id: UUID(), fileLock: nil)
        deletionTokens[modelID] = token.id
        failPermitWaiters(modelID: modelID)
        await cancelAndWait(modelID: modelID)
        return token
    }

    func endDeletion(_ token: ManagedASRModelDeletionToken) {
        guard deletionTokens[token.modelID] == token.id else { return }
        deletionTokens[token.modelID] = nil
    }

    private func acquirePermit(modelID: String) async throws -> UUID {
        try Task.checkCancellation()
        guard deletionTokens[modelID] == nil else { throw CancellationError() }
        let id = UUID()
        guard activePermits[modelID] != nil else {
            activePermits[modelID] = id
            return id
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || cancelledWaiterIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    permitWaiters[modelID, default: []].append(
                        PermitWaiter(id: id, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelPermitWaiter(modelID: modelID, id: id) }
        }
    }

    private func cancelPermitWaiter(modelID: String, id: UUID) {
        guard let index = permitWaiters[modelID]?.firstIndex(where: { $0.id == id }) else {
            cancelledWaiterIDs.insert(id)
            return
        }
        let waiter = permitWaiters[modelID]!.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releasePermit(modelID: String, id: UUID) {
        guard activePermits[modelID] == id else { return }
        if deletionTokens[modelID] != nil {
            activePermits[modelID] = nil
            failPermitWaiters(modelID: modelID)
            return
        }

        while !(permitWaiters[modelID]?.isEmpty ?? true) {
            let waiter = permitWaiters[modelID]!.removeFirst()
            if cancelledWaiterIDs.remove(waiter.id) != nil {
                waiter.continuation.resume(throwing: CancellationError())
                continue
            }
            activePermits[modelID] = waiter.id
            waiter.continuation.resume(returning: waiter.id)
            return
        }
        activePermits[modelID] = nil
    }

    private func failPermitWaiters(modelID: String) {
        let waiters = permitWaiters.removeValue(forKey: modelID) ?? []
        for waiter in waiters {
            cancelledWaiterIDs.remove(waiter.id)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
}

public enum ManagedASRModelOperationError: Error, LocalizedError, Sendable {
    case deletionAlreadyInProgress(String)

    public var errorDescription: String? {
        switch self {
        case .deletionAlreadyInProgress(let modelID):
            return "A deletion is already in progress for model \(modelID)."
        }
    }
}

private final class ManagedASRScalarProgressRelay: @unchecked Sendable {
    private let handler: ((Double, String?) -> Void)?

    init(_ handler: ((Double, String?) -> Void)?) {
        self.handler = handler
    }

    func call(_ fraction: Double, _ message: String?) {
        handler?(fraction, message)
    }
}
