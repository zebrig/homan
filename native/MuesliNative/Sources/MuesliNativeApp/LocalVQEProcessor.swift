import CryptoKit
import Foundation
import LocalVQEBridge

enum MeetingAecModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case gtcrn49K = "gtcrn_49k"
    case localVQEV12 = "localvqe_v1_2"

    static let defaultModel = MeetingAecModel.localVQEV12

    var id: String { rawValue }

    static func resolved(_ rawValue: String?) -> MeetingAecModel {
        guard let rawValue, let model = MeetingAecModel(rawValue: rawValue) else {
            return defaultModel
        }
        return model
    }

    var label: String {
        switch self {
        case .gtcrn49K:
            return "GTCRN 49K (Low CPU)"
        case .localVQEV12:
            return "LocalVQE v1.2 (Stronger AEC)"
        }
    }

    var settingsDescription: String {
        switch self {
        case .gtcrn49K:
            return "Lower-CPU echo cancellation, noise suppression, and dereverberation."
        case .localVQEV12:
            return "Default. Stronger echo suppression and faster adaptation, with substantially higher CPU use."
        }
    }

    var fileName: String {
        switch self {
        case .gtcrn49K:
            return "localvqe-pi-v1-49k-f32.gguf"
        case .localVQEV12:
            return "localvqe-v1.2-1.3M-f32.gguf"
        }
    }

    var sha256: String {
        switch self {
        case .gtcrn49K:
            return "0e0c82a8e9703e818b64dedd0fc306394cf5bbb59fcec1ccca82099d352d0c26"
        case .localVQEV12:
            return "4856ecf5f522b23fb2bc5caeac81f323c0ef1c4c156a9c7d40a6adbe092ba9ce"
        }
    }

    var downloadURL: URL {
        URL(
            string: "https://huggingface.co/LocalAI-io/LocalVQE/resolve/main/\(fileName)"
        )!
    }

    var inferenceThreads: Int {
        switch self {
        case .gtcrn49K:
            return 1
        case .localVQEV12:
            return 4
        }
    }

    var processorName: String {
        switch self {
        case .gtcrn49K:
            return "localvqe_gtcrn_49k"
        case .localVQEV12:
            return "localvqe_v1_2"
        }
    }

    var modelPathEnvironmentVariable: String {
        switch self {
        case .gtcrn49K:
            return "MUESLI_LOCALVQE_GTCRN_MODEL_PATH"
        case .localVQEV12:
            return "MUESLI_LOCALVQE_V12_MODEL_PATH"
        }
    }
}

enum LocalVQEError: Error, LocalizedError {
    case modelMissing(URL)
    case libraryMissing([URL])
    case loadFailed(String)
    case invalidRuntime(sampleRate: Int, hopLength: Int)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let url):
            return "LocalVQE model not found at \(url.path)"
        case .libraryMissing(let candidates):
            return "LocalVQE library not found in: \(candidates.map(\.path).joined(separator: ", "))"
        case .loadFailed(let message):
            return "LocalVQE failed to load: \(message)"
        case .invalidRuntime(let sampleRate, let hopLength):
            return "LocalVQE runtime reported unsupported sampleRate=\(sampleRate), hopLength=\(hopLength)"
        case .processFailed(let message):
            return "LocalVQE frame processing failed: \(message)"
        }
    }
}

enum LocalVQEModelStore {
    static func defaultModelURL(for model: MeetingAecModel) -> URL {
        AppIdentity.supportDirectoryURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("localvqe", isDirectory: true)
            .appendingPathComponent(model.fileName)
    }

    static func bundledModelURL(for model: MeetingAecModel) -> URL? {
        let resourceName = URL(fileURLWithPath: model.fileName)
            .deletingPathExtension()
            .lastPathComponent
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("localvqe", isDirectory: true)
                .appendingPathComponent(model.fileName),
            Bundle.main.url(forResource: resourceName, withExtension: "gguf"),
        ].compactMap { $0 }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func resolveModelURL(
        for model: MeetingAecModel,
        downloadIfMissing: Bool = true
    ) async throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let selectedOverride = environment[model.modelPathEnvironmentVariable]
        let legacyOverride = model == .localVQEV12
            ? environment["MUESLI_LOCALVQE_MODEL_PATH"]
            : nil
        if let override = selectedOverride ?? legacyOverride,
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.fileExists(atPath: url.path) else { throw LocalVQEError.modelMissing(url) }
            return url
        }

        let url = defaultModelURL(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try validateModel(at: url, model: model)
                return url
            } catch {
                fputs("[localvqe] ignoring invalid cached model at \(url.path): \(error)\n", stderr)
            }
        }

        if let bundledURL = bundledModelURL(for: model) {
            try validateModel(at: bundledURL, model: model)
            return bundledURL
        }
        guard downloadIfMissing else { throw LocalVQEError.modelMissing(url) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(model.fileName).\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        fputs("[localvqe] downloading model to \(url.path)\n", stderr)
        let (downloadedURL, _) = try await URLSession.shared.download(from: model.downloadURL)
        try FileManager.default.moveItem(at: downloadedURL, to: temporaryURL)
        try validateModel(at: temporaryURL, model: model)
        if FileManager.default.fileExists(atPath: url.path) {
            try validateModel(at: url, model: model)
            return url
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
        return url
    }

    private static func validateModel(at url: URL, model: MeetingAecModel) throws {
        let actualHash = try sha256Hex(for: url)
        guard actualHash == model.sha256 else {
            throw LocalVQEError.loadFailed(
                "model checksum mismatch at \(url.path): expected \(model.sha256), got \(actualHash)"
            )
        }
    }

    private static func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum LocalVQELibraryLocator {
    static func resolve(explicitPath: String? = ProcessInfo.processInfo.environment["MUESLI_LOCALVQE_LIBRARY_PATH"]) throws -> URL {
        if let explicitPath, !explicitPath.isEmpty {
            let url = URL(fileURLWithPath: explicitPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw LocalVQEError.libraryMissing([url]) }
            return url
        }

        let candidates = candidateURLs()
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw LocalVQEError.libraryMissing(candidates)
        }
        return found
    }

    static func candidateURLs(mainBundle: Bundle = .main) -> [URL] {
        let names = ["liblocalvqe.dylib", "liblocalvqe.0.1.0.dylib", "liblocalvqe_shared.dylib"]
        let roots = [
            mainBundle.executableURL?.deletingLastPathComponent(),
            mainBundle.privateFrameworksURL,
            mainBundle.resourceURL,
        ].compactMap { $0 }
        #if DEBUG
        let debugRoots = [
            URL(fileURLWithPath: "/usr/local/lib", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/lib", isDirectory: true),
        ]
        #else
        let debugRoots: [URL] = []
        #endif

        var seen = Set<String>()
        return (roots + debugRoots).flatMap { root in
            names.map { root.appendingPathComponent($0) }
        }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

/// LocalVQE embeds a ggml runtime whose process-wide initialization and
/// teardown are not safe to enter from two independent contexts at once.
///
/// Meeting capture itself never takes this lock: raw callbacks only enqueue
/// samples. The lock is acquired by model preparation and the bounded AEC
/// worker on `MeetingSession.chunkRotationQueue` / post-processing workers.
/// This keeps a newly started Live session from racing an older meeting's
/// post-AEC pass without putting native work on an audio callback.
enum LocalVQENativeRuntimeGate {
    private static let lock = NSLock()

    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

final class LocalVQEAudioProcessor: MeetingAecProcessor {
    let name: String
    let model: MeetingAecModel
    let modelPath: String
    let libraryPath: String
    let inferenceThreads: Int?

    private var context: OpaquePointer?
    private(set) var frameSize = 256
    private(set) var sampleRate = 16_000

    static func load(
        model: MeetingAecModel = .defaultModel,
        downloadModelIfMissing: Bool = true,
        threads: Int? = nil
    ) async throws -> LocalVQEAudioProcessor {
        let modelURL = try await LocalVQEModelStore.resolveModelURL(
            for: model,
            downloadIfMissing: downloadModelIfMissing
        )
        let libraryURL = try LocalVQELibraryLocator.resolve()
        return try LocalVQEAudioProcessor(
            model: model,
            modelURL: modelURL,
            libraryURL: libraryURL,
            threads: threads ?? model.inferenceThreads
        )
    }

    init(
        model: MeetingAecModel,
        modelURL: URL,
        libraryURL: URL,
        threads: Int
    ) throws {
        self.model = model
        name = model.processorName
        modelPath = modelURL.path
        libraryPath = libraryURL.path
        inferenceThreads = threads
        var error = [CChar](repeating: 0, count: 2048)
        context = LocalVQENativeRuntimeGate.withLock {
            modelPath.withCString { modelCString in
                libraryPath.withCString { libraryCString in
                    muesli_localvqe_create(
                        modelCString,
                        libraryCString,
                        Int32(threads),
                        &error,
                        Int32(error.count)
                    )
                }
            }
        }

        guard let context else {
            throw LocalVQEError.loadFailed(String(cString: error))
        }

        (sampleRate, frameSize) = LocalVQENativeRuntimeGate.withLock {
            (
                Int(muesli_localvqe_sample_rate(context)),
                Int(muesli_localvqe_hop_length(context))
            )
        }
        guard sampleRate == 16_000, frameSize == 256 else {
            throw LocalVQEError.invalidRuntime(sampleRate: sampleRate, hopLength: frameSize)
        }
    }

    deinit {
        if let context {
            LocalVQENativeRuntimeGate.withLock {
                muesli_localvqe_destroy(context)
            }
        }
    }

    func reset() {
        guard let context else { return }
        LocalVQENativeRuntimeGate.withLock {
            muesli_localvqe_reset(context)
        }
    }

    func processFrame(mic: [Float], reference: [Float]) throws -> [Float] {
        guard let context else { throw LocalVQEError.loadFailed("runtime is not loaded") }
        guard mic.count == frameSize, reference.count == frameSize else {
            throw LocalVQEError.processFailed("expected \(frameSize) samples, got mic=\(mic.count), reference=\(reference.count)")
        }

        var output = [Float](repeating: 0, count: frameSize)
        let result: (status: Int32, error: String?) = LocalVQENativeRuntimeGate.withLock {
            let status = mic.withUnsafeBufferPointer { micBuffer in
                reference.withUnsafeBufferPointer { referenceBuffer in
                    output.withUnsafeMutableBufferPointer { outputBuffer in
                        muesli_localvqe_process_frame_f32(
                            context,
                            micBuffer.baseAddress,
                            referenceBuffer.baseAddress,
                            Int32(frameSize),
                            outputBuffer.baseAddress
                        )
                    }
                }
            }
            let message = status == 0
                ? nil
                : String(cString: muesli_localvqe_last_error(context))
            return (status, message)
        }

        guard result.status == 0 else {
            throw LocalVQEError.processFailed(result.error ?? "unknown native error")
        }
        return output
    }
}
