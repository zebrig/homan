import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting diarization profiles")
struct MeetingDiarizationProfileTests {
    @Test("Sortformer install accepts FluidAudio's local cache layout")
    func sortformerInstallUsesFluidAudioCacheLayout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-sortformer-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = MeetingDiarizationProfiles.resolve(.stableFourSpeaker)
        let store = MeetingDiarizationAssetStore(rootURL: root)
        let base = try await store.beginInstall(definition)
        let model = base
            .appendingPathComponent("sortformer", isDirectory: true)
            .appendingPathComponent("SortformerNvidiaLow_v2.1.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("sortformer-model".utf8).write(
            to: model.appendingPathComponent("coremldata.bin")
        )

        let installed = try await store.finishInstall(definition)
        let reopened = MeetingDiarizationAssetStore(rootURL: root)
        let verified = try await reopened.requireReady(definition)

        #expect(!installed.modelDigest.isEmpty)
        #expect(verified.snapshot.modelDigest == installed.modelDigest)
        #expect(await reopened.status(for: .stableFourSpeaker).state == .ready)
    }

    @Test("residual speaker model files become a retryable failed install after relaunch")
    func residualInstallIsReportedAsFailedAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-incomplete-diarization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = MeetingDiarizationProfiles.resolve(.stableFourSpeaker)
        let store = MeetingDiarizationAssetStore(rootURL: root)
        let base = try await store.beginInstall(definition)
        try Data("partial".utf8).write(to: base.appendingPathComponent("partial-download"))

        let reopened = MeetingDiarizationAssetStore(rootURL: root)
        let status = await reopened.status(for: .stableFourSpeaker)

        #expect(status.state == .failed)
        #expect(status.lastErrorCategory == "incomplete_install")
    }

    @Test("reopened asset store rejects model bytes that no longer match the marker")
    func installedAssetBytesAreRevalidatedAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-diarization-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = MeetingDiarizationProfiles.resolve(.offlineQuality)
        let store = MeetingDiarizationAssetStore(rootURL: root)
        let base = try await store.beginInstall(definition)
        let repo = base.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo,
            withIntermediateDirectories: true
        )
        let requiredNames = [
            "Segmentation.mlmodelc",
            "FBank.mlmodelc",
            "Embedding.mlmodelc",
            "PldaRho.mlmodelc",
            "plda-parameters.json",
        ]
        for name in requiredNames {
            let url = repo.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
                try Data("model-\(name)".utf8).write(
                    to: url.appendingPathComponent("weights.bin")
                )
            } else {
                try Data("parameters".utf8).write(to: url)
            }
        }
        let installed = try await store.finishInstall(definition)

        let reopened = MeetingDiarizationAssetStore(rootURL: root)
        let verified = try await reopened.requireReady(definition)
        #expect(verified.snapshot.modelDigest == installed.modelDigest)

        try Data("tampered".utf8).write(
            to: repo
                .appendingPathComponent("Embedding.mlmodelc", isDirectory: true)
                .appendingPathComponent("weights.bin")
        )
        let reopenedAfterMutation = MeetingDiarizationAssetStore(rootURL: root)
        await #expect(throws: MeetingDiarizationAssetError.self) {
            _ = try await reopenedAfterMutation.requireReady(definition)
        }
    }

    @Test("legacy rollback switch is explicit and environment takes precedence")
    func legacyRollbackResolution() {
        #expect(MeetingDiarizationRollbackPolicy.resolve(
            environmentValue: nil,
            storedLegacyOverride: nil
        ) == .current)
        #expect(MeetingDiarizationRollbackPolicy.resolve(
            environmentValue: nil,
            storedLegacyOverride: true
        ) == .legacy)
        #expect(MeetingDiarizationRollbackPolicy.resolve(
            environmentValue: "current",
            storedLegacyOverride: true
        ) == .current)
        #expect(MeetingDiarizationRollbackPolicy.resolve(
            environmentValue: "legacy",
            storedLegacyOverride: false
        ) == .legacy)
        #expect(MeetingDiarizationRollbackPolicy.resolve(
            environmentValue: "unknown",
            storedLegacyOverride: true
        ) == .legacy)
    }

    @Test("legacy rollback provenance is distinct from shipping profiles")
    func legacyRollbackProvenance() {
        let runtime = DiarizerRuntimePolicy.resolve(for: DiarizerRuntimeEnvironment(
            cpuBrand: "Apple M4 Pro",
            hardwareModel: "Mac16,7",
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 26,
                minorVersion: 0,
                patchVersion: 0
            )
        ))
        let snapshot = MeetingDiarizationProfiles.legacyRollbackSnapshot(
            requestedID: .automatic,
            modelDigest: "legacy-model-digest",
            runtimePolicy: runtime
        )

        #expect(MeetingDiarizationProfiles.isLegacyRollbackSnapshot(snapshot))
        #expect(snapshot.profileID == MeetingDiarizationProfileID.automatic.rawValue)
        #expect(snapshot.engineID == MeetingDiarizationProfiles.legacyEngineID)
        #expect(!MeetingDiarizationProfiles.matchesCurrentDefinition(
            snapshot,
            requestedID: .automatic
        ))
        #expect(MeetingDiarizationProfiles.matchesActiveProvider(
            snapshot,
            requestedID: .automatic,
            providerMode: .legacy
        ))
        #expect(!MeetingDiarizationProfiles.matchesActiveProvider(
            snapshot,
            requestedID: .automatic,
            providerMode: .current
        ))
    }

    @Test("current profile snapshot requires every immutable definition field")
    func currentDefinitionCompatibility() {
        let definition = MeetingDiarizationProfiles.resolve(.offlineQuality)
        let snapshot = definition.snapshot(modelDigest: "installed-digest")

        #expect(MeetingDiarizationProfiles.matchesCurrentDefinition(
            snapshot,
            requestedID: .offlineQuality
        ))
        #expect(MeetingDiarizationProfiles.matchesActiveProvider(
            snapshot,
            requestedID: .offlineQuality,
            providerMode: .current
        ))
        #expect(!MeetingDiarizationProfiles.matchesActiveProvider(
            snapshot,
            requestedID: .offlineQuality,
            providerMode: .legacy
        ))

        let stale = MeetingDiarizationProfileSnapshot(
            profileID: snapshot.profileID,
            profileRevision: snapshot.profileRevision,
            engineID: snapshot.engineID,
            engineVersion: snapshot.engineVersion,
            modelRevision: snapshot.modelRevision,
            modelDigest: snapshot.modelDigest,
            effectiveConfigurationDigest: "stale-configuration",
            maximumSpeakers: snapshot.maximumSpeakers
        )
        #expect(!MeetingDiarizationProfiles.matchesCurrentDefinition(
            stale,
            requestedID: .offlineQuality
        ))
    }

    @Test("installed asset digest invalidates otherwise compatible evidence")
    func installedAssetCompatibility() {
        let definition = MeetingDiarizationProfiles.resolve(.stableFourSpeaker)
        let completed = definition.snapshot(modelDigest: "old-model-digest")
        let sameInstall = definition.snapshot(modelDigest: "old-model-digest")
        let replacement = definition.snapshot(modelDigest: "new-model-digest")

        #expect(MeetingDiarizationProfiles.matchesInstalledSnapshot(
            completed,
            installed: sameInstall
        ))
        #expect(!MeetingDiarizationProfiles.matchesInstalledSnapshot(
            completed,
            installed: replacement
        ))
    }
}
