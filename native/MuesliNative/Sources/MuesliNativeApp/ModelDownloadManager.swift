import Foundation
import MuesliCore

// MARK: - Download state (shared with the CLI)

/// Mirrors MuesliCLI.DownloadStateFile. The app reads this file to track a
/// download that a detached `homan-cli` process is performing.
struct AppDownloadState: Codable, Equatable {
    enum Status: String, Codable, Equatable {
        case downloading
        case done
        case error
    }

    var status: Status
    var bytes: Int64
    var total: Int64?
    var error: String?
    var sha256: String?
}

enum ModelDownloadManagerError: LocalizedError {
    case cliNotFound
    case cannotLaunch

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "The bundled homan-cli tool was not found in the app bundle."
        case .cannotLaunch:
            return "Could not launch the bundled homan-cli download tool."
        }
    }
}

/// External-process download for large models (e.g. the ~5 GB Gemma 4 GGUF).
///
/// The app spawns `homan-cli download-model` as a *detached* process and then
/// polls its state file (`Application Support/<App>/model-downloads/<id>.json`).
/// Because the CLI is a separate process, the download survives app quit/relaunch:
/// on relaunch the app reads the state file and continues to show progress.
final class ExternalProcessDownload: @unchecked Sendable {
    private let modelID: String
    private let downloadURL: URL
    private let destination: URL
    private let expectedSize: Int64?
    private let sha256: String?
    private let stateFileURL: URL

    private var process: Process?
    private var pollTask: Task<Void, Never>?

    init(
        modelID: String,
        downloadURL: URL,
        destination: URL,
        expectedSize: Int64?,
        sha256: String?,
        stateFileURL: URL
    ) {
        self.modelID = modelID
        self.downloadURL = downloadURL
        self.destination = destination
        self.expectedSize = expectedSize
        self.sha256 = sha256
        self.stateFileURL = stateFileURL
    }

    /// Resolve the bundled homan-cli path. The SwiftPM-built product and the
    /// packaged app both place it in the same directory as the app executable.
    static func cliExecutableURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL] = [
            Bundle.main.executableURL.map { $0.deletingLastPathComponent().appendingPathComponent("homan-cli") },
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/homan-cli"),
        ].compactMap { $0 }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Current download state from disk (nil if no download has started).
    var currentState: AppDownloadState? {
        AppDownloadStateFile.read(at: stateFileURL)
    }

    /// Launch the detached CLI download. Returns once the process has been spawned
    /// (not when the download completes). Progress is observed via `currentState`.
    func start() throws {
        guard let cliURL = Self.cliExecutableURL() else {
            throw ModelDownloadManagerError.cliNotFound
        }
        guard process == nil else { return }

        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = cliURL
        var arguments = [
            "download-model",
            "--id", modelID,
            "--url", downloadURL.absoluteString,
            "--dest", destination.path,
        ]
        if let expectedSize {
            arguments += ["--expected-size", "\(expectedSize)"]
        }
        if let sha256 {
            arguments += ["--sha256", sha256]
        }
        // The CLI derives the state-file directory from the app's support directory.
        arguments += ["--support-dir", AppPaths.supportDirectoryPath()]
        process.arguments = arguments

        // Detach: the process keeps running even if this app exits.
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Read pipes to avoid a full buffer stalling the child.
        drain(outputPipe.fileHandleForReading)
        drain(errorPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            throw ModelDownloadManagerError.cannotLaunch
        }
        self.process = process
    }

    /// Cancel the in-flight download (best effort) and remove the state file.
    func cancel() {
        process?.terminate()
        process = nil
        pollTask?.cancel()
        pollTask = nil
        try? FileManager.default.removeItem(at: stateFileURL)
    }

    private func drain(_ handle: FileHandle) {
        Task.detached {
            while true {
                let data = handle.readData(ofLength: 4096)
                if data.isEmpty { break }
            }
        }
    }
}

/// Read/write of the app-side state file (thin wrapper, no CLI dependency).
private struct AppDownloadStateFile {
    static func read(at url: URL) -> AppDownloadState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppDownloadState.self, from: data)
    }
}

/// Paths shared between the app and the detached CLI for download state.
enum AppPaths {
    static func supportDirectoryPath() -> String {
        if let env = ProcessInfo.processInfo.environment["MUESLI_SUPPORT_DIR"], !env.isEmpty {
            return env
        }
        return MuesliPaths.defaultSupportDirectoryURL().path
    }

    static func modelDownloadsDirectoryURL() -> URL {
        URL(fileURLWithPath: supportDirectoryPath())
            .appendingPathComponent("model-downloads", isDirectory: true)
    }

    static func stateFileURL(for modelID: String) -> URL {
        modelDownloadsDirectoryURL().appendingPathComponent("\(modelID).json")
    }
}
