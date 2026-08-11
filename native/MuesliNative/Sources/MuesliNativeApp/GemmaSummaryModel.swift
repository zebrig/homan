import Foundation

// MARK: - DownloadableModel

/// Common shape for any model that can be downloaded via the shared card UI.
/// Both in-process (URLSession) and external-process (homan-cli) downloads
/// drive the same state.
protocol DownloadableModel: Identifiable, Equatable {
    var id: String { get }
    var label: String { get }
    var sizeLabel: String { get }
    var description: String { get }
    var downloadURL: URL { get }
    var expectedSizeBytes: Int64? { get }
    var sha256: String? { get }
    var filename: String { get }
    var cacheDirectory: URL { get }
    var modelURL: URL { get }
    var isDownloaded: Bool { get }
}

extension DownloadableModel {
    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }
}

// MARK: - Gemma summary model catalog

/// On-device meeting-summarization models (llama.cpp / GGUF).
/// E4B QAT is the default (2026-08-05) — fastest stable path on the llama.swift runtime.
struct GemmaSummaryModel: DownloadableModel {
    enum Variant: String {
        case e4b = "gemma-4-e4b-ud-q4_k_xl"
        case e4bQAT = "gemma-4-e4b-qat-ud-q4_k_xl"
        case e2bQAT = "gemma-4-e2b-qat-ud-q4_k_xl"
    }

    let id: String
    let label: String
    let sizeLabel: String
    let description: String
    let downloadURL: URL
    let expectedSizeBytes: Int64?
    let sha256: String?
    let filename: String

    var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/\(id)", isDirectory: true)
    }

    var modelURL: URL {
        cacheDirectory.appendingPathComponent(filename)
    }

    // E4B non-QAT UD-Q4_K_XL (5.13 GB) — higher quality, ~2.5× slower decode.
    static let e4b = GemmaSummaryModel(
        id: Variant.e4b.rawValue,
        label: "Gemma 4 E4B",
        sizeLabel: "~5.1 GB",
        description: "Non-QAT Gemma 4 E4B (UD-Q4_K_XL). Full-quality baseline; ~8 t/s decode on M4.",
        downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-UD-Q4_K_XL.gguf")!,
        expectedSizeBytes: 5_126_306_944,
        sha256: nil,
        filename: "gemma-4-E4B-it-UD-Q4_K_XL.gguf"
    )

    // E4B QAT UD-Q4_K_XL (4.22 GB) — the default since 2026-08-05: ~11 t/s decode on the
    // llama.swift runtime (b10276). Lives in the dedicated unsloth QAT repo.
    static let e4bQAT = GemmaSummaryModel(
        id: Variant.e4bQAT.rawValue,
        label: "Gemma 4 E4B (QAT)",
        sizeLabel: "~4.2 GB",
        description: "Recommended. QAT build; ~11 t/s decode on M4. Good English and Russian.",
        downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/resolve/main/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf")!,
        expectedSizeBytes: 4_215_695_776,
        sha256: nil,
        filename: "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf"
    )

    // E2B QAT UD-Q4_K_XL (2.62 GB) — smaller, faster, lower quality. Same QAT
    // language caveat as E4B QAT (EN meetings → Spanish).
    static let e2bQAT = GemmaSummaryModel(
        id: Variant.e2bQAT.rawValue,
        label: "Gemma 4 E2B (QAT)",
        sizeLabel: "~2.6 GB",
        description: "Experimental. Smallest and fastest Gemma 4. Quality is below E4B; same QAT language caveat as E4B QAT.",
        downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf")!,
        expectedSizeBytes: 2_620_370_976,
        sha256: nil,
        filename: "gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf"
    )

    static let all: [GemmaSummaryModel] = [.e4bQAT, .e4b, .e2bQAT]
    static let defaultModel: GemmaSummaryModel = .e4bQAT

    static func resolve(id: String) -> GemmaSummaryModel {
        all.first { $0.id == id } ?? .defaultModel
    }

    static var downloaded: [GemmaSummaryModel] {
        all.filter(\.isDownloaded)
    }

    /// The state-file ID used by the detached `homan-cli download-model` process.
    var downloadStateID: String { "gemma-summary-\(id)" }
}
