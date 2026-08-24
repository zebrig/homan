import Foundation

/// A Homan-owned tombstone shared by the app and bundled CLI. It prevents an
/// explicitly deleted model from being silently re-imported from FluidAudio's
/// older shared cache, without modifying that third-party cache.
public enum ManagedASRLegacyAdoptionPolicy {
    public static func isSuppressed(
        modelID: String,
        supportDirectory: URL = MuesliPaths.defaultSupportDirectoryURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: markerURL(
            modelID: modelID,
            supportDirectory: supportDirectory
        ).path)
    }

    public static func suppress(
        modelID: String,
        supportDirectory: URL = MuesliPaths.defaultSupportDirectoryURL(),
        fileManager: FileManager = .default
    ) throws {
        let marker = markerURL(modelID: modelID, supportDirectory: supportDirectory)
        try fileManager.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: marker, options: .atomic)
    }

    public static func markerURL(
        modelID: String,
        supportDirectory: URL = MuesliPaths.defaultSupportDirectoryURL()
    ) -> URL {
        let filename = modelID
            .replacingOccurrences(of: "/", with: "--")
            .replacingOccurrences(of: "\\", with: "--")
        return supportDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("LegacySuppressions", isDirectory: true)
            .appendingPathComponent("\(filename).ignored")
    }
}
