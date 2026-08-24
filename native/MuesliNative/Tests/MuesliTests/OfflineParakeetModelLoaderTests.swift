import Foundation
import Testing
@testable import MuesliFluidAudioSupport

@Suite("Offline Parakeet model loader")
struct OfflineParakeetModelLoaderTests {
    @Test("loads dictionary vocabularies without a network-capable FluidAudio loader")
    func loadsDictionaryVocabulary() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-vocab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"0":"<blank>","1":"hello"}"#.utf8).write(to: url)

        let vocabulary = try OfflineParakeetModelLoader.loadVocabulary(from: url)
        #expect(vocabulary == [0: "<blank>", 1: "hello"])
    }

    @Test("loads array vocabularies")
    func loadsArrayVocabulary() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-vocab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"["<blank>","hello"]"#.utf8).write(to: url)

        let vocabulary = try OfflineParakeetModelLoader.loadVocabulary(from: url)
        #expect(vocabulary == [0: "<blank>", 1: "hello"])
    }

    @Test("rejects non-numeric dictionary keys")
    func rejectsInvalidDictionaryVocabulary() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-vocab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"token":"hello"}"#.utf8).write(to: url)

        #expect(throws: OfflineParakeetModelLoader.LoaderError.self) {
            try OfflineParakeetModelLoader.loadVocabulary(from: url)
        }
    }
}
