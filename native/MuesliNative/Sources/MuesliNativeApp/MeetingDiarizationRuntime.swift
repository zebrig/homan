@preconcurrency import CoreML
@preconcurrency import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import MuesliCore

struct DiarizationEngineDescriptor: Sendable, Equatable {
    let engineID: String
    let engineVersion: String
    let supportsOverlap: Bool
    let maximumSpeakers: Int?
}

struct MeetingSystemTimelineInput: Sendable {
    let url: URL
    let map: MeetingSystemTimelineMap
}

struct ModelPreparationProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case validating
        case downloading
        case loading
        case ready
    }

    let fractionCompleted: Double
    let phase: Phase
}

struct MeetingDiarizationProgress: Sendable, Equatable {
    let completedUnits: Int
    let totalUnits: Int

    var fractionCompleted: Double {
        guard totalUnits > 0 else { return 0 }
        return min(max(Double(completedUnits) / Double(totalUnits), 0), 1)
    }
}

struct MeetingDiarizationTimelineResult: Sendable {
    let descriptor: DiarizationEngineDescriptor
    let profile: MeetingDiarizationProfileSnapshot
    let activitySegments: [MeetingDiarizationActivitySegment]
    let timings: MeetingDiarizationTimings
    let warnings: [String]
}

protocol LocalMeetingDiarizationProviding: Sendable {
    func prepare(
        profileID: MeetingDiarizationProfileID,
        progress: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws -> MeetingDiarizationProfileSnapshot

    func diarize(
        timeline: MeetingSystemTimelineInput,
        profileID: MeetingDiarizationProfileID,
        progress: @escaping @Sendable (MeetingDiarizationProgress) -> Void
    ) async throws -> MeetingDiarizationTimelineResult

    func unload() async
}

enum MeetingDiarizationAssetState: String, Codable, Sendable {
    case absent
    case installing
    case ready
    case failed
}

struct MeetingDiarizationAssetStatus: Codable, Sendable, Equatable, Identifiable {
    var id: String { assetID }

    let assetID: String
    let profileID: MeetingDiarizationProfileID
    let profileRevision: Int
    let modelRevision: String
    let modelDigest: String?
    let sizeBytes: Int64
    let state: MeetingDiarizationAssetState
    let installedAt: Date?
    let lastErrorCategory: String?
    let licenseName: String
    let licenseURL: URL
}

enum MeetingDiarizationAssetError: Error, LocalizedError {
    case notInstalled(String)
    case incomplete(String)
    case incompatible(String)
    case invalidPLDA
    case unsupportedLiveModel(String)
    case captureActive

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            return "The \(name) speaker model is not installed. Install it from Models first."
        case .incomplete(let name):
            return "The installed \(name) speaker model could not be validated. Retry its installation from Models."
        case .incompatible(let name):
            return "The installed \(name) speaker model is not compatible with this Homan profile."
        case .invalidPLDA:
            return "The Offline quality speaker model has invalid PLDA parameters."
        case .unsupportedLiveModel(let name):
            return "This model doesn't support Live speaker diarization: \(name)."
        case .captureActive:
            return "Speaker model installation was stopped because a meeting recording started. Try again after recording finishes."
        }
    }
}

private final class MeetingDiarizationInstallCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<MeetingDiarizationProfileSnapshot, Error>?
    private var cancellationRequested = false

    func attach(_ task: Task<MeetingDiarizationProfileSnapshot, Error>) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.task = task
            return cancellationRequested
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<MeetingDiarizationProfileSnapshot, Error>? in
            cancellationRequested = true
            return self.task
        }
        task?.cancel()
    }
}

/// App-owned, versioned model storage. A marker is published only after the
/// complete model bundle has loaded successfully and its bytes have been
/// fingerprinted. Meeting processing reads this store but never installs.
actor MeetingDiarizationAssetStore {
    static let shared = MeetingDiarizationAssetStore()

    private struct Marker: Codable {
        let assetID: String
        let profileID: MeetingDiarizationProfileID
        let profileRevision: Int
        let modelRevision: String
        let modelDigest: String
        let sizeBytes: Int64
        let installedAt: Date
        let licenseName: String
        let licenseURL: URL
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private var transientState: [String: (state: MeetingDiarizationAssetState, error: String?)] = [:]
    private var verifiedModelDigests: [String: String] = [:]

    init(
        rootURL: URL = AppIdentity.supportDirectoryURL
            .appendingPathComponent("Models/Diarization", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func baseDirectory(for definition: MeetingDiarizationProfileDefinition) -> URL {
        rootURL.appendingPathComponent(definition.modelAssetID, isDirectory: true)
    }

    func statuses() -> [MeetingDiarizationAssetStatus] {
        MeetingDiarizationProfileID.allCases.map { status(for: $0) }
    }

    func status(for profileID: MeetingDiarizationProfileID) -> MeetingDiarizationAssetStatus {
        let definition = MeetingDiarizationProfiles.resolve(profileID)
        let transient = transientState[definition.modelAssetID]
        let marker = loadMarker(for: definition)
        if let marker,
           markerIsCompatible(marker, with: definition),
           requiredPaths(for: definition).allSatisfy({ fileManager.fileExists(atPath: $0.path) }) {
            return MeetingDiarizationAssetStatus(
                assetID: definition.modelAssetID,
                profileID: profileID,
                profileRevision: marker.profileRevision,
                modelRevision: marker.modelRevision,
                modelDigest: marker.modelDigest,
                sizeBytes: marker.sizeBytes,
                state: transient?.state == .installing ? .installing : .ready,
                installedAt: marker.installedAt,
                lastErrorCategory: transient?.error,
                licenseName: definition.licenseName,
                licenseURL: definition.licenseURL
            )
        }
        let hasResidualInstall = fileManager.fileExists(
            atPath: baseDirectory(for: definition).path
        )
        let persistedFailureCategory: String? = if marker != nil {
            "incompatible_install"
        } else if hasResidualInstall {
            "incomplete_install"
        } else {
            nil
        }
        return MeetingDiarizationAssetStatus(
            assetID: definition.modelAssetID,
            profileID: profileID,
            profileRevision: definition.revision,
            modelRevision: definition.modelRevision,
            modelDigest: nil,
            sizeBytes: 0,
            state: transient?.state ?? (hasResidualInstall ? .failed : .absent),
            installedAt: nil,
            lastErrorCategory: transient?.error ?? persistedFailureCategory,
            licenseName: definition.licenseName,
            licenseURL: definition.licenseURL
        )
    }

    func beginInstall(_ definition: MeetingDiarizationProfileDefinition) throws -> URL {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let base = baseDirectory(for: definition)
        try fileManager.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        transientState[definition.modelAssetID] = (.installing, nil)
        verifiedModelDigests.removeValue(forKey: definition.modelAssetID)
        try? fileManager.removeItem(at: markerURL(for: definition))
        return base
    }

    func finishInstall(
        _ definition: MeetingDiarizationProfileDefinition
    ) throws -> MeetingDiarizationProfileSnapshot {
        guard requiredPaths(for: definition).allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            transientState[definition.modelAssetID] = (.failed, "missing_files")
            throw MeetingDiarizationAssetError.incomplete(definition.displayName)
        }
        let base = baseDirectory(for: definition)
        let digestResult = try directoryDigest(at: base)
        let marker = Marker(
            assetID: definition.modelAssetID,
            profileID: definition.effectiveID,
            profileRevision: definition.revision,
            modelRevision: definition.modelRevision,
            modelDigest: digestResult.digest,
            sizeBytes: digestResult.sizeBytes,
            installedAt: Date(),
            licenseName: definition.licenseName,
            licenseURL: definition.licenseURL
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: markerURL(for: definition), options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerURL(for: definition).path
        )
        transientState[definition.modelAssetID] = (.ready, nil)
        verifiedModelDigests[definition.modelAssetID] = marker.modelDigest
        return definition.snapshot(modelDigest: marker.modelDigest)
    }

    func failInstall(
        _ definition: MeetingDiarizationProfileDefinition,
        category: String
    ) {
        transientState[definition.modelAssetID] = (.failed, category)
    }

    func requireReady(
        _ definition: MeetingDiarizationProfileDefinition
    ) throws -> (directory: URL, snapshot: MeetingDiarizationProfileSnapshot) {
        guard let marker = loadMarker(for: definition) else {
            throw MeetingDiarizationAssetError.notInstalled(definition.displayName)
        }
        guard markerIsCompatible(marker, with: definition) else {
            throw MeetingDiarizationAssetError.incompatible(definition.displayName)
        }
        guard requiredPaths(for: definition).allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            throw MeetingDiarizationAssetError.incomplete(definition.displayName)
        }
        if verifiedModelDigests[definition.modelAssetID] != marker.modelDigest {
            let actual = try directoryDigest(at: baseDirectory(for: definition))
            guard actual.digest == marker.modelDigest,
                  actual.sizeBytes == marker.sizeBytes else {
                transientState[definition.modelAssetID] = (.failed, "digest_mismatch")
                throw MeetingDiarizationAssetError.incompatible(definition.displayName)
            }
            verifiedModelDigests[definition.modelAssetID] = marker.modelDigest
        }
        return (
            baseDirectory(for: definition),
            definition.snapshot(modelDigest: marker.modelDigest)
        )
    }

    func remove(_ definition: MeetingDiarizationProfileDefinition) throws {
        let base = baseDirectory(for: definition).standardizedFileURL
        let root = rootURL.standardizedFileURL
        guard base.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if fileManager.fileExists(atPath: base.path) {
            try fileManager.removeItem(at: base)
        }
        verifiedModelDigests.removeValue(forKey: definition.modelAssetID)
        transientState[definition.modelAssetID] = (.absent, nil)
    }

    private func markerURL(for definition: MeetingDiarizationProfileDefinition) -> URL {
        baseDirectory(for: definition).appendingPathComponent("homan-asset.json")
    }

    private func loadMarker(for definition: MeetingDiarizationProfileDefinition) -> Marker? {
        let url = markerURL(for: definition)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    private func markerIsCompatible(
        _ marker: Marker,
        with definition: MeetingDiarizationProfileDefinition
    ) -> Bool {
        marker.assetID == definition.modelAssetID
            && marker.profileID == definition.effectiveID
            && marker.profileRevision == definition.revision
            && marker.modelRevision == definition.modelRevision
            && marker.sizeBytes > 0
            && marker.modelDigest.count == 64
            && marker.modelDigest.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
    }

    private func requiredPaths(
        for definition: MeetingDiarizationProfileDefinition
    ) -> [URL] {
        let base = baseDirectory(for: definition)
        switch definition.engineID {
        case .offlineCommunity:
            let repo = base.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
            return [
                "Segmentation.mlmodelc",
                "FBank.mlmodelc",
                "Embedding.mlmodelc",
                "PldaRho.mlmodelc",
                "plda-parameters.json",
            ].map { repo.appendingPathComponent($0) }
        case .sortformerBalanced:
            return [
                base
                    .appendingPathComponent(Repo.sortformer.folderName, isDirectory: true)
                    .appendingPathComponent("\(definition.modelRevision).mlmodelc", isDirectory: true),
            ]
        }
    }

    private func directoryDigest(at directory: URL) throws -> (digest: String, sizeBytes: Int64) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        let files = enumerator.compactMap { $0 as? URL }.filter { url in
            url.lastPathComponent != "homan-asset.json"
                && ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
        }.sorted { $0.path < $1.path }
        var hasher = SHA256()
        var total: Int64 = 0
        for file in files {
            let relative = String(file.path.dropFirst(directory.path.count))
            hasher.update(data: Data(relative.utf8))
            let handle = try FileHandle(forReadingFrom: file)
            do {
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    total += Int64(chunk.count)
                    hasher.update(data: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }
}

/// Owns every local Final diarizer instance. The inference gate is deliberately
/// outside the model objects: Swift actor reentrancy otherwise allows another
/// call (including unload/remove) to enter while native inference is awaiting.
actor MeetingDiarizationRuntime: LocalMeetingDiarizationProviding {
    private struct LegacyAssetBundle {
        let segmentationURL: URL
        let embeddingURL: URL
        let digest: String
    }

    /// FluidAudio 0.15.2 `DiarizerConfig.default.chunkDuration` is 10 seconds
    /// with zero overlap. Driving the legacy manager at that same boundary
    /// preserves whole-file behavior while adding capture/cancel checkpoints.
    private static let legacyChunkDurationSeconds: TimeInterval = 10

    private let assets: MeetingDiarizationAssetStore
    private let scheduler: MeetingInferenceScheduler
    private let inferenceGate = InferenceGate()
    private var offlineManager: OfflineDiarizerManager?
    private var sortformerManager: SortformerDiarizer?
    private var legacyManager: DiarizerManager?
    private var loadedOfflineDigest: String?
    private var loadedSortformerDigest: String?
    private var loadedLegacyDigest: String?

    init(
        assets: MeetingDiarizationAssetStore = .shared,
        scheduler: MeetingInferenceScheduler = .shared
    ) {
        self.assets = assets
        self.scheduler = scheduler
    }

    func assetStatuses() async -> [MeetingDiarizationAssetStatus] {
        await assets.statuses()
    }

    func prepare(
        profileID: MeetingDiarizationProfileID,
        progress: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws -> MeetingDiarizationProfileSnapshot {
        if MeetingDiarizationRollbackPolicy.current() == .legacy {
            progress(.init(fractionCompleted: 0, phase: .validating))
            let legacyAssets = try Self.locateLegacyAssets()
            let snapshot = MeetingDiarizationProfiles.legacyRollbackSnapshot(
                requestedID: profileID,
                modelDigest: legacyAssets.digest,
                runtimePolicy: DiarizerRuntimePolicy.resolve(for: .current())
            )
            progress(.init(fractionCompleted: 1, phase: .ready))
            return snapshot
        }
        let definition = MeetingDiarizationProfiles.resolve(profileID)
        progress(.init(fractionCompleted: 0, phase: .validating))
        let ready = try await assets.requireReady(definition)
        progress(.init(fractionCompleted: 1, phase: .ready))
        return ready.snapshot
    }

    /// The only path allowed to download speaker models. UI callers must also
    /// ensure recording is inactive before invoking it.
    func install(
        profileID: MeetingDiarizationProfileID,
        progress: @escaping @Sendable (ModelPreparationProgress) -> Void = { _ in }
    ) async throws -> MeetingDiarizationProfileSnapshot {
        guard !scheduler.isCaptureActive else {
            throw MeetingDiarizationAssetError.captureActive
        }
        let cancellationRelay = MeetingDiarizationInstallCancellationRelay()
        let registrationID = scheduler.registerCancellationOnCapture {
            cancellationRelay.cancel()
        }
        defer { scheduler.unregisterCancellationOnCapture(registrationID) }

        let task = Task { [self] in
            try Task.checkCancellation()
            return try await performInstall(
                profileID: profileID,
                progress: progress
            )
        }
        cancellationRelay.attach(task)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performInstall(
        profileID: MeetingDiarizationProfileID,
        progress: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws -> MeetingDiarizationProfileSnapshot {
        try await inferenceGate.acquire()
        let definition = MeetingDiarizationProfiles.resolve(profileID)
        do {
            try Task.checkCancellation()
            guard !scheduler.isCaptureActive else {
                throw MeetingDiarizationAssetError.captureActive
            }
            let directory = try await assets.beginInstall(definition)
            progress(.init(fractionCompleted: 0, phase: .downloading))
            switch definition.engineID {
            case .offlineCommunity:
                let models = try await OfflineDiarizerModels.load(
                    from: directory,
                    progressHandler: { state in
                        progress(.init(
                            fractionCompleted: state.fractionCompleted,
                            phase: state.fractionCompleted >= 0.5 ? .loading : .downloading
                        ))
                    }
                )
                try Task.checkCancellation()
                let manager = OfflineDiarizerManager(config: .default)
                manager.initialize(models: models)
                offlineManager = manager
            case .sortformerBalanced:
                let config = SortformerConfig.balancedV2_1
                let models = try await SortformerModels.loadFromHuggingFace(
                    config: config,
                    cacheDirectory: directory,
                    computeUnits: .all,
                    progressHandler: { state in
                        progress(.init(
                            fractionCompleted: state.fractionCompleted,
                            phase: state.fractionCompleted >= 0.5 ? .loading : .downloading
                        ))
                    }
                )
                try Task.checkCancellation()
                let manager = SortformerDiarizer(config: config)
                manager.initialize(models: models)
                sortformerManager = manager
            }
            try Task.checkCancellation()
            guard !scheduler.isCaptureActive else {
                throw MeetingDiarizationAssetError.captureActive
            }
            let snapshot = try await assets.finishInstall(definition)
            switch definition.engineID {
            case .offlineCommunity: loadedOfflineDigest = snapshot.modelDigest
            case .sortformerBalanced: loadedSortformerDigest = snapshot.modelDigest
            }
            progress(.init(fractionCompleted: 1, phase: .ready))
            await inferenceGate.release()
            return snapshot
        } catch {
            await assets.failInstall(definition, category: Self.errorCategory(error))
            await inferenceGate.release()
            throw error
        }
    }

    func remove(profileID: MeetingDiarizationProfileID) async throws {
        let definition = MeetingDiarizationProfiles.resolve(profileID)
        try await inferenceGate.acquire()
        do {
            switch definition.engineID {
            case .offlineCommunity:
                offlineManager = nil
                loadedOfflineDigest = nil
            case .sortformerBalanced:
                sortformerManager = nil
                loadedSortformerDigest = nil
            }
            try await assets.remove(definition)
            await inferenceGate.release()
        } catch {
            await inferenceGate.release()
            throw error
        }
    }

    func diarize(
        timeline: MeetingSystemTimelineInput,
        profileID: MeetingDiarizationProfileID,
        progress: @escaping @Sendable (MeetingDiarizationProgress) -> Void = { _ in }
    ) async throws -> MeetingDiarizationTimelineResult {
        if MeetingDiarizationRollbackPolicy.current() == .legacy {
            return try await diarizeWithLegacyProvider(
                timeline: timeline,
                requestedProfileID: profileID,
                progress: progress
            )
        }
        let definition = MeetingDiarizationProfiles.resolve(profileID)
        let ready = try await assets.requireReady(definition)
        try await inferenceGate.acquire()
        do {
            try await scheduler.waitUntilCaptureAllowsInference()
            try Task.checkCancellation()
            let loadStarted = Date()
            let rawSegments: [TimedSpeakerSegment]
            let inferenceStarted: Date
            switch definition.engineID {
            case .offlineCommunity:
                if offlineManager == nil || loadedOfflineDigest != ready.snapshot.modelDigest {
                    offlineManager = try Self.loadOfflineManager(from: ready.directory)
                    loadedOfflineDigest = ready.snapshot.modelDigest
                }
                guard let offlineManager else {
                    throw MeetingDiarizationAssetError.incomplete(definition.displayName)
                }
                inferenceStarted = Date()
                let factory = AudioSourceFactory()
                let sourceResult = try factory.makeDiskBackedSource(
                    from: timeline.url,
                    targetSampleRate: MeetingSystemTimelineRenderer.sampleRate
                )
                defer { sourceResult.source.cleanup() }
                try await scheduler.waitUntilCaptureAllowsInference()
                let inferenceScheduler = scheduler
                let result = try await offlineManager.process(
                    audioSource: sourceResult.source,
                    audioLoadingSeconds: sourceResult.loadDuration,
                    progressCallback: { completed, total in
                        inferenceScheduler.waitAtInferenceCheckpoint()
                        progress(.init(completedUnits: completed, totalUnits: total))
                    }
                )
                rawSegments = result.segments
            case .sortformerBalanced:
                if sortformerManager == nil || loadedSortformerDigest != ready.snapshot.modelDigest {
                    sortformerManager = try Self.loadSortformerManager(from: ready.directory)
                    loadedSortformerDigest = ready.snapshot.modelDigest
                }
                guard let sortformerManager else {
                    throw MeetingDiarizationAssetError.incomplete(definition.displayName)
                }
                inferenceStarted = Date()
                let result = try await Self.processSortformerFile(
                    at: timeline.url,
                    manager: sortformerManager,
                    scheduler: scheduler,
                    progress: progress
                )
                rawSegments = result.speakers.keys.sorted().flatMap { index -> [TimedSpeakerSegment] in
                    guard let speaker = result.speakers[index] else { return [] }
                    return speaker.finalizedSegments.map { segment in
                        TimedSpeakerSegment(
                            speakerId: "S\(index + 1)",
                            embedding: [],
                            startTimeSeconds: segment.startTime,
                            endTimeSeconds: segment.endTime,
                            qualityScore: segment.activity
                        )
                    }
                }
            }
            try Task.checkCancellation()
            let completedAt = Date()
            let activity = Self.validatedActivity(
                rawSegments,
                duration: timeline.map.totalDurationSeconds
            )
            let result = MeetingDiarizationTimelineResult(
                descriptor: DiarizationEngineDescriptor(
                    engineID: definition.engineID.rawValue,
                    engineVersion: definition.engineVersion,
                    supportsOverlap: true,
                    maximumSpeakers: definition.maximumSpeakers
                ),
                profile: ready.snapshot,
                activitySegments: activity,
                timings: MeetingDiarizationTimings(
                    modelLoadSeconds: max(0, inferenceStarted.timeIntervalSince(loadStarted)),
                    inferenceSeconds: max(0, completedAt.timeIntervalSince(inferenceStarted)),
                    postProcessingSeconds: max(0, Date().timeIntervalSince(completedAt))
                ),
                warnings: []
            )
            await inferenceGate.release()
            return result
        } catch {
            await inferenceGate.release()
            throw error
        }
    }

    func unload() async {
        do {
            try await inferenceGate.acquire()
        } catch {
            return
        }
        offlineManager = nil
        sortformerManager = nil
        legacyManager?.cleanup()
        legacyManager = nil
        loadedOfflineDigest = nil
        loadedSortformerDigest = nil
        loadedLegacyDigest = nil
        await inferenceGate.release()
    }

    /// Explicit rollback adapter for the pre-offline FluidAudio diarizer. It
    /// uses cached models only and is mutually exclusive with the selected
    /// shipping provider. The legacy dependency is synchronous, so Homan
    /// drives it one native-sized chunk at a time and yields between chunks.
    private func diarizeWithLegacyProvider(
        timeline: MeetingSystemTimelineInput,
        requestedProfileID: MeetingDiarizationProfileID,
        progress: @escaping @Sendable (MeetingDiarizationProgress) -> Void
    ) async throws -> MeetingDiarizationTimelineResult {
        try await inferenceGate.acquire()
        do {
            try await scheduler.waitUntilCaptureAllowsInference()
            try Task.checkCancellation()
            let preparationStarted = Date()
            let legacyAssets = try Self.locateLegacyAssets()
            let runtimePolicy = DiarizerRuntimePolicy.resolve(for: .current())
            if legacyManager == nil || loadedLegacyDigest != legacyAssets.digest {
                legacyManager?.cleanup()
                let models = try DiarizerModels.load(
                    localSegmentationModel: legacyAssets.segmentationURL,
                    localEmbeddingModel: legacyAssets.embeddingURL,
                    configuration: runtimePolicy.modelConfiguration
                )
                let manager = DiarizerManager(config: .default)
                manager.initialize(models: models)
                legacyManager = manager
                loadedLegacyDigest = legacyAssets.digest
            }
            guard let legacyManager else {
                throw MeetingDiarizationAssetError.incomplete("Legacy compatibility")
            }

            // Speaker state is meeting-scoped. Reusing it across two meetings
            // would fabricate stable identities that the legacy model cannot
            // actually guarantee.
            legacyManager.speakerManager.reset()
            let inferenceStarted = Date()
            let rawSegments = try await processLegacyFile(
                at: timeline.url,
                manager: legacyManager,
                progress: progress
            )
            let inferenceCompleted = Date()
            try Task.checkCancellation()
            let activity = Self.validatedActivity(
                rawSegments,
                duration: timeline.map.totalDurationSeconds
            )
            let snapshot = MeetingDiarizationProfiles.legacyRollbackSnapshot(
                requestedID: requestedProfileID,
                modelDigest: legacyAssets.digest,
                runtimePolicy: runtimePolicy
            )
            let result = MeetingDiarizationTimelineResult(
                descriptor: DiarizationEngineDescriptor(
                    engineID: MeetingDiarizationProfiles.legacyEngineID,
                    engineVersion: MeetingDiarizationProfiles.fluidAudioVersion,
                    supportsOverlap: true,
                    maximumSpeakers: nil
                ),
                profile: snapshot,
                activitySegments: activity,
                timings: MeetingDiarizationTimings(
                    modelLoadSeconds: max(
                        0,
                        inferenceStarted.timeIntervalSince(preparationStarted)
                    ),
                    inferenceSeconds: max(
                        0,
                        inferenceCompleted.timeIntervalSince(inferenceStarted)
                    ),
                    postProcessingSeconds: max(
                        0,
                        Date().timeIntervalSince(inferenceCompleted)
                    )
                ),
                warnings: ["Legacy speaker-analysis rollback provider was explicitly selected."]
            )
            await inferenceGate.release()
            return result
        } catch {
            await inferenceGate.release()
            throw error
        }
    }

    private static func loadOfflineManager(from base: URL) throws -> OfflineDiarizerManager {
        let repo = base.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
        let all = MLModelConfiguration()
        all.computeUnits = .all
        all.allowLowPrecisionAccumulationOnGPU = true
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let models = OfflineDiarizerModels(
            segmentationModel: try MLModel(contentsOf: repo.appendingPathComponent("Segmentation.mlmodelc"), configuration: all),
            fbankModel: try MLModel(contentsOf: repo.appendingPathComponent("FBank.mlmodelc"), configuration: cpu),
            embeddingModel: try MLModel(contentsOf: repo.appendingPathComponent("Embedding.mlmodelc"), configuration: all),
            pldaRhoModel: try MLModel(contentsOf: repo.appendingPathComponent("PldaRho.mlmodelc"), configuration: all),
            pldaPsi: try loadPLDAPsi(from: repo.appendingPathComponent("plda-parameters.json")),
            compilationDuration: 0
        )
        let manager = OfflineDiarizerManager(config: .default)
        manager.initialize(models: models)
        return manager
    }

    /// Finds only already-cached legacy assets. This helper intentionally has
    /// no download fallback: Final/recovery must never initiate network work.
    private static func locateLegacyAssets(
        fileManager: FileManager = .default
    ) throws -> LegacyAssetBundle {
        let currentDirectory = DiarizerModels.defaultModelsDirectory()
        let modelsRoot = currentDirectory.deletingLastPathComponent()
        let candidates = [
            currentDirectory,
            modelsRoot.appendingPathComponent("speaker-diarization", isDirectory: true),
        ].reduce(into: [URL]()) { result, candidate in
            let standardized = candidate.standardizedFileURL
            if !result.contains(standardized) {
                result.append(standardized)
            }
        }

        for directory in candidates {
            let segmentation = directory.appendingPathComponent(
                "pyannote_segmentation.mlmodelc",
                isDirectory: true
            )
            let embedding = directory.appendingPathComponent(
                "wespeaker_v2.mlmodelc",
                isDirectory: true
            )
            guard fileManager.fileExists(atPath: segmentation.path),
                  fileManager.fileExists(atPath: embedding.path) else {
                continue
            }
            return LegacyAssetBundle(
                segmentationURL: segmentation,
                embeddingURL: embedding,
                digest: try digestLegacyAssets(
                    [segmentation, embedding],
                    relativeTo: directory,
                    fileManager: fileManager
                )
            )
        }
        throw MeetingDiarizationAssetError.notInstalled("Legacy compatibility")
    }

    private static func digestLegacyAssets(
        _ roots: [URL],
        relativeTo base: URL,
        fileManager: FileManager
    ) throws -> String {
        var files: [URL] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw MeetingDiarizationAssetError.incomplete("Legacy compatibility")
            }
            files.append(contentsOf: enumerator.compactMap { item -> URL? in
                guard let url = item as? URL,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { return nil }
                return url
            })
        }
        guard !files.isEmpty else {
            throw MeetingDiarizationAssetError.incomplete("Legacy compatibility")
        }

        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(String(file.path.dropFirst(base.path.count)).utf8))
            let handle = try FileHandle(forReadingFrom: file)
            do {
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func processLegacyFile(
        at url: URL,
        manager: DiarizerManager,
        progress: @escaping @Sendable (MeetingDiarizationProgress) -> Void
    ) async throws -> [TimedSpeakerSegment] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let framesPerChunk = max(
            1,
            Int(format.sampleRate * Self.legacyChunkDurationSeconds)
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(framesPerChunk)
        ) else {
            throw MeetingSystemTimelineError.invalidAudio(url.lastPathComponent)
        }

        let totalFrames = max(1, Int(file.length))
        var processedFrames = 0
        var segments: [TimedSpeakerSegment] = []
        progress(.init(completedUnits: 0, totalUnits: totalFrames))
        while file.framePosition < file.length {
            try await scheduler.waitUntilCaptureAllowsInference()
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            let requested = AVAudioFrameCount(min(Int64(framesPerChunk), remaining))
            try file.read(into: buffer, frameCount: requested)
            let sourceFrameCount = Int(buffer.frameLength)
            guard sourceFrameCount > 0 else { break }
            let samples = try AudioConverter().resampleBuffer(buffer)
            let startTime = TimeInterval(processedFrames) / format.sampleRate
            let result = try manager.performCompleteDiarization(
                samples,
                sampleRate: MeetingSystemTimelineRenderer.sampleRate,
                atTime: startTime
            )
            segments.append(contentsOf: result.segments)
            processedFrames += sourceFrameCount
            progress(.init(
                completedUnits: min(processedFrames, totalFrames),
                totalUnits: totalFrames
            ))
            try Task.checkCancellation()
        }
        progress(.init(completedUnits: totalFrames, totalUnits: totalFrames))
        return segments
    }

    static func loadSortformerManager(
        from base: URL,
        timelineConfig: DiarizerTimelineConfig = .sortformerDefault
    ) throws -> SortformerDiarizer {
        let config = SortformerConfig.balancedV2_1
        let modelURL = base
            .appendingPathComponent("diar-streaming-sortformer-coreml", isDirectory: true)
            .appendingPathComponent("SortformerNvidiaLow_v2.1.mlmodelc", isDirectory: true)
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .all
        mlConfig.allowLowPrecisionAccumulationOnGPU = true
        let model = try MLModel(contentsOf: modelURL, configuration: mlConfig)
        let models = try SortformerModels(config: config, main: model)
        let manager = SortformerDiarizer(
            config: config,
            timelineConfig: timelineConfig
        )
        manager.initialize(models: models)
        return manager
    }

    /// Drives Sortformer through its streaming API even for Final work. This
    /// preserves bounded memory for long meetings and creates a cancellation /
    /// capture-yield checkpoint before every model-sized slice.
    private static func processSortformerFile(
        at url: URL,
        manager: SortformerDiarizer,
        scheduler: MeetingInferenceScheduler,
        progress: @escaping @Sendable (MeetingDiarizationProgress) -> Void
    ) async throws -> DiarizerTimeline {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount == 1,
              abs(format.sampleRate - Double(MeetingSystemTimelineRenderer.sampleRate)) < 0.5,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(MeetingSystemTimelineRenderer.sampleRate / 2)
              ) else {
            throw MeetingSystemTimelineError.invalidAudio(url.lastPathComponent)
        }

        manager.reset()
        let totalFrames = max(1, Int(file.length))
        var processedFrames = 0
        while file.framePosition < file.length {
            try await scheduler.waitUntilCaptureAllowsInference()
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            try file.read(into: buffer, frameCount: requested)
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            guard let channel = buffer.floatChannelData?.pointee else {
                throw MeetingSystemTimelineError.invalidAudio(url.lastPathComponent)
            }
            let samples = Array(UnsafeBufferPointer(start: channel, count: count))
            _ = try manager.process(samples: samples, sourceSampleRate: format.sampleRate)
            processedFrames += count
            progress(.init(
                completedUnits: min(processedFrames, totalFrames),
                totalUnits: totalFrames
            ))
        }
        try await scheduler.waitUntilCaptureAllowsInference()
        try Task.checkCancellation()
        _ = try manager.finalizeSession()
        progress(.init(completedUnits: totalFrames, totalUnits: totalFrames))
        return manager.timeline
    }

    private static func loadPLDAPsi(from url: URL) throws -> [Double] {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tensors = root["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let encoded = psi["data_base64"] as? String,
              let decoded = Data(base64Encoded: encoded),
              !decoded.isEmpty,
              decoded.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw MeetingDiarizationAssetError.invalidPLDA
        }
        let floats = decoded.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        return floats.map(Double.init)
    }

    private static func validatedActivity(
        _ segments: [TimedSpeakerSegment],
        duration: TimeInterval
    ) -> [MeetingDiarizationActivitySegment] {
        segments.compactMap { segment in
            let start = TimeInterval(segment.startTimeSeconds)
            let end = TimeInterval(segment.endTimeSeconds)
            guard start.isFinite, end.isFinite, end > start, end > 0, start < duration else {
                return nil
            }
            return MeetingDiarizationActivitySegment(
                speakerKey: segment.speakerId,
                startSeconds: max(0, start),
                endSeconds: min(duration, end),
                confidence: segment.qualityScore
            )
        }.filter(\.isValid)
    }

    private static func errorCategory(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is MeetingDiarizationAssetError { return "asset" }
        if error is CocoaError { return "filesystem" }
        return "provider"
    }
}
