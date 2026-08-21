import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("ConfigStore", .serialized)
struct ConfigStoreTests {

    @Test("load returns a valid config")
    func loadReturnsConfig() {
        let store = makeStore()
        let config = store.load()
        // Hotkey may have been customized by user — just verify it loaded
        #expect(HotkeyConfig.label(for: config.dictationHotkey.keyCode) != nil)
        #expect(!config.sttBackend.isEmpty)
    }

    @Test("save and load round-trip")
    func saveLoadRoundTrip() {
        let store = makeStore()
        let original = store.load()

        var config = original
        config.openAIAPIKey = "sk-test-roundtrip"
        config.openAIModel = "gpt-5.4-pro"
        config.openRouterAPIKey = "sk-or-test-roundtrip"
        config.openRouterModel = "nvidia/nemotron-3-super-120b-a12b:free"
        config.cohereLanguage = CohereTranscribeLanguage.german.rawValue
        config.meetingSummaryBackend = "openrouter"
        store.save(config)

        let loaded = store.load()
        #expect(loaded.openAIAPIKey == "sk-test-roundtrip")
        #expect(loaded.openAIModel == "gpt-5.4-pro")
        #expect(loaded.openRouterAPIKey == "sk-or-test-roundtrip")
        #expect(loaded.openRouterModel == "nvidia/nemotron-3-super-120b-a12b:free")
        #expect(loaded.cohereLanguage == CohereTranscribeLanguage.german.rawValue)
        #expect(loaded.meetingSummaryBackend == "openrouter")

        // Restore original
        store.save(original)
    }

    @Test("config path is inside the supplied support directory")
    func configPath() {
        let supportDirectory = makeSupportDirectory()
        let store = ConfigStore(supportDirectory: supportDirectory)
        #expect(store.configPath() == supportDirectory.appendingPathComponent("config.json"))
    }

    @Test("saved config uses owner-only file permissions")
    func configPermissions() throws {
        let store = makeStore()
        let original = store.load()

        store.save(original)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.configPath().path)
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(permissions?.intValue == 0o600)
    }

    private func makeStore() -> ConfigStore {
        ConfigStore(supportDirectory: makeSupportDirectory())
    }

    private func makeSupportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-config-test-\(UUID().uuidString)", isDirectory: true)
    }
}

@Suite("Test storage isolation")
struct TestStorageIsolationTests {
    @Test("default app storage is redirected away from production during tests")
    func defaultStorageIsIsolated() throws {
        try #require(AppIdentity.isRunningTests)

        let productionDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Homan", isDirectory: true)
            .standardizedFileURL
        let testDirectory = AppIdentity.supportDirectoryURL.standardizedFileURL
        try #require(testDirectory != productionDirectory)

        #expect(
            testDirectory.path.hasPrefix(
                FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"
            )
        )
        #expect(ConfigStore().supportDirectory().standardizedFileURL == testDirectory)
        #expect(
            AppIdentity.databaseURL.standardizedFileURL ==
                testDirectory.appendingPathComponent("muesli.db").standardizedFileURL
        )

        #expect(
            !ConfigStore().configPath().standardizedFileURL.path
                .hasPrefix(productionDirectory.path + "/")
        )
    }
}
