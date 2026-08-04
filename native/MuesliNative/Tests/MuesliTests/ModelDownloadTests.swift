import Foundation
import Testing

@testable import MuesliCLI
@testable import MuesliNativeApp

// MARK: - DownloadStateFile

struct DownloadStateFileTests {
    @Test func stateFileRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("test.json")
        let state = DownloadStateFile(
            status: .downloading,
            bytes: 1234,
            total: 5678,
            error: nil,
            sha256: nil
        )
        try state.write(to: url)

        let read = DownloadStateFile.read(at: url)
        #expect(read?.status == .downloading)
        #expect(read?.bytes == 1234)
        #expect(read?.total == 5678)
    }

    @Test func stateFileErrorRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("test.json")
        let state = DownloadStateFile(
            status: .error,
            bytes: 0,
            total: nil,
            error: "SHA-256 mismatch",
            sha256: nil
        )
        try state.write(to: url)

        let read = DownloadStateFile.read(at: url)
        #expect(read?.status == .error)
        #expect(read?.error == "SHA-256 mismatch")
    }

    @Test func stateFileAtomicWriteLeavesNoPartial() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("test.json")
        let state = DownloadStateFile(status: .done, bytes: 100, total: 100, error: nil, sha256: "abc")
        try state.write(to: url)

        // The temp file used for atomic rename should not linger.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.count == 1)
    }
}

// MARK: - SHA-256 digest

struct SHA256DigestTests {
    @Test func sha256KnownVector() {
        var hasher = SHA256Digest()
        hasher.update(Data("abc".utf8))
        // SHA-256("abc") = ba7816bf...
        #expect(hasher.hexDigest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func sha256Empty() {
        var hasher = SHA256Digest()
        #expect(hasher.hexDigest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha256ChunkedMatchesOneShot() {
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        var chunked = SHA256Digest()
        for i in stride(from: 0, to: data.count, by: 8192) {
            let end = min(i + 8192, data.count)
            chunked.update(data[i..<end])
        }
        var whole = SHA256Digest()
        whole.update(data)
        #expect(chunked.hexDigest == whole.hexDigest)
    }
}

// MARK: - AppDownloadState decoding

struct AppDownloadStateTests {
    @Test func decodesCLIWrittenState() throws {
        let json = Data(#"{"status":"done","bytes":2097152,"total":2097152}"#.utf8)
        let state = try JSONDecoder().decode(AppDownloadState.self, from: json)
        #expect(state.status == .done)
        #expect(state.bytes == 2_097_152)
        #expect(state.total == 2_097_152)
    }

    @Test func decodesErrorState() throws {
        let json = Data(#"{"status":"error","bytes":0,"total":null,"error":"SHA-256 mismatch"}"#.utf8)
        let state = try JSONDecoder().decode(AppDownloadState.self, from: json)
        #expect(state.status == .error)
        #expect(state.error == "SHA-256 mismatch")
        #expect(state.total == nil)
    }
}

// MARK: - GemmaSummaryModel catalog

struct GemmaSummaryModelTests {
    @Test func defaultIsE4B() {
        #expect(GemmaSummaryModel.defaultModel.id == "gemma-4-e4b-ud-q4_k_xl")
        #expect(GemmaSummaryModel.resolve(id: "nonexistent") == .e4b)
    }

    @Test func allModelsHaveUniqueIDs() {
        let ids = GemmaSummaryModel.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func modelURLResolvesUnderCache() {
        let model = GemmaSummaryModel.e4b
        #expect(model.modelURL.lastPathComponent == "gemma-4-E4B-it-UD-Q4_K_XL.gguf")
        #expect(model.cacheDirectory.path.contains(".cache/muesli/models"))
    }

    @Test func expectedSizesMatchRealFiles() {
        // These byte sizes were verified against the HF CDN at implementation time.
        #expect(GemmaSummaryModel.e4b.expectedSizeBytes == 5_126_306_944)
        #expect(GemmaSummaryModel.e4bQAT.expectedSizeBytes == 4_215_695_776)
        #expect(GemmaSummaryModel.e2bQAT.expectedSizeBytes == 2_620_370_976)
    }

    @Test func downloadStateIDsAreUniquePerModel() {
        // The state-file ID keys the external-process download state. Every catalog
        // entry must map to a distinct file so progress never collides across models.
        let ids = GemmaSummaryModel.all.map(\.downloadStateID)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("gemma-summary-") })
    }
}

// MARK: - ModelsCategory (T014: Meeting Summarization section)

struct ModelsCategoryTests {
    @Test func includesMeetingSummarization() {
        let category = ModelsCategory.meetingSummarization
        #expect(ModelsCategory.allCases.contains(category))
        #expect(category.title == "Meeting Summary")
        #expect(category.id == "meetingSummarization")
    }
}
